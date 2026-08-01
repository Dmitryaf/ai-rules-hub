[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$ListTarget,

    [string]$ProjectRoot,

    [string[]]$Profiles = @(),

    [string[]]$Topics = @(),

    [switch]$NoSeedProjectFiles,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$hubRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$powerShellExe = (Get-Process -Id $PID).Path
$catalogPath = Join-Path $hubRoot 'sync/catalog.json'
$syncScriptPath = Join-Path $hubRoot 'scripts/sync-rules.ps1'
$initScriptPath = Join-Path $hubRoot 'scripts/init-project-sync.ps1'

function Write-Help {
    @'
AI Rules Hub commands

  help                     Show this help.
  doctor                   Check the hub and show its working tree.
  list profiles            List profiles and the topics they include.
  list topics              List available topics and source files.
  init   -ProjectRoot PATH Initialize a project without applying rules.
  status -ProjectRoot PATH Show connection and synchronization state.
  plan   -ProjectRoot PATH Preview the currently pinned revision.
  apply  -ProjectRoot PATH Apply the currently pinned revision.
  update -ProjectRoot PATH Preview a move to the current hub revision.
  update -ProjectRoot PATH -Apply
                           Accept the current hub revision and apply it.

Examples

  .\ai-rules.ps1 list profiles
  .\ai-rules.ps1 init -ProjectRoot C:\path\to\project -Profiles standard-product
  .\ai-rules.ps1 status -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 plan -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 apply -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 update -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 update -ProjectRoot C:\path\to\project -Apply

plan reads the manifest's pinned revision and changes nothing.
apply accepts that pinned revision after the existing safety checks.
update targets the current hub checkout; it changes files only with -Apply.

No command runs git pull or git fetch automatically.
'@ | Write-Host
}

function Get-Catalog {
    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.schemaVersion -ne '0.1') {
        throw "Unsupported catalog schemaVersion: $($catalog.schemaVersion)"
    }
    return $catalog
}

function ConvertTo-NameList {
    param([string[]]$Values)

    return @(
        foreach ($value in @($Values)) {
            foreach ($part in ([string]$value -split ',')) {
                $name = $part.Trim()
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $name
                }
            }
        }
    )
}

function Assert-Selections {
    param(
        [Parameter(Mandatory = $true)]$Catalog,
        [string[]]$SelectedProfiles,
        [string[]]$SelectedTopics
    )

    $availableProfiles = @($Catalog.profiles.PSObject.Properties.Name)
    $availableTopics = @($Catalog.topics.PSObject.Properties.Name)
    foreach ($profile in @($SelectedProfiles)) {
        if ($profile -notin $availableProfiles) {
            throw "Unknown profile '$profile'. Available: $($availableProfiles -join ', ')"
        }
    }
    foreach ($topic in @($SelectedTopics)) {
        if ($topic -notin $availableTopics) {
            throw "Unknown topic '$topic'. Available: $($availableTopics -join ', ')"
        }
    }
}

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1 | Out-String
        if (-not $Capture -and -not [string]::IsNullOrWhiteSpace($output)) {
            Write-Host $output.TrimEnd()
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
    return @($output)
}

function Get-HubGitState {
    $revisionOutput = @(Invoke-GitText -Arguments @('-C', $hubRoot, 'rev-parse', 'HEAD'))
    $statusOutput = @(Invoke-GitText -Arguments @('-C', $hubRoot, 'status', '--porcelain'))
    $revision = ([string]$revisionOutput[0]).Trim()
    if ($revision -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'The current hub revision is not a full 40-character Git commit SHA.'
    }
    return [pscustomobject]@{
        Revision = $revision
        Dirty = $statusOutput.Count -gt 0
    }
}

function Resolve-ProjectRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Command '$Command' requires -ProjectRoot."
    }
    return (Resolve-Path -LiteralPath $Path).Path
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

