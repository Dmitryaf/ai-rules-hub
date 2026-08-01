[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [ValidateSet('Plan', 'Apply')]
    [string]$Mode = 'Plan',

    [string]$RevisionOverride,

    [switch]$FailOnConflict
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

function Get-ManagedRelativePath {
    param([Parameter(Mandatory = $true)][string]$SourceRelativePath)

    $normalizedSource = $SourceRelativePath.Replace('\', '/')
    if ($normalizedSource -eq 'rules/CORE.md') {
        return 'CORE.md'
    }

    return $normalizedSource
}

$hubRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$projectRootFull = (Resolve-Path -LiteralPath $ProjectRoot).Path
$catalogPath = Join-Path $hubRoot 'sync/catalog.json'
$catalog = Get-JsonFile -Path $catalogPath

if ($catalog.schemaVersion -ne '0.1') {
    throw "Unsupported catalog schemaVersion: $($catalog.schemaVersion)"
}

$localRulesRoot = Get-SafePath -BasePath $projectRootFull -ChildPath '.ai-rules' -Label 'local rules directory'
$manifestFullPath = Join-Path $localRulesRoot 'manifest.json'
$destinationRoot = Join-Path $localRulesRoot 'upstream'
$destinationRelative = '.ai-rules/upstream'
$lockPath = Join-Path $localRulesRoot 'lock.json'

if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
    throw "Sync manifest was not found: $manifestFullPath"
}

$manifest = Get-JsonFile -Path $manifestFullPath
if ($manifest.schemaVersion -ne '0.2') {
    throw "Unsupported manifest schemaVersion: $($manifest.schemaVersion)"
}

foreach ($requiredProperty in @('source', 'topics', 'profiles')) {
    if ($null -eq $manifest.PSObject.Properties[$requiredProperty]) {
        throw "Manifest property is required: $requiredProperty"
    }
}

if ($null -eq $manifest.source.PSObject.Properties['repository']) {
    throw 'Manifest source.repository is required.'
}
if ([string]$manifest.source.repository -ne 'ai-rules-hub') {
    throw "Unsupported source repository: $($manifest.source.repository)"
}
if ($null -eq $manifest.source.PSObject.Properties['revision']) {
    throw 'Manifest source.revision is required; use null for an unpinned local preparation.'
}

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

if (-not [string]::IsNullOrWhiteSpace($RevisionOverride)) {
    if ($Mode -ne 'Plan') {
        throw 'RevisionOverride is supported only in Plan mode.'
    }
    if ($RevisionOverride -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'RevisionOverride must be a full 40-character Git commit SHA.'
    }
    if ([string]::IsNullOrWhiteSpace($revision)) {
        throw 'RevisionOverride was provided, but the hub Git revision cannot be determined.'
    }
    if ($revision -ne $RevisionOverride) {
        throw "RevisionOverride must match the current hub checkout. Expected $RevisionOverride, got $revision."
    }
    $expectedRevision = $RevisionOverride
}

if (-not [string]::IsNullOrWhiteSpace($expectedRevision)) {
    if ($expectedRevision -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Manifest source.revision must be a full 40-character Git commit SHA.'
    }
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
    if ($previousLock.schemaVersion -ne '0.2') {
        throw "Unsupported lock schemaVersion: $($previousLock.schemaVersion)"
    }
    if ([string]$previousLock.manifest -ne '.ai-rules/manifest.json') {
        throw "Unsupported lock manifest path: $($previousLock.manifest)"
    }
    if ([string]$previousLock.managedRoot -ne $destinationRelative) {
        throw "Unsupported lock managed root: $($previousLock.managedRoot)"
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

    $managedRelativePath = Get-ManagedRelativePath -SourceRelativePath $sourceRelativePath
    $targetFullPath = Get-SafePath -BasePath $destinationRoot -ChildPath $managedRelativePath -Label 'managed target'
    $targetRelativePath = Get-RelativePathFromRoot -Root $projectRootFull -Path $targetFullPath
    if (-not $selectedTargets.Add($targetRelativePath)) {
        throw "Multiple catalog sources resolve to the same managed target: $targetRelativePath"
    }

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

    $managedPrefix = $destinationRelative.TrimEnd('/') + '/'
    if (-not $oldTarget.StartsWith($managedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Locked target is outside the managed upstream directory: $oldTarget"
    }
    $oldManagedRelativePath = $oldTarget.Substring($managedPrefix.Length)
    $oldTargetFullPath = Get-SafePath -BasePath $destinationRoot -ChildPath $oldManagedRelativePath -Label 'locked target'
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
Write-Host "Manifest: .ai-rules/manifest.json"
Write-Host "Managed root: $destinationRelative"
$plan | Select-Object Action, Source, Target | Format-Table -AutoSize

$actionOrder = @('add', 'update', 'unchanged', 'conflict', 'orphan', 'orphan-modified', 'orphan-missing')
$summaryParts = @(
    foreach ($actionName in $actionOrder) {
        $count = @($plan | Where-Object { $_.Action -eq $actionName }).Count
        if ($count -gt 0) {
            "${actionName}=$count"
        }
    }
)
Write-Host "Summary: $($summaryParts -join ', ')"

if ($Mode -eq 'Plan') {
    Write-Host 'Plan only: no project files were changed.' -ForegroundColor Green
    $planConflicts = @($plan | Where-Object { $_.Action -eq 'conflict' })
    if ($planConflicts.Count -gt 0) {
        Write-Host 'Resolve managed-file conflicts before Apply.' -ForegroundColor Yellow
        if ($FailOnConflict) {
            throw "Plan stopped: $($planConflicts.Count) managed file conflict(s) require manual resolution."
        }
    }
    else {
        Write-Host 'Next: review this plan and the selected revision, then run the same command with -Mode Apply.'
    }
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

$generatedAtUtc = [DateTime]::UtcNow.ToString('o')
if ($null -ne $previousLock -and -not [string]::IsNullOrWhiteSpace([string]$previousLock.generatedAtUtc)) {
    $generatedAtUtc = [string]$previousLock.generatedAtUtc
}

$lockObject = [ordered]@{
    schemaVersion = '0.2'
    generatedAtUtc = $generatedAtUtc
    source = [ordered]@{
        repository = 'ai-rules-hub'
        revision = $revision
        dirty = $sourceDirty
        catalogVersion = $catalog.schemaVersion
    }
    manifest = '.ai-rules/manifest.json'
    managedRoot = $destinationRelative
    topics = @($selectedTopics | Sort-Object)
    profiles = @($manifest.profiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    files = $lockEntries
}

$lockJson = $lockObject | ConvertTo-Json -Depth 10
$lockChanged = $true
if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    $existingLockJson = [System.IO.File]::ReadAllText($lockPath).TrimEnd([char[]]@("`r", "`n"))
    if ($existingLockJson -eq $lockJson.TrimEnd([char[]]@("`r", "`n"))) {
        $lockChanged = $false
    }
}

if ($lockChanged) {
    $lockObject.generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $lockJson = $lockObject | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $lockPath -Value $lockJson -Encoding UTF8
    Write-Host "Lock updated: $lockPath" -ForegroundColor Green
}
else {
    Write-Host "Lock unchanged: $lockPath" -ForegroundColor Green
}

Write-Host 'Sync applied.' -ForegroundColor Green
