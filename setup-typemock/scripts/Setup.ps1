. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')
Assert-WindowsRunner

if ($env:INPUT_VERSION -ne '9.3.5') {
    throw "Unsupported Typemock version '$env:INPUT_VERSION'. This action currently supports only 9.3.5."
}

[void](Assert-HttpsUri -Value $env:INPUT_INSTALLER_URL)
$expectedHash = Get-NormalizedSha256 -Value $env:INPUT_SHA256
$silentArguments = ConvertFrom-JsonArgumentArray `
    -Json $env:INPUT_SILENT_ARGUMENTS_JSON `
    -InputName 'silent-install-arguments-json'

$expectedExecutable = [Environment]::ExpandEnvironmentVariables($env:INPUT_EXPECTED_EXECUTABLE).Trim()
if ([string]::IsNullOrWhiteSpace($expectedExecutable) -or
    -not [IO.Path]::IsPathRooted($expectedExecutable)) {
    throw 'expected-executable must be an absolute path (environment variables may be used).'
}
$expectedExecutable = [IO.Path]::GetFullPath($expectedExecutable)

Add-SecretMask -Value $env:INPUT_LICENSE_VALUE
Add-SecretMask -Value $env:INPUT_LICENSE_FILE

$hasLicenseValue = -not [string]::IsNullOrWhiteSpace($env:INPUT_LICENSE_VALUE)
$hasLicenseFile = -not [string]::IsNullOrWhiteSpace($env:INPUT_LICENSE_FILE)
$activationRequested = -not [string]::IsNullOrWhiteSpace($env:INPUT_ACTIVATION_EXECUTABLE)
if (($hasLicenseValue -or $hasLicenseFile) -and -not $activationRequested) {
    throw 'License input was supplied without activation-executable. Omit it and perform caller-managed activation, or provide the structured activation inputs.'
}
if ($activationRequested -and $hasLicenseValue -eq $hasLicenseFile) {
    throw 'Structured activation requires exactly one of license-value or license-file.'
}
if ($hasLicenseFile -and -not (Test-Path -LiteralPath $env:INPUT_LICENSE_FILE -PathType Leaf)) {
    throw 'license-file does not identify an existing file.'
}

function Get-ValidatedTypemockVersion {
    if (-not (Test-Path -LiteralPath $expectedExecutable -PathType Leaf)) {
        return $null
    }
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($expectedExecutable)
    $text = "$($versionInfo.ProductVersion) $($versionInfo.FileVersion)"
    if ($text -notmatch '(?<!\d)9\.3\.5(?!\d)') {
        return $null
    }
    return '9.3.5'
}

$installedVersion = Get-ValidatedTypemockVersion
$installerRan = $false
if ($null -eq $installedVersion) {
    $toolCache = $env:RUNNER_TOOL_CACHE
    if ([string]::IsNullOrWhiteSpace($toolCache)) {
        throw 'RUNNER_TOOL_CACHE is not set.'
    }
    $downloadDirectory = Join-Path $toolCache 'typemock\9.3.5\downloads'
    $installerPath = Join-Path $downloadDirectory "$expectedHash.exe"

    $cachedInstallerValid = $false
    if (Test-Path -LiteralPath $installerPath -PathType Leaf) {
        $cachedHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $cachedInstallerValid = $cachedHash -eq $expectedHash
        if (-not $cachedInstallerValid) {
            Remove-Item -LiteralPath $installerPath -Force
        }
    }
    if (-not $cachedInstallerValid) {
        Invoke-VerifiedDownload `
            -Uri $env:INPUT_INSTALLER_URL `
            -Sha256 $expectedHash `
            -Destination $installerPath
    }

    [void](Invoke-DirectProcess `
        -FilePath $installerPath `
        -ArgumentList $silentArguments `
        -SuppressOutput)
    $installerRan = $true
    $installedVersion = Get-ValidatedTypemockVersion
    if ($null -eq $installedVersion) {
        throw "Typemock installer completed, but expected version 9.3.5 was not found at '$expectedExecutable'."
    }
}

$activated = $false
if ($activationRequested) {
    $activationExecutable = [Environment]::ExpandEnvironmentVariables($env:INPUT_ACTIVATION_EXECUTABLE).Trim()
    if (-not [IO.Path]::IsPathRooted($activationExecutable)) {
        throw 'activation-executable must be an absolute path.'
    }
    $activationExecutable = [IO.Path]::GetFullPath($activationExecutable)
    $activationArguments = ConvertFrom-JsonArgumentArray `
        -Json $env:INPUT_ACTIVATION_ARGUMENTS_JSON `
        -InputName 'activation-arguments-json'

    $placeholder = if ($hasLicenseValue) { '{license}' } else { '{license-file}' }
    if (-not ($activationArguments | Where-Object { $_.Contains($placeholder) })) {
        throw "activation-arguments-json must contain the $placeholder placeholder in one argument."
    }
    if ($hasLicenseValue -and ($activationArguments | Where-Object { $_.Contains('{license-file}') })) {
        throw 'activation-arguments-json contains {license-file}, but license-value was supplied.'
    }
    if ($hasLicenseFile -and ($activationArguments | Where-Object { $_.Contains('{license}') })) {
        throw 'activation-arguments-json contains {license}, but license-file was supplied.'
    }

    $replacement = if ($hasLicenseValue) { $env:INPUT_LICENSE_VALUE } else { $env:INPUT_LICENSE_FILE }
    $resolvedArguments = @(
        foreach ($argument in $activationArguments) {
            $resolved = $argument.Replace($placeholder, $replacement)
            Add-SecretMask -Value $resolved
            $resolved
        }
    )
    [void](Invoke-DirectProcess `
        -FilePath $activationExecutable `
        -ArgumentList $resolvedArguments `
        -SuppressOutput)
    $activated = $true
}

Write-ActionOutput -Name 'path' -Value $expectedExecutable
Write-ActionOutput -Name 'version' -Value $installedVersion
Write-ActionOutput -Name 'installer-ran' -Value $installerRan.ToString().ToLowerInvariant()
Write-ActionOutput -Name 'activated' -Value $activated.ToString().ToLowerInvariant()
Write-Host 'Typemock 9.3.5 installation validated. License material was not written to action outputs.'
