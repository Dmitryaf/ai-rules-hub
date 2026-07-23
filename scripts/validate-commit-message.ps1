[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MessageFile
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) {
    Write-Error "Commit message file does not exist: $MessageFile"
    exit 1
}

$lines = @(Get-Content -LiteralPath $MessageFile -Encoding UTF8)
if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) {
    Write-Error 'Commit message header is empty.'
    exit 1
}

$header = $lines[0]

if ($header -match '^(Merge .+|Revert ".+")$') {
    exit 0
}

while ($header -match '^(fixup!|squash!) (?<inner>.+)$') {
    $header = $Matches['inner']
}

$types = @('feat', 'fix', 'docs', 'test', 'refactor', 'perf', 'build', 'ci', 'chore', 'revert')
$scopes = @(
    'core', 'product', 'architecture', 'data', 'quality', 'security',
    'docs', 'git', 'ai', 'research', 'profiles', 'templates', 'sync',
    'hub', 'sources', 'tooling'
)

$typePattern = ($types | ForEach-Object { [regex]::Escape($_) }) -join '|'
$scopePattern = ($scopes | ForEach-Object { [regex]::Escape($_) }) -join '|'
$headerPattern = "^(?<type>$typePattern)\((?<scope>$scopePattern)\)(?<breaking>!)?: (?<summary>.+)$"

$problems = [System.Collections.Generic.List[string]]::new()

if ($header.Length -gt 72) {
    $problems.Add("Header is $($header.Length) characters; maximum is 72.")
}

if ($header -notmatch $headerPattern) {
    $problems.Add('Expected: <type>(<scope>): <summary> with an allowed type and scope.')
}
else {
    $summary = $Matches['summary']
    if ($summary -ne $summary.Trim()) {
        $problems.Add('Summary must not have leading or trailing whitespace.')
    }
    if ($summary.EndsWith('.')) {
        $problems.Add('Summary must not end with a period.')
    }
}

if ($lines.Count -gt 1 -and -not [string]::IsNullOrEmpty($lines[1])) {
    $problems.Add('The second line must be empty before body or footer.')
}

for ($index = 1; $index -lt $lines.Count; $index++) {
    if ($lines[$index].Length -gt 100) {
        $problems.Add("Line $($index + 1) is longer than 100 characters.")
    }
    if ($lines[$index] -match '[ \t]+$') {
        $problems.Add("Line $($index + 1) has trailing whitespace.")
    }
}

if ($problems.Count -gt 0) {
    Write-Host 'Invalid commit message:' -ForegroundColor Red
    Write-Host "  $($lines[0])" -ForegroundColor Red
    foreach ($problem in $problems) {
        Write-Host "- $problem" -ForegroundColor Red
    }
    Write-Host "Allowed types: $($types -join ', ')"
    Write-Host "Allowed scopes: $($scopes -join ', ')"
    exit 1
}

exit 0
