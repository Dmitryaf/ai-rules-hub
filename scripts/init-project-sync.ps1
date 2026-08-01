[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [string[]]$Topics = @(),

    [string[]]$Profiles = @(),

    [switch]$SeedProjectFiles
)

$ErrorActionPreference = 'Stop'

function Get-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Label must be relative: $RelativePath"
    }

    $rootFullPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $RelativePath))
    $prefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the project root: $RelativePath"
    }

    return $candidate
}

$hubRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$projectRootFull = (Resolve-Path -LiteralPath $ProjectRoot).Path
$catalogPath = Join-Path $hubRoot 'sync/catalog.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($catalog.schemaVersion -ne '0.1') {
    throw "Unsupported catalog schemaVersion: $($catalog.schemaVersion)"
}

$availableTopics = @($catalog.topics.PSObject.Properties.Name)
$availableProfiles = @($catalog.profiles.PSObject.Properties.Name)

$Topics = @(
    foreach ($topicValue in @($Topics)) {
        foreach ($topicPart in ([string]$topicValue -split ',')) {
            if (-not [string]::IsNullOrWhiteSpace($topicPart)) {
                $topicPart.Trim()
            }
        }
    }
)
$Profiles = @(
    foreach ($profileValue in @($Profiles)) {
        foreach ($profilePart in ([string]$profileValue -split ',')) {
            if (-not [string]::IsNullOrWhiteSpace($profilePart)) {
                $profilePart.Trim()
            }
        }
    }
)

foreach ($topic in $Topics) {
    if ($topic -notin $availableTopics) {
        throw "Unknown topic '$topic'. Available: $($availableTopics -join ', ')"
    }
}

foreach ($profile in $Profiles) {
    if ($profile -notin $availableProfiles) {
        throw "Unknown profile '$profile'. Available: $($availableProfiles -join ', ')"
    }
}

$localRulesRoot = Get-PathInsideRoot -Root $projectRootFull -RelativePath '.ai-rules' -Label 'Local rules directory'
$manifestPath = Join-Path $localRulesRoot 'manifest.json'
$legacyPaths = @(
    (Join-Path $projectRootFull '.ai-rules-hub.json'),
    (Join-Path $projectRootFull '.ai-rules-hub.lock.json')
)

foreach ($legacyPath in $legacyPaths) {
    if (Test-Path -LiteralPath $legacyPath) {
        throw "Legacy sync file detected. Review and migrate it explicitly before initialization: $legacyPath"
    }
}

if (Test-Path -LiteralPath $manifestPath) {
    throw "Sync manifest already exists and will not be overwritten: $manifestPath"
}

if (-not (Test-Path -LiteralPath $localRulesRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $localRulesRoot | Out-Null
    Write-Host "Created directory: $localRulesRoot" -ForegroundColor Green
}

$manifest = [ordered]@{
    schemaVersion = '0.2'
    source = [ordered]@{
        repository = 'ai-rules-hub'
        revision = $null
    }
    topics = @($Topics | Sort-Object -Unique)
    profiles = @($Profiles | Sort-Object -Unique)
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "Created: $manifestPath" -ForegroundColor Green

if ($SeedProjectFiles) {
    $seedFiles = @(
        [pscustomobject]@{ Name = 'AGENTS.md'; TargetRoot = $projectRootFull },
        [pscustomobject]@{ Name = 'RULESET.md'; TargetRoot = $localRulesRoot },
        [pscustomobject]@{ Name = 'PROJECT_RULES.md'; TargetRoot = $localRulesRoot }
    )

    foreach ($seedFile in $seedFiles) {
        $sourcePath = Join-Path $hubRoot "templates/$($seedFile.Name)"
        $targetPath = Join-Path $seedFile.TargetRoot $seedFile.Name
        if (Test-Path -LiteralPath $targetPath) {
            Write-Host "Skipped existing local file: $targetPath" -ForegroundColor Yellow
            continue
        }

        Copy-Item -LiteralPath $sourcePath -Destination $targetPath
        Write-Host "Seeded local file: $targetPath" -ForegroundColor Green
    }
}

Write-Host 'Initialization does not apply synchronization.'
$syncScriptPath = Join-Path $hubRoot 'scripts/sync-rules.ps1'
Write-Host "Next: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$syncScriptPath`" -ProjectRoot `"$projectRootFull`" -Mode Plan"
