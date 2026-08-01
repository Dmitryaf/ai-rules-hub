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
. (Join-Path $hubRoot 'scripts/sync-common.ps1')

function Write-Help {
    @'
Команды AI Rules Hub

  help                     Показать эту справку.
  doctor                   Проверить сам хаб и его рабочее дерево.
  doctor -ProjectRoot PATH Проверить подключение проекта без изменений.
  list profiles            Показать профили и их назначение.
  list topics              Показать темы и их назначение.
  init   -ProjectRoot PATH Подготовить проект без применения правил.
  status -ProjectRoot PATH Показать состояние подключения проекта.
  plan   -ProjectRoot PATH Предварительно показать изменения текущей revision.
  apply  -ProjectRoot PATH Применить уже закреплённую revision.
  update -ProjectRoot PATH Показать переход на текущую revision хаба.
  update -ProjectRoot PATH -Apply
                           Закрепить текущую revision и применить её.

Примеры

  .\ai-rules.ps1 list profiles
  .\ai-rules.ps1 init -ProjectRoot C:\path\to\project -Profiles standard-product
  .\ai-rules.ps1 doctor -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 status -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 plan -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 update -ProjectRoot C:\path\to\project
  .\ai-rules.ps1 update -ProjectRoot C:\path\to\project -Apply

plan ничего не меняет и использует revision из manifest.
apply работает только с уже закреплённой revision.
update использует текущий checkout хаба и меняет проект только с -Apply.

CLI не выполняет git pull или git fetch автоматически.
'@ | Write-Host
}

function Get-Catalog {
    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.schemaVersion -ne '0.1') {
        throw "Неподдерживаемая версия catalog schemaVersion: $($catalog.schemaVersion)"
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
            throw "Неизвестный профиль '$profile'. Доступны: $($availableProfiles -join ', ')"
        }
    }
    foreach ($topic in @($SelectedTopics)) {
        if ($topic -notin $availableTopics) {
            throw "Неизвестная тема '$topic'. Доступны: $($availableTopics -join ', ')"
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
        throw "Команда Git завершилась ошибкой: git $($Arguments -join ' ')"
    }
    return @($output)
}

function Get-HubGitState {
    $revisionOutput = @(Invoke-GitText -Arguments @('-C', $hubRoot, 'rev-parse', 'HEAD'))
    $statusOutput = @(Invoke-GitText -Arguments @('-C', $hubRoot, 'status', '--porcelain'))
    $revision = ([string]$revisionOutput[0]).Trim()
    if ($revision -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Не удалось определить полный 40-символьный Git SHA текущей revision хаба.'
    }
    return [pscustomobject]@{
        Revision = $revision
        Dirty = $statusOutput.Count -gt 0
    }
}

function Test-GitAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Ancestor,
        [Parameter(Mandatory = $true)][string]$Descendant
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $hubRoot merge-base --is-ancestor $Ancestor $Descendant 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -eq 0) {
        return [pscustomobject]@{ Available = $true; IsAncestor = $true; ExitCode = $exitCode }
    }
    if ($exitCode -eq 1) {
        return [pscustomobject]@{ Available = $true; IsAncestor = $false; ExitCode = $exitCode }
    }
    return [pscustomobject]@{ Available = $false; IsAncestor = $false; ExitCode = $exitCode }
}

function Get-RevisionRelation {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRevision,
        [Parameter(Mandatory = $true)][string]$HubRevision
    )

    $relation = 'unavailable'
    $detail = $null
    if ($ProjectRevision -eq $HubRevision) {
        $relation = 'same'
    }
    elseif ($ProjectRevision -notmatch '^[0-9a-fA-F]{40}$' -or $HubRevision -notmatch '^[0-9a-fA-F]{40}$') {
        $detail = 'Одна из revisions не является полным Git SHA.'
    }
    else {
        $projectIsAncestor = Test-GitAncestor -Ancestor $ProjectRevision -Descendant $HubRevision
        if (-not $projectIsAncestor.Available) {
            $detail = "Git не смог проверить revision проекта (exit code $($projectIsAncestor.ExitCode))."
        }
        elseif ($projectIsAncestor.IsAncestor) {
            $relation = 'ahead'
        }
        else {
            $hubIsAncestor = Test-GitAncestor -Ancestor $HubRevision -Descendant $ProjectRevision
            if (-not $hubIsAncestor.Available) {
                $detail = "Git не смог проверить revision хаба (exit code $($hubIsAncestor.ExitCode))."
            }
            elseif ($hubIsAncestor.IsAncestor) {
                $relation = 'behind'
            }
            else {
                $relation = 'diverged'
            }
        }
    }

    return [pscustomobject]@{
        Relation = $relation
        ProjectRevision = $ProjectRevision
        HubRevision = $HubRevision
        Detail = $detail
    }
}

function Get-MissingAgentRoutes {
    param([Parameter(Mandatory = $true)][string]$Content)

    $requiredRoutes = @('.ai-rules/RULESET.md', '.ai-rules/PROJECT_RULES.md', '.ai-rules/upstream/CORE.md')
    return @($requiredRoutes | Where-Object { -not $Content.Contains($_) })
}

function Test-RulesetToken {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $pattern = '(?<![A-Za-z0-9_-])' + [regex]::Escape($Id) + '(?![A-Za-z0-9_-])'
    return [regex]::IsMatch($Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-RulesetConsistencyResults {
    param(
        [Parameter(Mandatory = $true)]$Catalog,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $selectedProfiles = @($Manifest.profiles | ForEach-Object { [string]$_ })
    $selectedTopics = @($Manifest.topics | ForEach-Object { [string]$_ })
    foreach ($profileId in @($Catalog.profiles.PSObject.Properties.Name)) {
        $mentioned = Test-RulesetToken -Content $Content -Id $profileId
        if ($profileId -in $selectedProfiles -and -not $mentioned) {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "Профиль $profileId выбран в manifest, но не объяснён в RULESET.md." })
        }
        elseif ($profileId -notin $selectedProfiles -and $mentioned) {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "RULESET.md упоминает $profileId, но этот профиль не выбран в manifest." })
        }
    }
    foreach ($topicId in @($Catalog.topics.PSObject.Properties.Name)) {
        $mentioned = Test-RulesetToken -Content $Content -Id $topicId
        if ($topicId -in $selectedTopics -and -not $mentioned) {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "Тема $topicId выбрана напрямую, но не объяснена в RULESET.md." })
        }
        elseif ($topicId -notin $selectedTopics -and $mentioned) {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "RULESET.md упоминает $topicId, но эта тема не выбрана напрямую в manifest." })
        }
    }
    return @($results)
}

