. (Join-Path $PSScriptRoot '../../scripts/ActionHelpers.ps1')

if ($env:INPUT_NODE_VERSION -notmatch '^\d+$') {
    throw 'node-version must be an explicit Node.js LTS major, such as 24.'
}
$major = [int]$env:INPUT_NODE_VERSION
if ($major -lt 18 -or $major % 2 -ne 0) {
    throw "node-version '$major' is not a supported even-numbered LTS major."
}
if ($env:INPUT_CACHE -notin @('', 'npm')) {
    throw "cache must be 'npm' or an empty string."
}
