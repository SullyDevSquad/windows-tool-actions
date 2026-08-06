. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')
Assert-WindowsRunner

[void](Assert-HttpsUri -Value $env:INPUT_BINARY_URL)
$expectedHash = Get-NormalizedSha256 -Value $env:INPUT_SHA256
$toolCache = $env:RUNNER_TOOL_CACHE
if ([string]::IsNullOrWhiteSpace($toolCache)) {
    throw 'RUNNER_TOOL_CACHE is not set.'
}

$cacheDirectory = Join-Path $toolCache (Join-Path 'msxsl' (Join-Path $expectedHash 'x64'))
$executable = Join-Path $cacheDirectory 'msxsl.exe'
$cacheHit = $false
if (Test-Path -LiteralPath $executable -PathType Leaf) {
    $actualHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -eq $expectedHash) {
        $cacheHit = $true
    }
    else {
        Remove-Item -LiteralPath $executable -Force
    }
}

if (-not $cacheHit) {
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    $download = Join-Path $cacheDirectory 'msxsl.download'
    try {
        Invoke-VerifiedDownload `
            -Uri $env:INPUT_BINARY_URL `
            -Sha256 $expectedHash `
            -Destination $download
        Move-Item -LiteralPath $download -Destination $executable -Force
    }
    finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    }
}

$smokeDirectory = Join-Path $cacheDirectory "smoke-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $smokeDirectory -Force | Out-Null
try {
    $xmlPath = Join-Path $smokeDirectory 'input.xml'
    $xslPath = Join-Path $smokeDirectory 'transform.xsl'
    [IO.File]::WriteAllText($xmlPath, '<root><value>ok</value></root>')
    [IO.File]::WriteAllText(
        $xslPath,
        '<?xml version="1.0"?><xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:output method="text"/><xsl:template match="/">msxsl-<xsl:value-of select="/root/value"/></xsl:template></xsl:stylesheet>'
    )
    $output = Invoke-DirectProcess -FilePath $executable -ArgumentList @($xmlPath, $xslPath)
    if ($output.Trim() -ne 'msxsl-ok') {
        throw "MSXSL smoke transform returned unexpected output: '$($output.Trim())'"
    }
}
finally {
    Remove-Item -LiteralPath $smokeDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Add-ActionPath -Path $cacheDirectory
Write-ActionOutput -Name 'path' -Value $executable
Write-ActionOutput -Name 'sha256' -Value $expectedHash
Write-ActionOutput -Name 'cache-hit' -Value $cacheHit.ToString().ToLowerInvariant()
Write-Host 'Checksum-verified MSXSL binary passed a minimal XML/XSL transform.'
