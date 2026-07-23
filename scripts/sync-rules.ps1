[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [ValidateSet('Plan', 'Apply')]
    [string]$Mode = 'Plan',

    [string]$ManifestPath = '.ai-rules-hub.json'
)

$ErrorActionPreference = 'Stop'

function Get-SafePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([System.IO.Path]::IsPathRooted($ChildPath)) {
        throw "$Label must be relative: $ChildPath"
    }

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@('\', '/'))
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $baseFullPath $ChildPath))
    $prefix = $baseFullPath + [System.IO.Path]::DirectorySeparatorChar

    if (
        $candidate -ne $baseFullPath -and
        -not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "$Label escapes its allowed root: $ChildPath"
    }

    return $candidate
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $pathFullPath = [System.IO.Path]::GetFullPath($Path)
    return $pathFullPath.Substring($rootFullPath.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $textExtensions = @('.md', '.json', '.yml', '.yaml', '.txt')
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -in $textExtensions) {
        $content = [System.IO.File]::ReadAllText($Path)
        $normalizedContent = $content.Replace("`r`n", "`n").Replace("`r", "`n")
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        $bytes = $utf8WithoutBom.GetBytes($normalizedContent)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($bytes)
            return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        finally {
            $sha256.Dispose()
        }
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
}

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Unknown ${Label}: $Name"
    }

    return $property.Value
}

$hubRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$projectRootFull = (Resolve-Path -LiteralPath $ProjectRoot).Path
$catalogPath = Join-Path $hubRoot 'sync/catalog.json'
$catalog = Get-JsonFile -Path $catalogPath

if ($catalog.schemaVersion -ne '0.1') {
    throw "Unsupported catalog schemaVersion: $($catalog.schemaVersion)"
}

if ([System.IO.Path]::IsPathRooted($ManifestPath)) {
    $manifestFullPath = [System.IO.Path]::GetFullPath($ManifestPath)
    $projectPrefix = $projectRootFull.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $manifestFullPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest must be inside the target project: $ManifestPath"
    }
}
else {
    $manifestFullPath = Get-SafePath -BasePath $projectRootFull -ChildPath $ManifestPath -Label 'ManifestPath'
}

if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
    throw "Sync manifest was not found: $manifestFullPath"
}

$manifest = Get-JsonFile -Path $manifestFullPath
if ($manifest.schemaVersion -ne '0.1') {
    throw "Unsupported manifest schemaVersion: $($manifest.schemaVersion)"
}

if ([string]::IsNullOrWhiteSpace([string]$manifest.destination)) {
    throw 'Manifest destination is required.'
}

$destinationRoot = Get-SafePath -BasePath $projectRootFull -ChildPath ([string]$manifest.destination) -Label 'destination'
$destinationRelative = ([string]$manifest.destination).Replace('\', '/').TrimEnd('/')
if (
    $destinationRoot -eq $projectRootFull -or
    $destinationRelative -eq '.git' -or
    $destinationRelative.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw "Manifest destination must be a dedicated managed directory outside .git: $($manifest.destination)"
}

if (
    $null -ne $manifest.source -and
    $null -ne $manifest.source.repository -and
    -not [string]::IsNullOrWhiteSpace([string]$manifest.source.repository) -and
    [string]$manifest.source.repository -ne 'ai-rules-hub'
) {
    throw "Unsupported source repository: $($manifest.source.repository)"
}

$lockPath = Join-Path $projectRootFull '.ai-rules-hub.lock.json'

$selectedSources = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$selectedTopics = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($coreFile in @($catalog.core)) {
    [void]$selectedSources.Add([string]$coreFile)
}

foreach ($topicName in @($manifest.topics)) {
    $topicFile = Get-ObjectProperty -Object $catalog.topics -Name ([string]$topicName) -Label 'topic'
    [void]$selectedTopics.Add([string]$topicName)
    [void]$selectedSources.Add([string]$topicFile)
}

foreach ($profileName in @($manifest.profiles)) {
    $profile = Get-ObjectProperty -Object $catalog.profiles -Name ([string]$profileName) -Label 'profile'
    [void]$selectedSources.Add([string]$profile.file)

    foreach ($topicName in @($profile.topics)) {
        $topicFile = Get-ObjectProperty -Object $catalog.topics -Name ([string]$topicName) -Label 'profile topic'
        [void]$selectedTopics.Add([string]$topicName)
        [void]$selectedSources.Add([string]$topicFile)
    }
}

$revision = $null
$sourceDirty = $null
try {
    $revisionOutput = @(& git -C $hubRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $revisionOutput.Count -gt 0) {
        $revision = [string]$revisionOutput[0]
    }

    $dirtyOutput = @(& git -C $hubRoot status --porcelain 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $sourceDirty = $dirtyOutput.Count -gt 0
    }
}
catch {
    $revision = $null
    $sourceDirty = $null
}

$expectedRevision = $null
if ($null -ne $manifest.source -and $null -ne $manifest.source.revision) {
    $expectedRevision = [string]$manifest.source.revision
}

if (-not [string]::IsNullOrWhiteSpace($expectedRevision)) {
    if ([string]::IsNullOrWhiteSpace($revision)) {
        throw 'Manifest pins a revision, but the hub Git revision cannot be determined.'
    }
    if ($revision -ne $expectedRevision) {
        throw "Hub revision mismatch. Expected $expectedRevision, got $revision."
    }
    if ($sourceDirty -eq $true -and $Mode -eq 'Apply') {
        throw 'Pinned synchronization cannot apply from a dirty hub checkout.'
    }
}

$previousLock = $null
$oldByTarget = @{}
if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    $previousLock = Get-JsonFile -Path $lockPath
    if ($previousLock.schemaVersion -ne '0.1') {
        throw "Unsupported lock schemaVersion: $($previousLock.schemaVersion)"
    }

    foreach ($entry in @($previousLock.files)) {
        $oldByTarget[[string]$entry.target] = $entry
    }
}

