[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$gitDirectory = Join-Path $repoRoot '.git'
$hookPath = Join-Path $repoRoot '.githooks/commit-msg'

if (-not (Test-Path -LiteralPath $gitDirectory)) {
    throw "Git metadata was not found at $gitDirectory"
}

if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
    throw "Commit hook was not found at $hookPath"
}

& git -C $repoRoot config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure core.hooksPath.'
}

$configuredPath = (& git -C $repoRoot config --get core.hooksPath).Trim()
if ($configuredPath -ne '.githooks') {
    throw "Unexpected core.hooksPath after installation: $configuredPath"
}

Write-Host 'Git hooks configured: core.hooksPath=.githooks' -ForegroundColor Green