function Get-LockSnapshotResults {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedProjectRoot,
        [Parameter(Mandatory = $true)]$Lock
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Lock.PSObject.Properties['files']) {
        $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = 'В lock отсутствует массив files.' })
        return @($results)
    }

    $upstreamRoot = [System.IO.Path]::GetFullPath((Join-Path $ResolvedProjectRoot '.ai-rules/upstream')).TrimEnd([char[]]@('\', '/'))
    $upstreamPrefix = $upstreamRoot + [System.IO.Path]::DirectorySeparatorChar
    foreach ($entry in @($Lock.files)) {
        $target = [string]$entry.target
        $state = [string]$entry.state
        if ([string]::IsNullOrWhiteSpace($target) -or [System.IO.Path]::IsPathRooted($target)) {
            $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = "Некорректный относительный target в lock: $target" })
            continue
        }

        try {
            $targetPath = Get-AiRulesSafePath -BasePath $ResolvedProjectRoot -ChildPath $target -Label 'lock target'
        }
        catch {
            $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = $_.Exception.Message })
            continue
        }
        if (-not $targetPath.StartsWith($upstreamPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = "Target из lock находится вне .ai-rules/upstream/: $target" })
            continue
        }
        if ($state -notin @('managed', 'orphan')) {
            $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = "Неизвестное состояние lock '$state' для $target." })
            continue
        }
        if ([string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = "Некорректный SHA-256 в lock для $target." })
            continue
        }

        $exists = Test-Path -LiteralPath $targetPath -PathType Leaf
        if ($state -eq 'managed') {
            if (-not $exists) {
                $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = "Managed-файл отсутствует: $target" })
                continue
            }
            $actualHash = Get-AiRulesSha256 -Path $targetPath
            if ($actualHash -ne [string]$entry.sha256) {
                $results.Add([pscustomobject]@{ Level = 'ERROR'; Message = "Managed-файл изменён вне AI Rules Hub: $target" })
            }
            else {
                $results.Add([pscustomobject]@{ Level = 'OK'; Message = "Managed-файл соответствует lock: $target" })
            }
            continue
        }

        if (-not $exists) {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "Orphan-файл отсутствует и остаётся записью lock: $target" })
            continue
        }
        $actualHash = Get-AiRulesSha256 -Path $targetPath
        if ($actualHash -eq [string]$entry.sha256) {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "Orphan-файл сохранён без изменений: $target" })
        }
        else {
            $results.Add([pscustomobject]@{ Level = 'WARN'; Message = "Orphan-файл изменён; его нельзя удалять автоматически: $target" })
        }
    }
    return @($results)
}

function Resolve-ProjectRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Для команды '$Command' обязателен параметр -ProjectRoot."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Некорректный JSON в ${Path}: $($_.Exception.Message)"
    }
}

function Write-Values {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [object[]]$Values
    )

    Write-Host "${Label}:"
    if (@($Values).Count -eq 0) {
        Write-Host '  (не выбраны)'
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

function Get-PlanSummary {
    param([Parameter(Mandatory = $true)][string]$Output)

    $summary = @{}
    $summaryMatch = [regex]::Match($Output, '(?m)^Summary:\s*(?<value>.*)$')
    if (-not $summaryMatch.Success) {
        return $summary
    }
    foreach ($part in @($summaryMatch.Groups['value'].Value.Trim() -split ',\s*')) {
        if ($part -match '^(?<action>[a-z-]+)=(?<count>\d+)$') {
            $summary[$Matches['action']] = [int]$Matches['count']
        }
    }
    return $summary
}

function Get-EffectiveTopics {
    param(
        [Parameter(Mandatory = $true)]$Catalog,
        [string[]]$SelectedProfiles,
        [string[]]$SelectedTopics
    )

    $selected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($topic in @($SelectedTopics)) {
        if ($null -ne $Catalog.topics.PSObject.Properties[[string]$topic]) {
            [void]$selected.Add([string]$topic)
        }
    }
    foreach ($profileName in @($SelectedProfiles)) {
        $profileProperty = $Catalog.profiles.PSObject.Properties[[string]$profileName]
        if ($null -eq $profileProperty) {
            continue
        }
        foreach ($topic in @($profileProperty.Value.topics)) {
            [void]$selected.Add([string]$topic)
        }
    }

    return @(
        foreach ($topicProperty in $Catalog.topics.PSObject.Properties) {
            if ($selected.Contains($topicProperty.Name)) {
                $topicProperty.Name
            }
        }
    )
}

function Get-ManifestRevision {
    param([Parameter(Mandatory = $true)][string]$ResolvedProjectRoot)

    $manifestPath = Join-Path $ResolvedProjectRoot '.ai-rules/manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest не найден: $manifestPath"
    }
    $manifest = Get-JsonFile -Path $manifestPath
    if ($null -eq $manifest.source -or $null -eq $manifest.source.PSObject.Properties['revision']) {
        throw 'В manifest отсутствует обязательное поле source.revision.'
    }
    if ($null -eq $manifest.source.revision) {
        return $null
    }
    return [string]$manifest.source.revision
}

