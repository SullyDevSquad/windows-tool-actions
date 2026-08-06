. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')
Assert-WindowsRunner

if ($env:INPUT_VERSION -ne '4.8') {
    throw "Unsupported .NET Framework version '$env:INPUT_VERSION'. This action currently supports only 4.8."
}

function Get-RegistryValue {
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $view
        )
        try {
            $key = $baseKey.OpenSubKey($SubKey)
            if ($null -ne $key) {
                try {
                    $value = $key.GetValue($Name, $null)
                    if ($null -ne $value) {
                        return $value
                    }
                }
                finally {
                    $key.Dispose()
                }
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }
    return $null
}

$fullKey = 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
$release = Get-RegistryValue -SubKey $fullKey -Name 'Release'
if ($null -eq $release -or [int]$release -lt 528040) {
    throw '.NET Framework 4.8 or a later compatible 4.x runtime is not installed (minimum release key: 528040). This action does not install or reboot the runner.'
}
$runtimeVersion = [string](Get-RegistryValue -SubKey $fullKey -Name 'Version')
if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
    throw '.NET Framework runtime Version registry value was not found.'
}

$sdkRegistryPath = [string](Get-RegistryValue -SubKey 'SOFTWARE\Microsoft\Microsoft SDKs\NETFXSDK\4.8' -Name 'KitsInstallationFolder')
if ([string]::IsNullOrWhiteSpace($sdkRegistryPath) -or
    -not (Test-Path -LiteralPath $sdkRegistryPath -PathType Container)) {
    throw '.NET Framework 4.8 SDK registry entry or SDK directory is missing. Install the 4.8 Developer Pack in the runner image.'
}
$sdkToolsPath = $null
foreach ($architecture in @('x86', 'x64')) {
    $candidate = [string](Get-RegistryValue `
        -SubKey "SOFTWARE\Microsoft\Microsoft SDKs\NETFXSDK\4.8\WinSDK-NetFx40Tools-$architecture" `
        -Name 'InstallationFolder')
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and
        (Test-Path -LiteralPath $candidate -PathType Container)) {
        $sdkToolsPath = $candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace($sdkToolsPath)) {
    throw '.NET Framework 4.8 SDK tools registration or installation directory is missing.'
}

$programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$referenceAssemblies = Join-Path $programFilesX86 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'
$requiredReferences = @('mscorlib.dll', 'System.dll', 'System.Core.dll')
if (-not (Test-Path -LiteralPath $referenceAssemblies -PathType Container)) {
    throw ".NET Framework 4.8 targeting pack directory is missing: $referenceAssemblies"
}
foreach ($assembly in $requiredReferences) {
    $assemblyPath = Join-Path $referenceAssemblies $assembly
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw ".NET Framework 4.8 reference assembly is missing: $assemblyPath"
    }
}

Write-ActionOutput -Name 'release' -Value ([string]$release)
Write-ActionOutput -Name 'runtime-version' -Value $runtimeVersion
Write-ActionOutput -Name 'sdk-path' -Value $sdkRegistryPath.TrimEnd('\')
Write-ActionOutput -Name 'reference-assemblies' -Value $referenceAssemblies
Write-Host ".NET Framework 4.8 developer prerequisites validated (release $release)."