$plan = [System.Collections.Generic.List[object]]::new()
$selectedTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($sourceRelativePath in @($selectedSources) | Sort-Object) {
    $sourceFullPath = Get-SafePath -BasePath $hubRoot -ChildPath $sourceRelativePath -Label 'catalog source'
    if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
        throw "Catalog source does not exist: $sourceRelativePath"
    }

    $targetFullPath = Get-SafePath -BasePath $destinationRoot -ChildPath $sourceRelativePath -Label 'managed target'
    $targetRelativePath = Get-RelativePathFromRoot -Root $projectRootFull -Path $targetFullPath
    [void]$selectedTargets.Add($targetRelativePath)

    $sourceHash = Get-Sha256 -Path $sourceFullPath
    $targetHash = $null
    $action = 'add'

    if (Test-Path -LiteralPath $targetFullPath -PathType Leaf) {
        $targetHash = Get-Sha256 -Path $targetFullPath
        if ($targetHash -eq $sourceHash) {
            $action = 'unchanged'
        }
        elseif ($oldByTarget.ContainsKey($targetRelativePath) -and $oldByTarget[$targetRelativePath].sha256 -eq $targetHash) {
            $action = 'update'
        }
        else {
            $action = 'conflict'
        }
    }

    $plan.Add([pscustomobject]@{
        Action = $action
        Source = $sourceRelativePath
        Target = $targetRelativePath
        SourcePath = $sourceFullPath
        TargetPath = $targetFullPath
        Sha256 = $sourceHash
        Managed = $true
    })
}

foreach ($oldTarget in @($oldByTarget.Keys) | Sort-Object) {
    if ($selectedTargets.Contains($oldTarget)) {
        continue
    }

    $oldTargetFullPath = Get-SafePath -BasePath $projectRootFull -ChildPath $oldTarget -Label 'locked target'
    $orphanAction = 'orphan-missing'
    if (Test-Path -LiteralPath $oldTargetFullPath -PathType Leaf) {
        $oldTargetHash = Get-Sha256 -Path $oldTargetFullPath
        if ($oldTargetHash -eq $oldByTarget[$oldTarget].sha256) {
            $orphanAction = 'orphan'
        }
        else {
            $orphanAction = 'orphan-modified'
        }
    }

    $plan.Add([pscustomobject]@{
        Action = $orphanAction
        Source = [string]$oldByTarget[$oldTarget].source
        Target = $oldTarget
        SourcePath = $null
        TargetPath = $oldTargetFullPath
        Sha256 = [string]$oldByTarget[$oldTarget].sha256
        Managed = $false
    })
}

Write-Host "Hub revision: $revision"
Write-Host "Hub dirty: $sourceDirty"
Write-Host "Destination: $($manifest.destination)"
$plan | Select-Object Action, Source, Target | Format-Table -AutoSize

if ($Mode -eq 'Plan') {
    exit 0
}

$conflicts = @($plan | Where-Object { $_.Action -eq 'conflict' })
if ($conflicts.Count -gt 0) {
    throw "Apply stopped: $($conflicts.Count) managed file conflict(s) require manual resolution."
}

foreach ($item in @($plan | Where-Object { $_.Action -in @('add', 'update') })) {
    $targetDirectory = Split-Path -Parent $item.TargetPath
    if (-not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $item.SourcePath -Destination $item.TargetPath -Force
}

$lockEntries = @(
    $plan |
        Sort-Object Target |
        ForEach-Object {
            [ordered]@{
                source = $_.Source
                target = $_.Target
                sha256 = $_.Sha256
                state = $(if ($_.Managed) { 'managed' } else { 'orphan' })
            }
        }
)

$lockObject = [ordered]@{
    schemaVersion = '0.1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    source = [ordered]@{
        repository = 'ai-rules-hub'
        revision = $revision
        dirty = $sourceDirty
        catalogVersion = $catalog.schemaVersion
    }
    destination = [string]$manifest.destination
    topics = @($selectedTopics | Sort-Object)
    profiles = @($manifest.profiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    files = $lockEntries
}

$lockJson = $lockObject | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $lockPath -Value $lockJson -Encoding UTF8

Write-Host "Sync applied. Lock updated: $lockPath" -ForegroundColor Green
