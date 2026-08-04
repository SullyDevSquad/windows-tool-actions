. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')

$nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$npmCommand = Get-Command npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand -or $null -eq $npmCommand) {
    throw 'actions/setup-node completed, but node or npm is not on PATH.'
}

$nodeVersion = (& $nodeCommand.Source --version).Trim().TrimStart('v')
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^(?<major>\d+)\.\d+\.\d+') {
    throw "Could not validate Node.js version. Received '$nodeVersion'."
}
if ([int]$Matches.major -ne [int]$env:INPUT_NODE_VERSION) {
    throw "Expected Node.js major $env:INPUT_NODE_VERSION but received $nodeVersion."
}
$npmVersion = (& $npmCommand.Source --version).Trim()
if ($LASTEXITCODE -ne 0 -or $npmVersion -notmatch '^\d+\.\d+\.\d+') {
    throw "Could not validate npm version. Received '$npmVersion'."
}

Write-ActionOutput -Name 'node-version' -Value $nodeVersion
Write-ActionOutput -Name 'npm-version' -Value $npmVersion
Write-Host "Node.js $nodeVersion and npm $npmVersion validated."
