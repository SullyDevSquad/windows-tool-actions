. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')
Assert-WindowsRunner

if ($env:INPUT_VS_VERSION -notmatch '^(?<major>\d+)\.(?<minor>\d+)$') {
    throw "vs-version must use major.minor form (for example, 17.0). Received '$env:INPUT_VS_VERSION'."
}
$major = [int]$Matches.major
if ($major -ne 17) {
    throw "Unsupported Visual Studio version line '$env:INPUT_VS_VERSION'. This action locates Visual Studio 2022/MSBuild 17 only."
}
$upperMajor = $major + 1
$versionRange = "[$env:INPUT_VS_VERSION,$upperMajor.0)"

$components = @(
    $env:INPUT_REQUIRED_COMPONENTS -split '[,\r\n]+' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
foreach ($component in $components) {
    if ($component -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid Visual Studio component ID '$component'."
    }
}

$programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "vswhere.exe was not found at '$vswhere'. This action does not install Visual Studio."
}

$arguments = @('-latest', '-products', '*', '-version', $versionRange, '-property', 'installationPath')
if ($components.Count -gt 0) {
    $arguments += '-requires'
    $arguments += $components
}
$installationPath = [string](& $vswhere @arguments | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) {
    $componentMessage = if ($components.Count -gt 0) { " with required components: $($components -join ', ')" } else { '' }
    throw "No complete Visual Studio 2022 installation matched $versionRange$componentMessage. This action does not install Visual Studio."
}
$installationPath = $installationPath.Trim()

$installationVersion = [string](& $vswhere -path $installationPath -property installationVersion)
if ($LASTEXITCODE -ne 0 -or $installationVersion -notmatch '^17\.') {
    throw "vswhere returned an unexpected Visual Studio installation version '$installationVersion'."
}
$installationVersion = $installationVersion.Trim()

$msbuildPath = Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
    throw "MSBuild.exe was not found in the selected Visual Studio installation: $msbuildPath"
}
$versionOutput = (& $msbuildPath -nologo -version | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '^17\.') {
    throw "MSBuild version validation failed. Received '$versionOutput'."
}

$msbuildDirectory = Split-Path -Parent $msbuildPath
Add-ActionPath -Path $msbuildDirectory
Set-ActionEnvironment -Name 'MSBUILD_EXE_PATH' -Value $msbuildPath
Write-ActionOutput -Name 'path' -Value $msbuildPath
Write-ActionOutput -Name 'version' -Value $versionOutput
Write-ActionOutput -Name 'installation-path' -Value $installationPath
Write-Host "MSBuild $versionOutput validated in Visual Studio $installationVersion."
