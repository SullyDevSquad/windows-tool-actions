Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-WindowsRunner {
    if (-not $IsWindows) {
        throw 'This action supports Windows runners only.'
    }
}

function Assert-GitHubFileCommand {
    param(
        [Parameter(Mandatory)]
        [string]$EnvironmentVariable
    )

    $path = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "$EnvironmentVariable is not set. Run this script from a GitHub Actions step."
    }
    return $path
}

function Write-ActionOutput {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]*$')]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "Output '$Name' must be a single line."
    }
    $outputFile = Assert-GitHubFileCommand -EnvironmentVariable 'GITHUB_OUTPUT'
    Add-Content -LiteralPath $outputFile -Value "$Name=$Value" -Encoding utf8
}

function Add-ActionPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "PATH directory does not exist: $Path"
    }
    $pathFile = Assert-GitHubFileCommand -EnvironmentVariable 'GITHUB_PATH'
    Add-Content -LiteralPath $pathFile -Value $Path -Encoding utf8
}

function Set-ActionEnvironment {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "Environment value '$Name' must be a single line."
    }
    $environmentFile = Assert-GitHubFileCommand -EnvironmentVariable 'GITHUB_ENV'
    Add-Content -LiteralPath $environmentFile -Value "$Name=$Value" -Encoding utf8
}

function Add-SecretMask {
    param([AllowEmptyString()][string]$Value)

    if (-not [string]::IsNullOrEmpty($Value)) {
        $escaped = $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host "::add-mask::$escaped"
    }
}

function Get-NormalizedSha256 {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[a-f0-9]{64}$') {
        throw 'A SHA-256 value must contain exactly 64 hexadecimal characters.'
    }
    return $normalized
}

function Assert-HttpsUri {
    param([Parameter(Mandatory)][string]$Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne [Uri]::UriSchemeHttps -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw 'Download URL must be an absolute HTTPS URL without embedded credentials.'
    }
    return $uri
}

function Invoke-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$Destination
    )

    $validatedUri = Assert-HttpsUri -Value $Uri
    $expectedHash = Get-NormalizedSha256 -Value $Sha256
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(15)
    [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd('windows-tool-actions/1.0')
    try {
        $currentUri = $validatedUri
        $response = $null
        for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {
            $response = $client.GetAsync(
                $currentUri,
                [Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -notin 301, 302, 303, 307, 308) {
                break
            }
            if ($redirectCount -eq 5 -or $null -eq $response.Headers.Location) {
                throw 'The approved download URL exceeded the HTTPS redirect limit or returned an invalid redirect.'
            }
            $location = $response.Headers.Location
            $nextUri = if ($location.IsAbsoluteUri) {
                $location
            }
            else {
                [Uri]::new($currentUri, $location)
            }
            $response.Dispose()
            $response = $null
            $currentUri = Assert-HttpsUri -Value $nextUri.AbsoluteUri
        }

        if ($null -eq $response) {
            throw 'The approved download URL did not return a response.'
        }
        $response.EnsureSuccessStatusCode()
        $inputStream = $response.Content.ReadAsStream()
        $outputStream = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::Create,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $inputStream.CopyTo($outputStream)
        }
        finally {
            $outputStream.Dispose()
            $inputStream.Dispose()
            $response.Dispose()
        }

        $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 verification failed. Expected $expectedHash but received $actualHash."
        }
    }
    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function ConvertFrom-JsonArgumentArray {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$InputName
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return [string[]]@()
    }
    try {
        $value = ConvertFrom-Json -InputObject $Json -NoEnumerate
    }
    catch {
        throw "$InputName must be a JSON array of strings."
    }
    if ($value -isnot [System.Array]) {
        throw "$InputName must be a JSON array of strings."
    }
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $value) {
        if ($item -isnot [string]) {
            throw "$InputName must contain strings only."
        }
        $result.Add($item)
    }
    return $result.ToArray()
}

function Invoke-DirectProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$SuppressOutput
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable does not exist: $FilePath"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start process: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            if ($SuppressOutput) {
                throw "Process failed with exit code $($process.ExitCode): $FilePath"
            }
            throw "Process failed with exit code $($process.ExitCode): $FilePath`n$stderr"
        }
        if (-not $SuppressOutput -and -not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Verbose $stderr
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}
