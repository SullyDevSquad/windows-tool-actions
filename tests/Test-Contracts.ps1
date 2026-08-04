Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

$expectedActions = @(
    'setup-dotnet-framework',
    'setup-wix',
    'setup-msbuild',
    'setup-typemock',
    'setup-node-npm',
    'setup-msxsl'
)

foreach ($actionName in $expectedActions) {
    $metadataPath = Join-Path $repositoryRoot "$actionName/action.yml"
    Assert-Contract (Test-Path -LiteralPath $metadataPath -PathType Leaf) "$actionName/action.yml is missing."
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        Assert-Contract ($metadata -match '(?m)^\s+using:\s+composite\s*$') "$actionName is not a composite action."
        Assert-Contract ($metadata -match '(?m)^\s+shell:\s+pwsh\s*$') "$actionName does not use pwsh."
        Assert-Contract ($metadata -notmatch '(?ms)run:\s*[^\r\n]*\$\{\{\s*inputs\.') "$actionName interpolates an input directly into run source."
        foreach ($match in [regex]::Matches($metadata, '(?m)^\s+uses:\s+([^\s#]+)')) {
            $reference = $match.Groups[1].Value
            Assert-Contract ($reference -match '@[a-f0-9]{40}$') "$actionName has an unpinned action reference: $reference"
        }
    }
}

$powerShellFiles = Get-ChildItem -LiteralPath $repositoryRoot -Recurse -Filter '*.ps1' -File
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in $parseErrors) {
        $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
        $failures.Add("${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
    $unsafeCommands = $ast.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-Expression'
        },
        $true
    )
    Assert-Contract ($unsafeCommands.Count -eq 0) "$($file.Name) contains Invoke-Expression."
}

$workflowDirectory = Join-Path $repositoryRoot '.github/workflows'
if (Test-Path -LiteralPath $workflowDirectory -PathType Container) {
    foreach ($workflow in Get-ChildItem -LiteralPath $workflowDirectory -Filter '*.yml' -File) {
        $content = Get-Content -LiteralPath $workflow.FullName -Raw
        Assert-Contract ($content -notmatch '(?m)^\s*pull_request_target\s*:') "$($workflow.Name) uses pull_request_target."
        foreach ($match in [regex]::Matches($content, '(?m)^\s*-\s+uses:\s+([^\s#]+)')) {
            $reference = $match.Groups[1].Value
            if ($reference.StartsWith('./')) {
                continue
            }
            Assert-Contract ($reference -match '@[a-f0-9]{40}$') "$($workflow.Name) has an unpinned action reference: $reference"
        }
    }
}

$nodeMetadata = Get-Content -LiteralPath (Join-Path $repositoryRoot 'setup-node-npm/action.yml') -Raw
Assert-Contract (
    $nodeMetadata -match 'actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38'
) 'setup-node-npm does not use the reviewed full setup-node commit.'

$typemockMetadata = Get-Content -LiteralPath (Join-Path $repositoryRoot 'setup-typemock/action.yml') -Raw
foreach ($secretInput in @('license-value', 'license-file')) {
    Assert-Contract (
        $typemockMetadata -match "INPUT_[A-Z_]+:\s*\$\{\{\s*inputs\.$([regex]::Escape($secretInput))\s*\}\}"
    ) "Typemock $secretInput is not passed through env."
}

$scratch = Join-Path $repositoryRoot '.test-scratch'
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $env:GITHUB_OUTPUT = Join-Path $scratch 'output'
    $env:GITHUB_PATH = Join-Path $scratch 'path'
    $env:GITHUB_ENV = Join-Path $scratch 'env'
    . (Join-Path $repositoryRoot 'scripts/ActionHelpers.ps1')

    Assert-Contract (
        (Get-NormalizedSha256 -Value ('A' * 64)) -eq ('a' * 64)
    ) 'SHA-256 normalization failed.'
    Assert-Contract (
        (Assert-HttpsUri -Value 'https://github.com/').Scheme -eq 'https'
    ) 'HTTPS URL validation failed.'
    $arguments = ConvertFrom-JsonArgumentArray -Json '["/quiet","value with spaces"]' -InputName 'test'
    Assert-Contract ($arguments.Count -eq 2 -and $arguments[1] -eq 'value with spaces') 'JSON argument parsing failed.'
    $pwshPath = (Get-Process -Id $PID).Path
    $processOutput = Invoke-DirectProcess `
        -FilePath $pwshPath `
        -ArgumentList @('-NoLogo', '-NoProfile', '-Command', '[Console]::Write("direct process ok")')
    Assert-Contract ($processOutput -eq 'direct process ok') 'Direct process argument handling failed.'
    Write-ActionOutput -Name 'test-output' -Value 'ok'
    Set-ActionEnvironment -Name 'TEST_ENV' -Value 'ok'
    Add-ActionPath -Path $scratch
    Assert-Contract ((Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw).Trim() -eq 'test-output=ok') 'GITHUB_OUTPUT helper failed.'
    Assert-Contract ((Get-Content -LiteralPath $env:GITHUB_ENV -Raw).Trim() -eq 'TEST_ENV=ok') 'GITHUB_ENV helper failed.'
    Assert-Contract ((Get-Content -LiteralPath $env:GITHUB_PATH -Raw).Trim() -eq $scratch) 'GITHUB_PATH helper failed.'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "$($failures.Count) contract test(s) failed."
}

Write-Host "Validated $($expectedActions.Count) composite actions and $($powerShellFiles.Count) PowerShell files."