function Write-StateResult {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$ResolvedProjectRoot
    )

    Write-Host "State: $State"
    switch ($State) {
        'not-initialized' {
            Write-Host 'Описание: проект ещё не подключён к AI Rules Hub.'
            Write-Host "Next: .\ai-rules.ps1 init -ProjectRoot `"$ResolvedProjectRoot`" -Profiles <profile>"
        }
        'unpinned' {
            Write-Host 'Описание: проект подготовлен, но ещё не закреплён за воспроизводимой revision.'
            Write-Host "Next: заполните локальные файлы и выполните .\ai-rules.ps1 update -ProjectRoot `"$ResolvedProjectRoot`" -Apply"
        }
        'update-available' {
            Write-Host 'Описание: текущий checkout хаба содержит более новую revision.'
            Write-Host "Next: просмотрите переход через .\ai-rules.ps1 update -ProjectRoot `"$ResolvedProjectRoot`""
        }
        'checkout-older' {
            Write-Host 'Описание: checkout хаба старее revision, установленной в проекте.'
            Write-Host 'Next: получите нужную версию хаба или явно переключите checkout; не применяйте update -Apply без намеренного отката.'
        }
        'checkout-diverged' {
            Write-Host 'Описание: revision проекта и текущий checkout хаба находятся в расходящихся историях.'
            Write-Host 'Next: проверьте ветку и историю локального checkout хаба перед обновлением проекта.'
        }
        'checkout-mismatch' {
            Write-Host 'Описание: отношение revision проекта и checkout хаба надёжно определить не удалось.'
            Write-Host 'Next: получите или переключите checkout на revision проекта либо нужную целевую revision.'
        }
        'synchronized' {
            Write-Host 'Описание: проект синхронизирован с текущей revision хаба.'
            Write-Host 'Next: действий не требуется.'
        }
        'inconsistent' {
            Write-Host 'Описание: подключение содержит противоречие или незавершённое managed-состояние.'
            Write-Host "Next: .\ai-rules.ps1 doctor -ProjectRoot `"$ResolvedProjectRoot`""
        }
        default {
            Write-Host 'Описание: состояние подключения не распознано.'
            Write-Host "Next: .\ai-rules.ps1 doctor -ProjectRoot `"$ResolvedProjectRoot`""
        }
    }
}

function Show-Status {
    param([Parameter(Mandatory = $true)][string]$ResolvedProjectRoot)

    $projectName = Split-Path -Leaf $ResolvedProjectRoot.TrimEnd([char[]]@('\', '/'))
    $catalog = Get-Catalog
    $localRulesRoot = Join-Path $ResolvedProjectRoot '.ai-rules'
    $manifestPath = Join-Path $localRulesRoot 'manifest.json'
    $lockPath = Join-Path $localRulesRoot 'lock.json'
    $managedRoot = Join-Path $localRulesRoot 'upstream'
    $manifestFound = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $lockFound = Test-Path -LiteralPath $lockPath -PathType Leaf
    $managedRootFound = Test-Path -LiteralPath $managedRoot -PathType Container
    $hubState = Get-HubGitState

    Write-Host "Проект: $projectName"
    Write-Host "Корень проекта: $ResolvedProjectRoot"
    Write-Host "Manifest: $(if ($manifestFound) { 'найден' } else { 'отсутствует' })"
    Write-Host "Lock: $(if ($lockFound) { 'найден' } else { 'отсутствует' })"
    Write-Host "Managed-каталог: $(if ($managedRootFound) { 'найден' } else { 'отсутствует' })"
    Write-Host ''
    Write-Host "Revision хаба: $($hubState.Revision)"
    Write-Host "Checkout хаба изменён: $($hubState.Dirty.ToString().ToLowerInvariant())"

    if (-not $manifestFound) {
        Write-Host ''
        Write-Host 'Revision manifest: не закреплена'
        Write-Host 'Revision lock: отсутствует'
        Write-Values -Label 'Профили (Profiles)' -Values @()
        Write-Values -Label 'Прямые темы (Direct topics)' -Values @()
        Write-Values -Label 'Итоговые темы (Effective topics)' -Values @()
        Write-Host ''
        Write-Host 'Диагностика: сначала инициализируйте подключение проекта.'
        Write-StateResult -State 'not-initialized' -ResolvedProjectRoot $ResolvedProjectRoot
        return
    }

    try {
        $manifest = Get-JsonFile -Path $manifestPath
    }
    catch {
        Write-Host ''
        Write-Host 'Revision manifest: не определена'
        Write-Host 'Revision lock: не определена'
        Write-Values -Label 'Профили (Profiles)' -Values @()
        Write-Values -Label 'Прямые темы (Direct topics)' -Values @()
        Write-Values -Label 'Итоговые темы (Effective topics)' -Values @()
        Write-Host ''
        Write-Host "Диагностика: $($_.Exception.Message)"
        Write-StateResult -State 'inconsistent' -ResolvedProjectRoot $ResolvedProjectRoot
        return
    }
    $structuralDiagnostics = [System.Collections.Generic.List[string]]::new()
    $statusWarnings = [System.Collections.Generic.List[string]]::new()
    if ($manifest.schemaVersion -ne '0.2') {
        $structuralDiagnostics.Add("неподдерживаемая manifest schemaVersion: $($manifest.schemaVersion).")
    }
    foreach ($requiredProperty in @('source', 'topics', 'profiles')) {
        if ($null -eq $manifest.PSObject.Properties[$requiredProperty]) {
            $structuralDiagnostics.Add("в manifest отсутствует поле: $requiredProperty.")
        }
    }
    if ($null -eq $manifest.source) {
        $structuralDiagnostics.Add('в manifest отсутствует source.')
    }
    else {
        if ($null -eq $manifest.source.PSObject.Properties['repository'] -or [string]$manifest.source.repository -ne 'ai-rules-hub') {
            $structuralDiagnostics.Add('manifest source.repository отсутствует или не поддерживается.')
        }
        if ($null -eq $manifest.source.PSObject.Properties['revision']) {
            $structuralDiagnostics.Add('в manifest отсутствует поле source.revision.')
        }
    }
    $manifestRevision = $null
    if ($null -ne $manifest.source -and $null -ne $manifest.source.revision) {
        $manifestRevision = [string]$manifest.source.revision
    }
    $profiles = @($manifest.profiles | ForEach-Object { [string]$_ })
    $directTopics = @($manifest.topics | ForEach-Object { [string]$_ })
    $effectiveTopics = Get-EffectiveTopics -Catalog $catalog -SelectedProfiles $profiles -SelectedTopics $directTopics
    try {
        Assert-Selections -Catalog $catalog -SelectedProfiles $profiles -SelectedTopics $directTopics
    }
    catch {
        $structuralDiagnostics.Add($_.Exception.Message)
    }
    $lock = $null
    $lockRevision = $null
    $lockContractValid = $false
    if ($lockFound) {
        try {
            $lock = Get-JsonFile -Path $lockPath
            if ($lock.schemaVersion -ne '0.2') {
                $structuralDiagnostics.Add("неподдерживаемая lock schemaVersion: $($lock.schemaVersion).")
            }
            if ([string]$lock.manifest -ne '.ai-rules/manifest.json') {
                $structuralDiagnostics.Add('путь manifest в lock противоречит контракту.')
            }
            if ([string]$lock.managedRoot -ne '.ai-rules/upstream') {
                $structuralDiagnostics.Add('managed root в lock противоречит контракту.')
            }
            if (
                $lock.schemaVersion -eq '0.2' -and
                [string]$lock.manifest -eq '.ai-rules/manifest.json' -and
                [string]$lock.managedRoot -eq '.ai-rules/upstream'
            ) {
                $lockContractValid = $true
            }
            if ($null -ne $lock.source -and $null -ne $lock.source.revision) {
                $lockRevision = [string]$lock.source.revision
            }
            $lockTopics = @($lock.topics | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $expectedTopics = @($effectiveTopics | Sort-Object -Unique)
            if (($expectedTopics -join "`n") -ne ($lockTopics -join "`n")) {
                $structuralDiagnostics.Add('итоговые темы manifest и lock не совпадают.')
            }
            $lockProfiles = @($lock.profiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $expectedProfiles = @($profiles | Sort-Object -Unique)
            if (($expectedProfiles -join "`n") -ne ($lockProfiles -join "`n")) {
                $structuralDiagnostics.Add('профили manifest и lock не совпадают.')
            }
            if ($lockContractValid) {
                foreach ($snapshotResult in @(Get-LockSnapshotResults -ResolvedProjectRoot $ResolvedProjectRoot -Lock $lock)) {
                    if ($snapshotResult.Level -eq 'ERROR') {
                        $structuralDiagnostics.Add($snapshotResult.Message)
                    }
                    elseif ($snapshotResult.Level -eq 'WARN') {
                        $statusWarnings.Add($snapshotResult.Message)
                    }
                }
            }
        }
        catch {
            $structuralDiagnostics.Add($_.Exception.Message)
        }
    }

    Write-Host ''
    Write-Host "Revision manifest: $(if ([string]::IsNullOrWhiteSpace($manifestRevision)) { 'не закреплена' } else { $manifestRevision })"
    Write-Host "Revision lock: $(if ([string]::IsNullOrWhiteSpace($lockRevision)) { 'отсутствует' } else { $lockRevision })"
    Write-Values -Label 'Профили (Profiles)' -Values $profiles
    Write-Values -Label 'Прямые темы (Direct topics)' -Values $directTopics
    Write-Values -Label 'Итоговые темы (Effective topics)' -Values $effectiveTopics

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
        $diagnostics.Add('manifest пока не закреплён за revision.')
    }
    else {
        if ($manifestRevision -notmatch '^[0-9a-fA-F]{40}$') {
            $diagnostics.Add('revision manifest не является полным commit SHA.')
        }
        if (-not $lockFound) {
            $diagnostics.Add('для закреплённого manifest отсутствует lock.json.')
        }
        if (-not $managedRootFound) {
            $diagnostics.Add('для закреплённого manifest отсутствует managed-каталог upstream.')
        }
        if ($lockFound -and [string]::IsNullOrWhiteSpace($lockRevision)) {
            $diagnostics.Add('в lock отсутствует revision.')
        }
        if (-not [string]::IsNullOrWhiteSpace($lockRevision) -and $lockRevision -notmatch '^[0-9a-fA-F]{40}$') {
            $diagnostics.Add('revision lock не является полным commit SHA.')
        }
        if (-not [string]::IsNullOrWhiteSpace($lockRevision) -and $manifestRevision -ne $lockRevision) {
            $diagnostics.Add('revision manifest и lock не совпадают.')
        }
        $agentsPath = Join-Path $ResolvedProjectRoot 'AGENTS.md'
        $rulesetPath = Join-Path $ResolvedProjectRoot '.ai-rules/RULESET.md'
        $projectRulesPath = Join-Path $ResolvedProjectRoot '.ai-rules/PROJECT_RULES.md'
        if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
            $diagnostics.Add('для закреплённого проекта отсутствует корневой AGENTS.md.')
        }
        else {
            $agentsContent = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8
            $missingRoutes = Get-MissingAgentRoutes -Content $agentsContent
            if ($missingRoutes.Count -gt 0) {
                $diagnostics.Add("закреплённый проект не подключает обязательные маршруты AI Rules Hub: $($missingRoutes -join ', ').")
            }
        }
        if (-not (Test-Path -LiteralPath $rulesetPath -PathType Leaf)) {
            $diagnostics.Add('для закреплённого проекта отсутствует .ai-rules/RULESET.md.')
        }
        if (-not (Test-Path -LiteralPath $projectRulesPath -PathType Leaf)) {
            $diagnostics.Add('для закреплённого проекта отсутствует .ai-rules/PROJECT_RULES.md.')
        }

        if ($diagnostics.Count -gt 0) {
            $state = 'inconsistent'
        }
        else {
            $revisionRelation = Get-RevisionRelation -ProjectRevision $manifestRevision -HubRevision $hubState.Revision
            switch ($revisionRelation.Relation) {
                'ahead' {
                    $state = 'update-available'
                    $diagnostics.Add('текущий checkout хаба содержит более новую revision.')
                }
                'behind' {
                    $state = 'checkout-older'
                    $diagnostics.Add('checkout хаба старее revision проекта; update -Apply предложит откат.')
                }
                'diverged' {
                    $state = 'checkout-diverged'
                    $diagnostics.Add('revision проекта и checkout хаба находятся в расходящихся историях.')
                }
                'unavailable' {
                    $state = 'checkout-mismatch'
                    $diagnostics.Add("отношение revisions определить не удалось. $($revisionRelation.Detail)")
                }
                'same' {
                    $planResult = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @(
                        '-ProjectRoot', $ResolvedProjectRoot,
                        '-Mode', 'Plan'
                    ) -Capture
                    if ($planResult.ExitCode -ne 0) {
                        $state = 'inconsistent'
                        $diagnostics.Add('не удалось построить sync Plan.')
                        $diagnostics.Add($planResult.Output.Trim())
                    }
                    elseif ((Get-PlanState -Output $planResult.Output) -eq 'unchanged') {
                        $state = 'synchronized'
                    }
                    else {
                        $state = 'inconsistent'
                        $diagnostics.Add('sync Plan содержит незавершённые изменения или конфликтные состояния.')
                    }
                }
            }
        }
    }

    Write-Host ''
    foreach ($statusWarning in $statusWarnings) {
        Write-Host "Предупреждение: $statusWarning"
    }
    foreach ($diagnostic in $diagnostics) {
        Write-Host "Диагностика: $diagnostic"
    }
    Write-StateResult -State $state -ResolvedProjectRoot $ResolvedProjectRoot
}

function Add-DoctorResult {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)]$Errors,
        [Parameter(Mandatory = $true)]$Warnings
    )

    Write-Host "[$Level] $Message"
    if ($Level -eq 'ERROR') {
        $Errors.Add($Message) | Out-Null
    }
    elseif ($Level -eq 'WARN') {
        $Warnings.Add($Message) | Out-Null
    }
}

function Get-TemplatePlaceholders {
    param([Parameter(Mandatory = $true)][string]$TemplatePath)

    $content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    return @(
        [regex]::Matches($content, '<[^<>\r\n]+>') |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique
    )
}

function Invoke-ProjectDoctor {
    param([Parameter(Mandatory = $true)][string]$ResolvedProjectRoot)

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $projectName = Split-Path -Leaf $ResolvedProjectRoot.TrimEnd([char[]]@('\', '/'))
    $localRulesRoot = Join-Path $ResolvedProjectRoot '.ai-rules'
    $manifestPath = Join-Path $localRulesRoot 'manifest.json'
    $lockPath = Join-Path $localRulesRoot 'lock.json'
    $upstreamRoot = Join-Path $localRulesRoot 'upstream'
    $agentsPath = Join-Path $ResolvedProjectRoot 'AGENTS.md'
    $rulesetPath = Join-Path $localRulesRoot 'RULESET.md'
    $projectRulesPath = Join-Path $localRulesRoot 'PROJECT_RULES.md'
    $catalog = Get-Catalog
    $manifest = $null
    $manifestValid = $false
    $selectionsValid = $false
    $manifestRevision = $null
    $pinned = $false

    Write-Host "Проверка проекта: $projectName"
    Write-Host "Корень проекта: $ResolvedProjectRoot"
    Write-Host ''

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Add-DoctorResult -Level 'ERROR' -Message 'Manifest .ai-rules/manifest.json не найден.' -Errors $errors -Warnings $warnings
    }
    else {
        try {
            $manifest = Get-JsonFile -Path $manifestPath
            if ($manifest.schemaVersion -ne '0.2') {
                Add-DoctorResult -Level 'ERROR' -Message "Manifest использует неподдерживаемую schemaVersion: $($manifest.schemaVersion)." -Errors $errors -Warnings $warnings
            }
            elseif (
                $null -eq $manifest.PSObject.Properties['source'] -or
                $null -eq $manifest.PSObject.Properties['profiles'] -or
                $null -eq $manifest.PSObject.Properties['topics'] -or
                $null -eq $manifest.source -or
                $null -eq $manifest.source.PSObject.Properties['revision'] -or
                [string]$manifest.source.repository -ne 'ai-rules-hub'
            ) {
                Add-DoctorResult -Level 'ERROR' -Message 'Manifest не содержит обязательные source, profiles и topics.' -Errors $errors -Warnings $warnings
            }
            else {
                $manifestValid = $true
                Add-DoctorResult -Level 'OK' -Message 'Manifest найден и валиден.' -Errors $errors -Warnings $warnings
                try {
                    Assert-Selections -Catalog $catalog -SelectedProfiles @($manifest.profiles) -SelectedTopics @($manifest.topics)
                    $selectionsValid = $true
                    Add-DoctorResult -Level 'OK' -Message 'Все profiles и topics известны catalog.' -Errors $errors -Warnings $warnings
                }
                catch {
                    Add-DoctorResult -Level 'ERROR' -Message $_.Exception.Message -Errors $errors -Warnings $warnings
                }

                if ($null -ne $manifest.source.revision) {
                    $manifestRevision = [string]$manifest.source.revision
                }
                if ([string]::IsNullOrWhiteSpace($manifestRevision)) {
                    Add-DoctorResult -Level 'WARN' -Message 'Revision пока не закреплена; первое применение выполняется через update -Apply.' -Errors $errors -Warnings $warnings
                }
                elseif ($manifestRevision -notmatch '^[0-9a-fA-F]{40}$') {
                    Add-DoctorResult -Level 'ERROR' -Message 'Revision manifest должна быть полным 40-символьным Git SHA.' -Errors $errors -Warnings $warnings
                }
                else {
                    $pinned = $true
                    Add-DoctorResult -Level 'OK' -Message 'Revision закреплена полным Git SHA.' -Errors $errors -Warnings $warnings
                }
            }
        }
        catch {
            Add-DoctorResult -Level 'ERROR' -Message $_.Exception.Message -Errors $errors -Warnings $warnings
        }
    }

    foreach ($requiredFile in @(
        [pscustomobject]@{ Path = $agentsPath; Label = 'Корневой AGENTS.md' },
        [pscustomobject]@{ Path = $rulesetPath; Label = '.ai-rules/RULESET.md' },
        [pscustomobject]@{ Path = $projectRulesPath; Label = '.ai-rules/PROJECT_RULES.md' }
    )) {
        if (Test-Path -LiteralPath $requiredFile.Path -PathType Leaf) {
            Add-DoctorResult -Level 'OK' -Message "$($requiredFile.Label) найден." -Errors $errors -Warnings $warnings
        }
        else {
            Add-DoctorResult -Level 'ERROR' -Message "$($requiredFile.Label) не найден." -Errors $errors -Warnings $warnings
        }
    }

    $lock = $null
    $lockValid = $false
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        try {
            $lock = Get-JsonFile -Path $lockPath
            if ($lock.schemaVersion -ne '0.2') {
                Add-DoctorResult -Level 'ERROR' -Message "Lock использует неподдерживаемую schemaVersion: $($lock.schemaVersion)." -Errors $errors -Warnings $warnings
            }
            elseif (
                [string]$lock.manifest -ne '.ai-rules/manifest.json' -or
                [string]$lock.managedRoot -ne '.ai-rules/upstream' -or
                $null -eq $lock.PSObject.Properties['source'] -or
                $null -eq $lock.PSObject.Properties['files']
            ) {
                Add-DoctorResult -Level 'ERROR' -Message 'Lock содержит неподдерживаемые пути manifest или managedRoot.' -Errors $errors -Warnings $warnings
            }
            else {
                $lockValid = $true
                Add-DoctorResult -Level 'OK' -Message 'Lock найден и валиден.' -Errors $errors -Warnings $warnings
            }
        }
        catch {
            Add-DoctorResult -Level 'ERROR' -Message $_.Exception.Message -Errors $errors -Warnings $warnings
        }
    }
    elseif ($pinned) {
        Add-DoctorResult -Level 'ERROR' -Message 'Для закреплённого проекта отсутствует .ai-rules/lock.json.' -Errors $errors -Warnings $warnings
    }

    if ($pinned) {
        if (Test-Path -LiteralPath $upstreamRoot -PathType Container) {
            Add-DoctorResult -Level 'OK' -Message 'Managed-каталог .ai-rules/upstream найден.' -Errors $errors -Warnings $warnings
        }
        else {
            Add-DoctorResult -Level 'ERROR' -Message 'Для закреплённого проекта отсутствует .ai-rules/upstream.' -Errors $errors -Warnings $warnings
        }
    }
    if ($pinned -and $lockValid) {
        if ([string]$lock.source.revision -eq $manifestRevision) {
            Add-DoctorResult -Level 'OK' -Message 'Revision manifest и lock согласованы.' -Errors $errors -Warnings $warnings
        }
        else {
            Add-DoctorResult -Level 'ERROR' -Message 'Revision manifest и lock не совпадают.' -Errors $errors -Warnings $warnings
        }
        $expectedTopics = @(Get-EffectiveTopics -Catalog $catalog -SelectedProfiles @($manifest.profiles) -SelectedTopics @($manifest.topics) | Sort-Object -Unique)
        $lockTopics = @($lock.topics | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if (($expectedTopics -join "`n") -ne ($lockTopics -join "`n")) {
            Add-DoctorResult -Level 'ERROR' -Message 'Итоговые темы manifest и lock не совпадают.' -Errors $errors -Warnings $warnings
        }
        $expectedProfiles = @($manifest.profiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $lockProfiles = @($lock.profiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if (($expectedProfiles -join "`n") -ne ($lockProfiles -join "`n")) {
            Add-DoctorResult -Level 'ERROR' -Message 'Профили manifest и lock не совпадают.' -Errors $errors -Warnings $warnings
        }
    }
    if ($lockValid) {
        foreach ($snapshotResult in @(Get-LockSnapshotResults -ResolvedProjectRoot $ResolvedProjectRoot -Lock $lock)) {
            Add-DoctorResult -Level $snapshotResult.Level -Message $snapshotResult.Message -Errors $errors -Warnings $warnings
        }
    }

    if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
        $agentsContent = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8
        $routes = @('.ai-rules/RULESET.md', '.ai-rules/PROJECT_RULES.md', '.ai-rules/upstream/CORE.md')
        $missingRoutes = Get-MissingAgentRoutes -Content $agentsContent
        if ($missingRoutes.Count -gt 0) {
            if ($pinned) {
                Add-DoctorResult -Level 'ERROR' -Message "Закреплённый проект не подключает обязательные маршруты AI Rules Hub. Объедините существующий AGENTS.md с templates/AGENTS.md. Отсутствуют: $($missingRoutes -join ', ')." -Errors $errors -Warnings $warnings
            }
            else {
                Add-DoctorResult -Level 'WARN' -Message "AGENTS.md пока не подключает правила хаба. Объедините существующий файл с templates/AGENTS.md. Отсутствуют: $($missingRoutes -join ', ')." -Errors $errors -Warnings $warnings
            }
        }
        else {
            Add-DoctorResult -Level 'OK' -Message 'AGENTS.md содержит стандартные маршруты AI Rules Hub.' -Errors $errors -Warnings $warnings
        }

        foreach ($route in $routes) {
            if (-not $agentsContent.Contains($route)) {
                continue
            }
            $targetPath = Join-Path $ResolvedProjectRoot $route
            if (Test-Path -LiteralPath $targetPath) {
                continue
            }
            if ($route -eq '.ai-rules/upstream/CORE.md' -and -not $pinned) {
                Add-DoctorResult -Level 'WARN' -Message 'Маршрут к upstream/CORE.md станет доступен после первого update -Apply.' -Errors $errors -Warnings $warnings
            }
            else {
                Add-DoctorResult -Level 'ERROR' -Message "AGENTS.md ссылается на отсутствующий путь: $route." -Errors $errors -Warnings $warnings
            }
        }
    }

    foreach ($placeholderFile in @(
        [pscustomobject]@{ Path = $agentsPath; Template = (Join-Path $hubRoot 'templates/AGENTS.md'); Label = 'AGENTS.md' },
        [pscustomobject]@{ Path = $rulesetPath; Template = (Join-Path $hubRoot 'templates/RULESET.md'); Label = 'RULESET.md' },
        [pscustomobject]@{ Path = $projectRulesPath; Template = (Join-Path $hubRoot 'templates/PROJECT_RULES.md'); Label = 'PROJECT_RULES.md' }
    )) {
        if (-not (Test-Path -LiteralPath $placeholderFile.Path -PathType Leaf)) {
            continue
        }
        $userContent = Get-Content -LiteralPath $placeholderFile.Path -Raw -Encoding UTF8
        $remaining = @(Get-TemplatePlaceholders -TemplatePath $placeholderFile.Template | Where-Object { $userContent.Contains($_) })
        if ($remaining.Count -gt 0) {
            Add-DoctorResult -Level 'WARN' -Message "В $($placeholderFile.Label) остались placeholders: $($remaining -join ', ')." -Errors $errors -Warnings $warnings
        }
        else {
            Add-DoctorResult -Level 'OK' -Message "В $($placeholderFile.Label) нет известных placeholders." -Errors $errors -Warnings $warnings
        }
    }

    if ($manifestValid -and $selectionsValid -and (Test-Path -LiteralPath $rulesetPath -PathType Leaf)) {
        $rulesetContent = Get-Content -LiteralPath $rulesetPath -Raw -Encoding UTF8
        $rulesetResults = @(Get-RulesetConsistencyResults -Catalog $catalog -Manifest $manifest -Content $rulesetContent)
        if ($rulesetResults.Count -eq 0) {
            Add-DoctorResult -Level 'OK' -Message 'Manifest и RULESET.md согласованы по profiles и прямым topics.' -Errors $errors -Warnings $warnings
        }
        else {
            foreach ($rulesetResult in $rulesetResults) {
                Add-DoctorResult -Level $rulesetResult.Level -Message $rulesetResult.Message -Errors $errors -Warnings $warnings
            }
        }
    }

    if ($manifestValid -and $selectionsValid) {
        $canRunPlan = $true
        if ($pinned) {
            try {
                $hubState = Get-HubGitState
                $revisionRelation = Get-RevisionRelation -ProjectRevision $manifestRevision -HubRevision $hubState.Revision
                switch ($revisionRelation.Relation) {
                    'ahead' {
                        $canRunPlan = $false
                        Add-DoctorResult -Level 'WARN' -Message 'Текущий checkout хаба содержит более новую revision; установленный snapshot проверен отдельно по lock.' -Errors $errors -Warnings $warnings
                    }
                    'behind' {
                        $canRunPlan = $false
                        Add-DoctorResult -Level 'WARN' -Message 'Checkout хаба старее revision проекта; update -Apply без намерения приведёт к откату.' -Errors $errors -Warnings $warnings
                    }
                    'diverged' {
                        $canRunPlan = $false
                        Add-DoctorResult -Level 'WARN' -Message 'Revision проекта и checkout хаба расходятся; проверьте ветку и историю перед обновлением.' -Errors $errors -Warnings $warnings
                    }
                    'unavailable' {
                        $canRunPlan = $false
                        Add-DoctorResult -Level 'WARN' -Message "Revision проекта недоступна локально; managed Plan пропущен, snapshot проверен по lock. $($revisionRelation.Detail)" -Errors $errors -Warnings $warnings
                    }
                }
            }
            catch {
                $canRunPlan = $false
                Add-DoctorResult -Level 'ERROR' -Message $_.Exception.Message -Errors $errors -Warnings $warnings
            }
        }
        if ($canRunPlan) {
            $planResult = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @('-ProjectRoot', $ResolvedProjectRoot, '-Mode', 'Plan') -Capture
            if ($planResult.ExitCode -ne 0) {
                Add-DoctorResult -Level 'ERROR' -Message "Не удалось построить managed Plan: $($planResult.Output.Trim())." -Errors $errors -Warnings $warnings
            }
            else {
                $summary = Get-PlanSummary -Output $planResult.Output
                if ($summary.Count -eq 0) {
                    Add-DoctorResult -Level 'ERROR' -Message 'Managed Plan не содержит распознаваемый Summary.' -Errors $errors -Warnings $warnings
                }
                else {
                    if ($summary.ContainsKey('conflict')) {
                        Add-DoctorResult -Level 'ERROR' -Message "Managed Plan обнаружил conflict: $($summary['conflict'])." -Errors $errors -Warnings $warnings
                    }
                    foreach ($pendingAction in @('add', 'update')) {
                        if ($summary.ContainsKey($pendingAction)) {
                            if ($pinned) {
                                Add-DoctorResult -Level 'ERROR' -Message "Для текущей закреплённой revision обнаружено pending-состояние ${pendingAction}: $($summary[$pendingAction])." -Errors $errors -Warnings $warnings
                            }
                            else {
                                Add-DoctorResult -Level 'OK' -Message "Предварительный Plan: ${pendingAction}=$($summary[$pendingAction])." -Errors $errors -Warnings $warnings
                            }
                        }
                    }
                    foreach ($orphanAction in @('orphan', 'orphan-modified', 'orphan-missing')) {
                        if ($summary.ContainsKey($orphanAction)) {
                            Add-DoctorResult -Level 'WARN' -Message "Managed Plan обнаружил ${orphanAction}: $($summary[$orphanAction])." -Errors $errors -Warnings $warnings
                        }
                    }
                    if ($summary.ContainsKey('unchanged') -and $summary.Count -eq 1) {
                        Add-DoctorResult -Level 'OK' -Message "Managed-файлы синхронизированы: unchanged=$($summary['unchanged'])." -Errors $errors -Warnings $warnings
                    }
                }
            }
        }
    }

    Write-Host ''
    if ($errors.Count -gt 0) {
        Write-Host 'Итог: требуется исправление' -ForegroundColor Red
        return 1
    }
    if ($warnings.Count -gt 0) {
        Write-Host 'Итог: подключение работоспособно, есть предупреждения' -ForegroundColor Yellow
        return 0
    }
    Write-Host 'Итог: подключение корректно' -ForegroundColor Green
    return 0
}

function Invoke-HubDoctor {
    $failed = $false
    foreach ($step in @(
        [pscustomobject]@{ Name = 'Структура хаба'; Kind = 'script'; Path = (Join-Path $hubRoot 'scripts/check-hub.ps1') },
        [pscustomobject]@{ Name = 'Тесты tooling'; Kind = 'script'; Path = (Join-Path $hubRoot 'tests/test-tooling.ps1') },
        [pscustomobject]@{ Name = 'Проверка diff'; Kind = 'git'; Path = $null },
        [pscustomobject]@{ Name = 'Рабочее дерево'; Kind = 'status'; Path = $null }
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
        throw 'Проверка хаба обнаружила одну или несколько ошибок.'
    }
    Write-Host "`nПроверка хаба пройдена." -ForegroundColor Green
}

function Invoke-Update {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedProjectRoot,
        [switch]$Accept
    )

    $manifestPath = Join-Path $ResolvedProjectRoot '.ai-rules/manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest подключения не найден: $manifestPath"
    }
    $manifest = Get-JsonFile -Path $manifestPath
    if ($null -eq $manifest.source -or $null -eq $manifest.source.PSObject.Properties['revision']) {
        throw 'В manifest обязательно поле source.revision; для подготовки без pinning используйте null.'
    }
    $currentRevision = $null
    if ($null -ne $manifest.source.revision) {
        $currentRevision = [string]$manifest.source.revision
    }
    $hubState = Get-HubGitState

    Write-Host "Текущая revision проекта: $(if ([string]::IsNullOrWhiteSpace($currentRevision)) { 'не закреплена' } else { $currentRevision })"
    Write-Host "Целевая revision хаба: $($hubState.Revision)"

    $planArguments = @(
        '-ProjectRoot', $ResolvedProjectRoot,
        '-Mode', 'Plan',
        '-RevisionOverride', $hubState.Revision
    )
    if ($Accept) {
        if ($hubState.Dirty) {
            throw 'Для update -Apply рабочее дерево хаба должно быть чистым.'
        }
        $planArguments += '-FailOnConflict'
    }
    Write-Host "`nПредварительный Plan:"
    $planResult = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments $planArguments -Capture
    Write-Host $planResult.Output.TrimEnd()
    if ($planResult.ExitCode -ne 0) {
        throw 'Не удалось построить update Plan; файлы проекта не изменены.'
    }

    if (-not $Accept) {
        Write-Host "`nФайлы проекта не изменены." -ForegroundColor Green
        Write-Host 'После проверки выполните ту же команду с -Apply, чтобы закрепить revision.'
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
        Write-Host "`nПрименение:"
        Write-Host $applyResult.Output.TrimEnd()
        if ($applyResult.ExitCode -ne 0) {
            throw 'Применение правил завершилось ошибкой.'
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

    Write-Host "`nRevision закреплена, правила применены." -ForegroundColor Green
    Write-Host "Проверьте diff: git -C `"$ResolvedProjectRoot`" diff -- .ai-rules/manifest.json .ai-rules/lock.json .ai-rules/upstream"
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
            if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
                Invoke-HubDoctor
            }
            else {
                $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
                $doctorExitCode = Invoke-ProjectDoctor -ResolvedProjectRoot $resolvedProjectRoot
                if ($doctorExitCode -ne 0) {
                    exit $doctorExitCode
                }
            }
        }
        'list' {
            $catalog = Get-Catalog
            if ([string]::IsNullOrWhiteSpace($ListTarget)) {
                throw "Для команды 'list' укажите 'profiles' или 'topics'."
            }
            switch ($ListTarget.ToLowerInvariant()) {
                'profiles' {
                    foreach ($profileProperty in $catalog.profiles.PSObject.Properties) {
                        Write-Host $profileProperty.Name
                        Write-Host "  $($profileProperty.Value.description)"
                        Write-Host "  Темы: $(@($profileProperty.Value.topics) -join ', ')"
                        Write-Host "  Файл: $($profileProperty.Value.file)"
                    }
                }
                'topics' {
                    foreach ($topicProperty in $catalog.topics.PSObject.Properties) {
                        Write-Host $topicProperty.Name
                        Write-Host "  $($topicProperty.Value.description)"
                        Write-Host "  Файл: $($topicProperty.Value.file)"
                    }
                }
                default {
                    throw "Неизвестный раздел '$ListTarget'. Используйте 'profiles' или 'topics'."
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
                throw 'Инициализация проекта завершилась ошибкой.'
            }
            Write-Host "`nПроект инициализирован." -ForegroundColor Green
            Write-Host "`nПеред первым применением:"
            Write-Host ''
            Write-Host '1. Заполните .ai-rules/RULESET.md.'
            Write-Host '2. Заполните .ai-rules/PROJECT_RULES.md.'
            Write-Host '3. Проверьте или объедините корневой AGENTS.md.'
            Write-Host '4. Просмотрите первое применение:'
            Write-Host "   .\ai-rules.ps1 update -ProjectRoot `"$resolvedProjectRoot`""
            Write-Host '5. Примените закреплённую revision:'
            Write-Host "   .\ai-rules.ps1 update -ProjectRoot `"$resolvedProjectRoot`" -Apply"
        }
        'plan' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            $manifestRevision = Get-ManifestRevision -ResolvedProjectRoot $resolvedProjectRoot
            $result = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @('-ProjectRoot', $resolvedProjectRoot, '-Mode', 'Plan') -Capture
            $planOutput = $result.Output
            if ([string]::IsNullOrWhiteSpace($manifestRevision)) {
                $planOutput = [regex]::Replace($planOutput, '(?m)^Следующий шаг: проверьте Plan и выбранную revision, затем повторите команду с -Mode Apply\.\r?\n?', '')
            }
            Write-Host $planOutput.TrimEnd()
            if ($result.ExitCode -ne 0) {
                throw 'Не удалось построить sync Plan.'
            }
            if ([string]::IsNullOrWhiteSpace($manifestRevision)) {
                Write-Host "`nManifest пока не закреплён за revision."
                Write-Host 'Этот Plan является предварительным.'
                Write-Host "`nДля первого воспроизводимого применения используйте:"
                Write-Host ".\ai-rules.ps1 update -ProjectRoot `"$resolvedProjectRoot`" -Apply"
            }
        }
        'apply' {
            $resolvedProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
            $manifestRevision = Get-ManifestRevision -ResolvedProjectRoot $resolvedProjectRoot
            if ([string]::IsNullOrWhiteSpace($manifestRevision)) {
                throw @"
Проект ещё не закреплён за версией хаба.
Для первого применения выполните:

.\ai-rules.ps1 update -ProjectRoot "$resolvedProjectRoot"
.\ai-rules.ps1 update -ProjectRoot "$resolvedProjectRoot" -Apply
"@
            }
            $result = Invoke-ChildScript -ScriptPath $syncScriptPath -Arguments @('-ProjectRoot', $resolvedProjectRoot, '-Mode', 'Apply')
            if ($result.ExitCode -ne 0) {
                throw 'Применение правил завершилось ошибкой.'
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
            throw "Неизвестная команда '$Command'. Выполните '.\ai-rules.ps1 help'."
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

exit 0
