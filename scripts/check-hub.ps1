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
    'ai-rules.ps1',
    'CONTRIBUTING.md',
    '.github/SECURITY.md',
    'rules/README.md',
    'rules/CORE.md',
    'hub/PROJECT_RULES.md',
    'hub/ARCHITECTURE.md',
    'hub/COMMIT_RULES.md',
    'profiles/README.md',
    'templates/README.md',
    'templates/PROJECT_RULES.full.md',
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

$licenseCandidates = @('LICENSE', 'LICENSE.md', 'LICENSE.txt')
if (-not ($licenseCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf })) {
    $errors.Add('Public repository has no root LICENSE, LICENSE.md, or LICENSE.txt. License selection requires an explicit owner decision.')
}

$githubContributingCandidates = @('CONTRIBUTING.md', '.github/CONTRIBUTING.md')
if (-not ($githubContributingCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf })) {
    $errors.Add('Public repository has no GitHub-discoverable CONTRIBUTING.md.')
}

$securityPolicyPath = Join-Path $repoRoot '.github/SECURITY.md'
if (-not (Test-Path -LiteralPath $securityPolicyPath -PathType Leaf)) {
    $errors.Add('Public repository has no .github/SECURITY.md.')
}

$workflowRoot = Join-Path $repoRoot '.github/workflows'
if (Test-Path -LiteralPath $workflowRoot -PathType Container) {
    $workflowFiles = Get-ChildItem -LiteralPath $workflowRoot -File |
        Where-Object { $_.Extension -in @('.yml', '.yaml') }

    foreach ($workflowFile in $workflowFiles) {
        $workflowRelativePath = Get-RepoRelativePath -Path $workflowFile.FullName
        $workflowContent = Get-Content -LiteralPath $workflowFile.FullName -Raw -Encoding UTF8

        if ($workflowContent -notmatch '(?m)^permissions:\s*\r?\n(?:(?:^[ \t]+[^\r\n]*\r?\n)*)^[ \t]+contents:\s*read\s*(?:#.*)?$') {
            $errors.Add("Workflow must declare top-level read-only contents permission: $workflowRelativePath")
        }
        if ($workflowContent -match '(?im)^\s*permissions:\s*write-all\s*(?:#.*)?$' -or $workflowContent -match '(?im)^\s*[a-z][a-z-]*:\s*write\s*(?:#.*)?$') {
            $errors.Add("Workflow must not declare write permissions: $workflowRelativePath")
        }

        foreach ($actionMatch in [regex]::Matches($workflowContent, '(?m)^\s*(?:-\s*)?uses:\s*(?<reference>[^\s#]+)')) {
            $actionReference = $actionMatch.Groups['reference'].Value
            if ($actionReference.StartsWith('./') -or $actionReference.StartsWith('.\\')) {
                continue
            }

            if ($actionReference.StartsWith('docker://')) {
                if ($actionReference -notmatch '^docker://[^@\s]+@sha256:[0-9a-fA-F]{64}$') {
                    $errors.Add("Docker action must be pinned by sha256 digest in ${workflowRelativePath}: $actionReference")
                }
                continue
            }

            if ($actionReference -notmatch '^[^@\s]+@[0-9a-fA-F]{40}$') {
                $errors.Add("Action must be pinned to a full 40-character commit SHA in ${workflowRelativePath}: $actionReference")
            }
        }

        if ($workflowContent -match 'uses:\s*actions/checkout@' -and $workflowContent -notmatch '(?m)^\s+persist-credentials:\s*false\s*(?:#.*)?$') {
            $errors.Add("actions/checkout must disable persisted credentials in $workflowRelativePath")
        }
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
            if ([string]::IsNullOrWhiteSpace([string]$topicProperty.Value.file)) {
                $errors.Add("Topic '$($topicProperty.Name)' has no file.")
            }
            if ([string]::IsNullOrWhiteSpace([string]$topicProperty.Value.description)) {
                $errors.Add("Topic '$($topicProperty.Name)' has no description.")
            }
            $catalogSources.Add([string]$topicProperty.Value.file)
        }
        foreach ($profileProperty in $catalog.profiles.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace([string]$profileProperty.Value.description)) {
                $errors.Add("Profile '$($profileProperty.Name)' has no description.")
            }
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
