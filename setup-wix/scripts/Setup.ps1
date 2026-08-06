. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')
Assert-WindowsRunner

$requestedVersion = $env:INPUT_VERSION.Trim()
$isV6 = $requestedVersion -eq '6.x' -or $requestedVersion -match '^6\.\d+\.\d+$'
$isV3 = $requestedVersion -in @('3.11.1', '3.14.1')
if (-not $isV6 -and -not $isV3) {
    throw "Unsupported WiX version '$requestedVersion'. Use 6.x, an exact 6.y.z version, 3.11.1, or 3.14.1."
}

function Test-RequestedVersion {
    param([Parameter(Mandatory)][string]$Actual)

    if ($requestedVersion -eq '6.x') {
        return $Actual -match '^6\.\d+\.\d+$'
    }
    return $Actual -eq $requestedVersion
}

function Get-Wix6Installation {
    param([Parameter(Mandatory)][string]$Executable)

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return $null
    }
    try {
        $output = (& $Executable --version 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $output -notmatch '(?m)\b(6\.\d+\.\d+)\b') {
            return $null
        }
        $actual = $Matches[1]
        if (-not (Test-RequestedVersion -Actual $actual)) {
            return $null
        }
        return [pscustomobject]@{
            Version = $actual
            Directory = Split-Path -Parent $Executable
        }
    }
    catch {
        return $null
    }
}

function Get-Wix3Installation {
    param([Parameter(Mandatory)][string]$Directory)

    $candle = Join-Path $Directory 'candle.exe'
    $light = Join-Path $Directory 'light.exe'
    if (-not (Test-Path -LiteralPath $candle -PathType Leaf) -or
        -not (Test-Path -LiteralPath $light -PathType Leaf)) {
        return $null
    }

    try {
        $candleOutput = (& $candle '-?' 2>&1 | Out-String)
        $candleExitCode = $LASTEXITCODE
        $lightOutput = (& $light '-?' 2>&1 | Out-String)
        $lightExitCode = $LASTEXITCODE
    }
    catch {
        return $null
    }
    if ($candleExitCode -ne 0 -or $lightExitCode -ne 0) {
        return $null
    }

    $versionText = @(
        [Diagnostics.FileVersionInfo]::GetVersionInfo($candle).ProductVersion
        [Diagnostics.FileVersionInfo]::GetVersionInfo($candle).FileVersion
        $candleOutput
        $lightOutput
    ) -join ' '
    if ($versionText -notmatch '\b(3\.(?:11|14)\.1)\b') {
        return $null
    }
    $actual = $Matches[1]
    if (-not (Test-RequestedVersion -Actual $actual)) {
        return $null
    }
    return [pscustomobject]@{
        Version = $actual
        Directory = $Directory
    }
}

function Find-WixInstallation {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Directories)

    foreach ($directory in $Directories | Select-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($directory) -or
            -not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }
        if ($isV6) {
            $result = Get-Wix6Installation -Executable (Join-Path $directory 'wix.exe')
        }
        else {
            $result = Get-Wix3Installation -Directory $directory
        }
        if ($null -ne $result) {
            return $result
        }
    }
    return $null
}

$pathDirectories = @()
if ($isV6) {
    $command = Get-Command wix.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        $pathDirectories += Split-Path -Parent $command.Source
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($env:WIX)) {
        $pathDirectories += @($env:WIX, (Join-Path $env:WIX 'bin'))
    }
    $command = Get-Command candle.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        $pathDirectories += Split-Path -Parent $command.Source
    }
}

$installation = Find-WixInstallation -Directories $pathDirectories
$source = 'preinstalled'

$toolCache = $env:RUNNER_TOOL_CACHE
if ([string]::IsNullOrWhiteSpace($toolCache)) {
    throw 'RUNNER_TOOL_CACHE is not set.'
}
$cacheRoot = Join-Path $toolCache (Join-Path 'wix' $requestedVersion)
$cacheDirectory = Join-Path $cacheRoot 'x64'
if ($null -eq $installation -and (Test-Path -LiteralPath $cacheDirectory -PathType Container)) {
    $cachedDirectories = @($cacheDirectory) + @(
        Get-ChildItem -LiteralPath $cacheDirectory -Directory -Recurse |
            Select-Object -ExpandProperty FullName
    )
    $installation = Find-WixInstallation -Directories $cachedDirectories
    if ($null -ne $installation) {
        $source = 'tool-cache'
    }
}

if ($null -eq $installation) {
    if ([string]::IsNullOrWhiteSpace($env:INPUT_SOURCE_URL) -or
        [string]::IsNullOrWhiteSpace($env:INPUT_SHA256)) {
        throw "WiX $requestedVersion was not found. Provide both source-url and sha256 for an organization-approved ZIP distribution."
    }

    $download = Join-Path $cacheRoot 'download.zip'
    Invoke-VerifiedDownload -Uri $env:INPUT_SOURCE_URL -Sha256 $env:INPUT_SHA256 -Destination $download
    $stagingDirectory = Join-Path $cacheRoot "extract-$([Guid]::NewGuid().ToString('N'))"
    try {
        Expand-Archive -LiteralPath $download -DestinationPath $stagingDirectory -Force
        $candidateDirectories = @($stagingDirectory) + @(
            Get-ChildItem -LiteralPath $stagingDirectory -Directory -Recurse |
                Select-Object -ExpandProperty FullName
        )
        $installation = Find-WixInstallation -Directories $candidateDirectories
        if ($null -eq $installation) {
            throw "The verified archive does not contain a usable WiX $requestedVersion toolset."
        }

        Remove-Item -LiteralPath $cacheDirectory -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath $stagingDirectory -Force |
            Move-Item -Destination $cacheDirectory -Force
    }
    finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $candidateDirectories = @($cacheDirectory) + @(
        Get-ChildItem -LiteralPath $cacheDirectory -Directory -Recurse |
            Select-Object -ExpandProperty FullName
    )
    $installation = Find-WixInstallation -Directories $candidateDirectories
    if ($null -eq $installation) {
        throw 'WiX validation failed after moving the verified distribution into RUNNER_TOOL_CACHE.'
    }
    $source = 'download'
}

Add-ActionPath -Path $installation.Directory
if ($isV3) {
    $wixRoot = if ((Split-Path -Leaf $installation.Directory) -eq 'bin') {
        Split-Path -Parent $installation.Directory
    }
    else {
        $installation.Directory
    }
    $wixRoot = $wixRoot.TrimEnd('\') + '\'
    Set-ActionEnvironment -Name 'WIX' -Value $wixRoot
}

$major = $installation.Version.Split('.')[0]
Write-ActionOutput -Name 'installed-version' -Value $installation.Version
Write-ActionOutput -Name 'path' -Value $installation.Directory
Write-ActionOutput -Name 'major' -Value $major
Write-ActionOutput -Name 'source' -Value $source
Write-Host "WiX $($installation.Version) validated from $source."
