[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('audit')]
    [string]$Name
)

$ErrorActionPreference = 'Stop'
$hubRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

switch ($Name) {
    'audit' {
        $promptPath = Join-Path $hubRoot 'templates/PROJECT_AUDIT_PROMPT.md'
    }
}

$promptDocument = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8
$promptMatch = [regex]::Match($promptDocument, '(?ms)^```text\s*\r?\n(?<prompt>.*?)\r?\n```\s*$')
if (-not $promptMatch.Success) {
    throw "Не удалось прочитать готовый запрос из $promptPath."
}

Write-Output $promptMatch.Groups['prompt'].Value.Trim()