function Write-Values {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [object[]]$Values
    )

    Write-Host "${Label}:"
    if (@($Values).Count -eq 0) {
        Write-Host '  (none)'
        return
    }
    foreach ($value in @($Values)) {
        Write-Host "  $value"
    }
}

function Get-PlanState {
    param([Parameter(Mandatory = $true)][string]$Output)

    $summaryMatch = [regex]::Match($Output, '(?m)^Summary:\s*(?<value>.*)$')
    if (-not $summaryMatch.Success) {
        return 'invalid'
    }
    $parts = @($summaryMatch.Groups['value'].Value.Trim() -split ',\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($part in $parts) {
        if ($part -notmatch '^unchanged=\d+$') {
            return 'changes'
        }
    }
    return 'unchanged'
}

function Show-Status {
    param([Parameter(Mandatory = $true)][string]$ResolvedProjectRoot)

    $projectName = Split-Path -Leaf $ResolvedProjectRoot.TrimEnd([char[]]@('\', '/'))
    $localRulesRoot = Join-Path $ResolvedProjectRoot '.ai-rules'
    $manifestPath = Join-Path $localRulesRoot 'manifest.json'
    $lockPath = Join-Path $localRulesRoot 'lock.json'
    $managedRoot = Join-Path $localRulesRoot 'upstream'
    $manifestFound = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $lockFound = Test-Path -LiteralPath $lockPath -PathType Leaf
    $managedRootFound = Test-Path -LiteralPath $managedRoot -PathType Container
    $hubState = Get-HubGitState

    Write-Host "Project: $projectName"
    Write-Host "Project root: $ResolvedProjectRoot"
    Write-Host "Manifest: $(if ($manifestFound) { 'found' } else { 'missing' })"
    Write-Host "Lock: $(if ($lockFound) { 'found' } else { 'missing' })"
    Write-Host "Managed root: $(if ($managedRootFound) { 'found' } else { 'missing' })"
    Write-Host ''
    Write-Host "Hub revision: $($hubState.Revision)"
    Write-Host "Hub dirty: $($hubState.Dirty.ToString().ToLowerInvariant())"

    if (-not $manifestFound) {
        Write-Host ''
        Write-Host 'Manifest revision: unpinned'
        Write-Host 'Lock revision: absent'
        Write-Values -Label 'Profiles' -Values @()
        Write-Values -Label 'Topics' -Values @()
        Write-Host ''
        Write-Host 'Diagnostic: initialize the project before synchronization.'
        Write-Host 'State: not-initialized'
        return
    }

    try {
        $manifest = Get-JsonFile -Path $manifestPath
    }
    catch {
        Write-Host ''
        Write-Host 'Manifest revision: unpinned'
        Write-Host 'Lock revision: absent'
        Write-Values -Label 'Profiles' -Values @()
        Write-Values -Label 'Topics' -Values @()
        Write-Host ''
        Write-Host "Diagnostic: $($_.Exception.Message)"
        Write-Host 'State: inconsistent'
        return
    }
    $structuralDiagnostics = [System.Collections.Generic.List[string]]::new()
    if ($manifest.schemaVersion -ne '0.2') {
        $structuralDiagnostics.Add("unsupported manifest schemaVersion: $($manifest.schemaVersion).")
    }
    foreach ($requiredProperty in @('source', 'topics', 'profiles')) {
        if ($null -eq $manifest.PSObject.Properties[$requiredProperty]) {
            $structuralDiagnostics.Add("manifest property is missing: $requiredProperty.")
        }
    }
    if ($null -eq $manifest.source) {
        $structuralDiagnostics.Add('manifest source is missing.')
    }
    else {
        if ($null -eq $manifest.source.PSObject.Properties['repository'] -or [string]$manifest.source.repository -ne 'ai-rules-hub') {
            $structuralDiagnostics.Add('manifest source.repository is missing or unsupported.')
        }
        if ($null -eq $manifest.source.PSObject.Properties['revision']) {
            $structuralDiagnostics.Add('manifest source.revision property is missing.')
        }
    }
    $manifestRevision = $null
    if ($null -ne $manifest.source -and $null -ne $manifest.source.revision) {
        $manifestRevision = [string]$manifest.source.revision
    }
    $profiles = @($manifest.profiles | ForEach-Object { [string]$_ })
    $topics = @($manifest.topics | ForEach-Object { [string]$_ })
    try {
        Assert-Selections -Catalog (Get-Catalog) -SelectedProfiles $profiles -SelectedTopics $topics
    }
    catch {
        $structuralDiagnostics.Add($_.Exception.Message)
    }
    $lock = $null
    $lockRevision = $null
    if ($lockFound) {
        try {
            $lock = Get-JsonFile -Path $lockPath
            if ($lock.schemaVersion -ne '0.2') {
                $structuralDiagnostics.Add("unsupported lock schemaVersion: $($lock.schemaVersion).")
            }
            if ([string]$lock.manifest -ne '.ai-rules/manifest.json') {
                $structuralDiagnostics.Add('lock manifest path is inconsistent.')
            }
            if ([string]$lock.managedRoot -ne '.ai-rules/upstream') {
                $structuralDiagnostics.Add('lock managed root is inconsistent.')
            }
            if ($null -ne $lock.source -and $null -ne $lock.source.revision) {
                $lockRevision = [string]$lock.source.revision
            }
        }
        catch {
            $structuralDiagnostics.Add($_.Exception.Message)
        }
    }

    Write-Host ''
    Write-Host "Manifest revision: $(if ([string]::IsNullOrWhiteSpace($manifestRevision)) { 'unpinned' } else { $manifestRevision })"
    Write-Host "Lock revision: $(if ([string]::IsNullOrWhiteSpace($lockRevision)) { 'absent' } else { $lockRevision })"
    Write-Values -Label 'Profiles' -Values $profiles
    Write-Values -Label 'Topics' -Values $topics

    $diagnostics = [System.Collections.Generic.List[string]]::new()
    foreach ($structuralDiagnostic in $structuralDiagnostics) {
        $diagnostics.Add($structuralDiagnostic)
    }
    $state = $null
    if ($structuralDiagnostics.Count -gt 0) {
        $state = 'inconsistent'
    }
    elseif ([string]::IsNullOrWhiteSpace($manifestRevision)) {
        $state = 'unpinned'
        $diagnostics.Add('manifest source.revision is not pinned.')
    }
    else {
        if ($manifestRevision -notmatch '^[0-9a-fA-F]{40}$') {
            $diagnostics.Add('manifest revision is not a full commit SHA.')
        }
        if (-not $lockFound) {
            $diagnostics.Add('lock.json is missing for a pinned manifest.')
        }
        if (-not $managedRootFound) {
            $diagnostics.Add('managed upstream root is missing for a pinned manifest.')
        }
        if ($lockFound -and [string]::IsNullOrWhiteSpace($lockRevision)) {
            $diagnostics.Add('lock revision is missing.')
        }
        if (-not [string]::IsNullOrWhiteSpace($lockRevision) -and $lockRevision -notmatch '^[0-9a-fA-F]{40}$') {
            $diagnostics.Add('lock revision is not a full commit SHA.')
        }
        if (-not [string]::IsNullOrWhiteSpace($lockRevision) -and $manifestRevision -ne $lockRevision) {
            $diagnostics.Add('manifest and lock revisions do not match.')
        }

        if ($diagnostics.Count -gt 0) {
            $state = 'inconsistent'
        }
        elseif ($manifestRevision -ne $hubState.Revision) {
            $state = 'update-available'
            $diagnostics.Add('the current hub checkout differs from the project revision.')
        }
        else {
            $planResult = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @(
                '-ProjectRoot', $ResolvedProjectRoot,
                '-Mode', 'Plan'
            ) -Capture
            if ($planResult.ExitCode -ne 0) {
                $state = 'inconsistent'
                $diagnostics.Add('the synchronization plan failed.')
                $diagnostics.Add($planResult.Output.Trim())
            }
            elseif ((Get-PlanState -Output $planResult.Output) -eq 'unchanged') {
                $state = 'synchronized'
            }
            else {
                $state = 'inconsistent'
                $diagnostics.Add('the synchronization plan contains pending changes or unresolved states.')
            }
        }
    }

    Write-Host ''
    foreach ($diagnostic in $diagnostics) {
        Write-Host "Diagnostic: $diagnostic"
    }
    Write-Host "State: $state"
}

function Invoke-Doctor {
    $failed = $false
    foreach ($step in @(
        [pscustomobject]@{ Name = 'Hub structure'; Kind = 'script'; Path = (Join-Path $hubRoot 'scripts/check-hub.ps1') },
        [pscustomobject]@{ Name = 'Tooling tests'; Kind = 'script'; Path = (Join-Path $hubRoot 'tests/test-tooling.ps1') },
        [pscustomobject]@{ Name = 'Diff check'; Kind = 'git'; Path = $null },
        [pscustomobject]@{ Name = 'Working tree'; Kind = 'status'; Path = $null }
    )) {
        Write-Host "`n== $($step.Name) =="
        if ($step.Kind -eq 'script') {
            $result = Invoke-ChildScript -ScriptPath $step.Path
            if ($result.ExitCode -ne 0) {
                $failed = $true
            }
        }
        elseif ($step.Kind -eq 'git') {
            & git -C $hubRoot diff --check
            if ($LASTEXITCODE -ne 0) {
                $failed = $true
            }
        }
        else {
            & git -C $hubRoot status --short
            if ($LASTEXITCODE -ne 0) {
                $failed = $true
            }
        }
    }
    if ($failed) {
        throw 'Hub doctor found one or more failed checks.'
    }
    Write-Host "`nHub doctor passed." -ForegroundColor Green
}

function Invoke-Update {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedProjectRoot,
        [switch]$Accept
    )

    $manifestPath = Join-Path $ResolvedProjectRoot '.ai-rules/manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Sync manifest was not found: $manifestPath"
    }
    $manifest = Get-JsonFile -Path $manifestPath
    if ($null -eq $manifest.source -or $null -eq $manifest.source.PSObject.Properties['revision']) {
        throw 'Manifest source.revision is required; use null for an unpinned local preparation.'
    }
    $currentRevision = $null
    if ($null -ne $manifest.source.revision) {
        $currentRevision = [string]$manifest.source.revision
    }
    $hubState = Get-HubGitState

    Write-Host "Current project revision: $(if ([string]::IsNullOrWhiteSpace($currentRevision)) { 'unpinned' } else { $currentRevision })"
    Write-Host "Target hub revision: $($hubState.Revision)"

    $planArguments = @(
        '-ProjectRoot', $ResolvedProjectRoot,
        '-Mode', 'Plan',
        '-RevisionOverride', $hubState.Revision
    )
    if ($Accept) {
        if ($hubState.Dirty) {
            throw 'Update -Apply requires a clean hub checkout.'
        }
        $planArguments += '-FailOnConflict'
    }
    Write-Host "`nPlan:"
    $planResult = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments $planArguments -Capture
    Write-Host $planResult.Output.TrimEnd()
    if ($planResult.ExitCode -ne 0) {
        throw 'Update plan failed; no project files were changed.'
    }

    if (-not $Accept) {
        Write-Host "`nNo files were changed." -ForegroundColor Green
        Write-Host 'Run the same command with -Apply to accept this revision.'
        return
    }

    $originalManifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $temporaryManifestPath = Join-Path (Split-Path -Parent $manifestPath) "manifest.$([Guid]::NewGuid().ToString('N')).tmp"
    $manifest.source.revision = $hubState.Revision
    $manifestJson = ($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine
    try {
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryManifestPath, $manifestJson, $utf8WithoutBom)
        Move-Item -LiteralPath $temporaryManifestPath -Destination $manifestPath -Force

        $applyResult = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @(
            '-ProjectRoot', $ResolvedProjectRoot,
            '-Mode', 'Apply'
        ) -Capture
        Write-Host "`nApply:"
        Write-Host $applyResult.Output.TrimEnd()
        if ($applyResult.ExitCode -ne 0) {
            throw 'Synchronization Apply failed.'
        }
    }
    catch {
        [System.IO.File]::WriteAllBytes($manifestPath, $originalManifestBytes)
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temporaryManifestPath) {
            Remove-Item -LiteralPath $temporaryManifestPath -Force
        }
    }

    Write-Host "`nRevision accepted and synchronization applied." -ForegroundColor Green
    Write-Host "Review: git -C `"$ResolvedProjectRoot`" diff -- .ai-rules/manifest.json .ai-rules/lock.json .ai-rules/upstream"
    Write-Host ''
    Show-Status -ResolvedProjectRoot $ResolvedProjectRoot
}

try {
    $normalizedCommand = $Command.ToLowerInvariant()
    switch ($normalizedCommand) {
        'help' {
            Write-Help
        }
        'doctor' {
            Invoke-Doctor
        }
        'list' {
            $catalog = Get-Catalog
            if ([string]::IsNullOrWhiteSpace($ListTarget)) {
                throw "Command 'list' requires 'profiles' or 'topics'."
            }
            switch ($ListTarget.ToLowerInvariant()) {
                'profiles' {
                    foreach ($profileProperty in $catalog.profiles.PSObject.Properties) {
                        Write-Host $profileProperty.Name
                        Write-Host "  file: $($profileProperty.Value.file)"
                        Write-Host "  topics: $(@($profileProperty.Value.topics) -join ', ')"
                    }
                }
                'topics' {
                    foreach ($topicProperty in $catalog.topics.PSObject.Properties) {
                        Write-Host ('{0,-28} {1}' -f $topicProperty.Name, $topicProperty.Value)
                    }
                }
                default {
                    throw "Unknown list target '$ListTarget'. Use 'profiles' or 'topics'."
                }
            }
        }
        'init' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            $catalog = Get-Catalog
            $selectedProfiles = ConvertTo-NameList -Values $Profiles
            $selectedTopics = ConvertTo-NameList -Values $Topics
            Assert-Selections -Catalog $catalog -SelectedProfiles $selectedProfiles -SelectedTopics $selectedTopics
            $arguments = @('-ProjectRoot', $resolvedProjectRoot)
            if ($selectedProfiles.Count -gt 0) {
                $arguments += '-Profiles'
                $arguments += ($selectedProfiles -join ',')
            }
            if ($selectedTopics.Count -gt 0) {
                $arguments += '-Topics'
                $arguments += ($selectedTopics -join ',')
            }
            if (-not $NoSeedProjectFiles) {
                $arguments += '-SeedProjectFiles'
            }
            $result = Invoke-ChildScript -ScriptPath $initScriptPath -Arguments $arguments
            if ($result.ExitCode -ne 0) {
                throw 'Project initialization failed.'
            }
            Write-Host "Next: .\ai-rules.ps1 plan -ProjectRoot `"$resolvedProjectRoot`""
        }
        'plan' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            $result = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @('-ProjectRoot', $resolvedProjectRoot, '-Mode', 'Plan')
            if ($result.ExitCode -ne 0) {
                throw 'Synchronization plan failed.'
            }
        }
        'apply' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            $result = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @('-ProjectRoot', $resolvedProjectRoot, '-Mode', 'Apply')
            if ($result.ExitCode -ne 0) {
                throw 'Synchronization Apply failed.'
            }
        }
        'status' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            Show-Status -ResolvedProjectRoot $resolvedProjectRoot
        }
        'update' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            Invoke-Update -ResolvedProjectRoot $resolvedProjectRoot -Accept:$Apply
        }
        default {
            throw "Unknown command '$Command'. Run '.\ai-rules.ps1 help' for usage."
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

exit 0
