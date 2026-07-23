[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [string[]]$Topics = @(),

    [string[]]$Profiles = @(),

    [string]$Destination = '.ai-rules',

    [switch]$SeedProjectFiles
)

$ErrorActionPreference = 'Stop'

function Test-RelativePathInsideRoot {
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

[void](Test-RelativePathInsideRoot -Root $projectRootFull -RelativePath $Destination -Label 'Destination')
$normalizedDestination = $Destination.Replace('\', '/').TrimEnd('/')
if (
    $normalizedDestination -eq '.git' -or
    $normalizedDestination.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw "Destination must stay outside .git: $Destination"
}

$manifestPath = Join-Path $projectRootFull '.ai-rules-hub.json'
if (Test-Path -LiteralPath $manifestPath) {
    throw "Sync manifest already exists and will not be overwritten: $manifestPath"
}

$manifest = [ordered]@{
    schemaVersion = '0.1'
    source = [ordered]@{
        repository = 'ai-rules-hub'
        revision = $null
    }
    destination = $normalizedDestination
    topics = @($Topics | Sort-Object -Unique)
    profiles = @($Profiles | Sort-Object -Unique)
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "Created: $manifestPath" -ForegroundColor Green

if ($SeedProjectFiles) {
    $seedFiles = @('AGENTS.md', 'RULESET.md', 'PROJECT_RULES.md')
    foreach ($seedFile in $seedFiles) {
        $sourcePath = Join-Path $hubRoot "templates/$seedFile"
        $targetPath = Join-Path $projectRootFull $seedFile
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
