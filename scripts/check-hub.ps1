[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$errors = [System.Collections.Generic.List[string]]::new()

function Get-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    return $absolutePath.Substring($repoRoot.Length).TrimStart([char[]]@('\', '/'))
}

$requiredPaths = @(
    'AGENTS.md',
    'README.md',
    'rules/README.md',
    'rules/CORE.md',
    'hub/PROJECT_RULES.md',
    'hub/ARCHITECTURE.md',
    'hub/COMMIT_RULES.md',
    'hub/SOURCE_PROVENANCE.md',
    'profiles/README.md',
    'templates/README.md',
    'sync/README.md',
    'sync/catalog.json',
    'sync/project-manifest.schema.json',
    'scripts/validate-commit-message.ps1',
    'scripts/sync-rules.ps1',
    'scripts/init-project-sync.ps1',
    '.githooks/commit-msg',
    '.github/workflows/validate.yml',
    'tests/test-tooling.ps1'
)

foreach ($requiredPath in $requiredPaths) {
    $absolutePath = Join-Path $repoRoot $requiredPath
    if (-not (Test-Path -LiteralPath $absolutePath)) {
        $errors.Add("Missing required path: $requiredPath")
    }
}

$markdownFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.md' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

$linkPattern = [regex]'\[[^\]]*\]\((?<target>[^)]+)\)'

foreach ($file in $markdownFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

    foreach ($match in $linkPattern.Matches($content)) {
        $target = $match.Groups['target'].Value.Trim()

        if ($target.StartsWith('<') -and $target.EndsWith('>')) {
            $target = $target.Substring(1, $target.Length - 2)
        }

        if (
            $target.StartsWith('#') -or
            $target -match '^(?i:https?|mailto|tel):'
        ) {
            continue
        }

        $pathPart = ($target -split '#', 2)[0]
        if ([string]::IsNullOrWhiteSpace($pathPart)) {
            continue
        }

        $decodedPath = [Uri]::UnescapeDataString($pathPart)
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $decodedPath))

        if (-not (Test-Path -LiteralPath $candidate)) {
            $relativeFile = Get-RepoRelativePath -Path $file.FullName
            $errors.Add("Broken local link in ${relativeFile}: $target")
        }
    }
}

$catalogPath = Join-Path $repoRoot 'sync/catalog.json'
if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
    try {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($catalog.schemaVersion -ne '0.1') {
            $errors.Add("Unsupported catalog schemaVersion: $($catalog.schemaVersion)")
        }

        $catalogSources = [System.Collections.Generic.List[string]]::new()
        foreach ($coreFile in @($catalog.core)) {
            $catalogSources.Add([string]$coreFile)
        }
        foreach ($topicProperty in $catalog.topics.PSObject.Properties) {
            $catalogSources.Add([string]$topicProperty.Value)
        }
        foreach ($profileProperty in $catalog.profiles.PSObject.Properties) {
            $catalogSources.Add([string]$profileProperty.Value.file)
            foreach ($profileTopic in @($profileProperty.Value.topics)) {
                if ($null -eq $catalog.topics.PSObject.Properties[[string]$profileTopic]) {
                    $errors.Add("Profile '$($profileProperty.Name)' references unknown topic: $profileTopic")
                }
            }
        }

        foreach ($catalogSource in $catalogSources) {
            if ([System.IO.Path]::IsPathRooted($catalogSource) -or $catalogSource -match '(^|[\\/])\.\.([\\/]|$)') {
                $errors.Add("Catalog source must stay inside the hub: $catalogSource")
                continue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $catalogSource) -PathType Leaf)) {
                $errors.Add("Catalog source does not exist: $catalogSource")
            }
        }
    }
    catch {
        $errors.Add("Invalid sync catalog: $($_.Exception.Message)")
    }
}

$jsonFiles = @(
    'sync/project-manifest.schema.json',
    'sync/project-manifest.example.json'
)
foreach ($jsonFile in $jsonFiles) {
    $jsonPath = Join-Path $repoRoot $jsonFile
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        try {
            Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
        }
        catch {
            $errors.Add("Invalid JSON in ${jsonFile}: $($_.Exception.Message)")
        }
    }
}

$textFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and (
            $_.Extension -in @('.md', '.ps1', '.json', '.yml', '.yaml') -or
            $_.Name -eq '.gitattributes' -or
            $_.FullName -match '[\\/]\.githooks[\\/]'
        )
    }

foreach ($file in $textFiles) {
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
        $lineNumber++
        if ($line -match '[ \t]+$') {
            $relativeFile = Get-RepoRelativePath -Path $file.FullName
            $errors.Add("Trailing whitespace in ${relativeFile}:$lineNumber")
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Hub validation failed with $($errors.Count) error(s):" -ForegroundColor Red
    foreach ($validationError in $errors) {
        Write-Host "- $validationError" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Hub validation passed: $($markdownFiles.Count) Markdown and $($textFiles.Count) text files checked." -ForegroundColor Green
