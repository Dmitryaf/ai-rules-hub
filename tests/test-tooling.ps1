[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$hubRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
$tempRoot = Join-Path $tempBase "ai-rules-hub-tests-$([Guid]::NewGuid().ToString('N'))"
$assertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:assertionCount++
}

function Get-NormalizedSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8WithoutBom.GetBytes($content)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return '<missing>'
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    return (@(
        Get-ChildItem -LiteralPath $rootFull -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($rootFull.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
                "$relativePath|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
            }
    ) -join "`n")
}

function Invoke-HubScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1 | Out-String
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

New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $documentationRule = Get-Content -LiteralPath (Join-Path $hubRoot 'rules/DOCUMENTATION.md') -Raw -Encoding UTF8
    $agentsTemplate = Get-Content -LiteralPath (Join-Path $hubRoot 'templates/AGENTS.md') -Raw -Encoding UTF8
    $projectRulesTemplate = Get-Content -LiteralPath (Join-Path $hubRoot 'templates/PROJECT_RULES.md') -Raw -Encoding UTF8
    $fullProjectRulesTemplate = Get-Content -LiteralPath (Join-Path $hubRoot 'templates/PROJECT_RULES.full.md') -Raw -Encoding UTF8
    $standardProductProfile = Get-Content -LiteralPath (Join-Path $hubRoot 'profiles/standard-product.md') -Raw -Encoding UTF8
    $publicRepositoryProfile = Get-Content -LiteralPath (Join-Path $hubRoot 'profiles/public-repository.md') -Raw -Encoding UTF8
    $securityRule = Get-Content -LiteralPath (Join-Path $hubRoot 'rules/SECURITY_AND_PRIVACY.md') -Raw -Encoding UTF8
    $deliveryRule = Get-Content -LiteralPath (Join-Path $hubRoot 'rules/GIT_AND_DELIVERY.md') -Raw -Encoding UTF8
    $hubProjectRules = Get-Content -LiteralPath (Join-Path $hubRoot 'hub/PROJECT_RULES.md') -Raw -Encoding UTF8
    $validationWorkflow = Get-Content -LiteralPath (Join-Path $hubRoot '.github/workflows/validate.yml') -Raw -Encoding UTF8
    $hubCheck = Get-Content -LiteralPath (Join-Path $hubRoot 'scripts/check-hub.ps1') -Raw -Encoding UTF8

    Assert-True -Condition ($documentationRule -match 'docs/README\.md' -and $documentationRule -match 'docs/research/' -and $documentationRule -match 'docs/archive/') -Message 'documentation rule must define index, research, and archive roles'
    Assert-True -Condition ($documentationRule -match '(?s)PRODUCT\.md.*ARCHITECTURE\.md.*ROADMAP\.md') -Message 'documentation rule must define canonical current-state documents'
    Assert-True -Condition (([regex]::Matches($documentationRule, 'docs/README\.md')).Count -ge 3) -Message 'documentation creation and audit must route through an index'
    Assert-True -Condition ($documentationRule -match 'PROJECT_RULES\.md' -and $documentationRule -match 'keep / merge / move / archive / delete / unknown') -Message 'documentation rule must define project routing and audit plan'
    Assert-True -Condition ($agentsTemplate -match 'PROJECT_RULES\.md' -and $agentsTemplate -match 'docs/README\.md') -Message 'agent template must route documentation through project rules and index'
    Assert-True -Condition (([regex]::Matches($projectRulesTemplate, '(?m)^## ')).Count -eq 6 -and $projectRulesTemplate.Length -lt 2500 -and $projectRulesTemplate -notmatch '\|.*\|.*\|') -Message 'default project rules template must stay minimal'
    Assert-True -Condition ($fullProjectRulesTemplate -match 'docs/README\.md' -and $fullProjectRulesTemplate -match '\|.*\|.*\|') -Message 'full project rules template must retain detailed routing content'
    Assert-True -Condition ($standardProductProfile -match '\.\./rules/DOCUMENTATION\.md' -and $standardProductProfile -match 'docs/README\.md') -Message 'standard-product must include documentation rule and recommend an index'
    Assert-True -Condition ($hubProjectRules -match '\.\./profiles/public-repository\.md' -and $hubProjectRules -match 'maintainer-led') -Message 'hub project rules must apply the public repository profile explicitly'
    Assert-True -Condition ($publicRepositoryProfile -match 'LICENSE|license' -and $publicRepositoryProfile -match 'third-party' -and $publicRepositoryProfile -match 'contributions' -and $publicRepositoryProfile -match 'Repository settings') -Message 'public repository profile must cover licensing, attribution, contributions, and settings'
    Assert-True -Condition ($securityRule -match 'Issues' -and $securityRule -match 'AGENTS\.md' -and $securityRule -match 'connector context') -Message 'security rule must treat public input and agent instructions as trust-boundary concerns'
    Assert-True -Condition ($deliveryRule -match 'GitHub Actions' -and $deliveryRule -match 'commit SHA' -and $deliveryRule -match 'pull_request_target' -and $deliveryRule -match 'workflow_run') -Message 'delivery rule must define safe GitHub Actions defaults'
    Assert-True -Condition ($validationWorkflow -match '(?m)^permissions:\s*\r?\n\s+contents:\s*read\s*$' -and $validationWorkflow -match 'actions/checkout@[0-9a-f]{40}' -and $validationWorkflow -match 'persist-credentials:\s*false') -Message 'validation workflow must be read-only and use pinned checkout without persisted credentials'
    Assert-True -Condition ((Test-Path -LiteralPath (Join-Path $hubRoot 'CONTRIBUTING.md')) -and (Test-Path -LiteralPath (Join-Path $hubRoot '.github/SECURITY.md'))) -Message 'public repository entry points must exist'
    Assert-True -Condition ($hubCheck -match 'LICENSE\.md' -and $hubCheck -match 'GitHub-discoverable CONTRIBUTING' -and $hubCheck -match 'full 40-character commit SHA') -Message 'hub check must enforce public repository hygiene'

    $cliPath = Join-Path $hubRoot 'ai-rules.ps1'
    $helpResult = Invoke-HubScript -ScriptPath $cliPath -Arguments @('help')
    Assert-True -Condition ($helpResult.ExitCode -eq 0 -and $helpResult.Output -match 'No command runs git pull or git fetch') -Message 'CLI help must pass and explain the no-fetch boundary'
    $profilesResult = Invoke-HubScript -ScriptPath $cliPath -Arguments @('list', 'profiles')
    Assert-True -Condition ($profilesResult.ExitCode -eq 0 -and $profilesResult.Output -match 'profiles/standard-product\.md' -and $profilesResult.Output -match 'architecture-and-data') -Message 'CLI profile list must use real catalog data'
    $topicsResult = Invoke-HubScript -ScriptPath $cliPath -Arguments @('list', 'topics')
    Assert-True -Condition ($topicsResult.ExitCode -eq 0 -and $topicsResult.Output -match 'rules/PRODUCT\.md' -and $topicsResult.Output -match 'project-study') -Message 'CLI topic list must use real catalog data'
    $unknownCommandResult = Invoke-HubScript -ScriptPath $cliPath -Arguments @('unknown-command')
    Assert-True -Condition ($unknownCommandResult.ExitCode -ne 0 -and $unknownCommandResult.Output -match 'Unknown command') -Message 'unknown CLI command must fail clearly'
    $missingProjectRootResult = Invoke-HubScript -ScriptPath $cliPath -Arguments @('status')
    Assert-True -Condition ($missingProjectRootResult.ExitCode -ne 0 -and $missingProjectRootResult.Output -match 'requires -ProjectRoot') -Message 'project commands must explain a missing ProjectRoot'
    $unknownSelectionRoot = Join-Path $tempRoot 'unknown selection project'
    New-Item -ItemType Directory -Path $unknownSelectionRoot | Out-Null
    $unknownProfileResult = Invoke-HubScript -ScriptPath $cliPath -Arguments @('init', '-ProjectRoot', $unknownSelectionRoot, '-Profiles', 'missing-profile')
    Assert-True -Condition ($unknownProfileResult.ExitCode -ne 0 -and $unknownProfileResult.Output -match 'Unknown profile') -Message 'CLI init must validate profiles through the catalog'

    $validatorPath = Join-Path $hubRoot 'scripts/validate-commit-message.ps1'
    $validMessagePath = Join-Path $tempRoot 'valid-message.txt'
    $invalidMessagePath = Join-Path $tempRoot 'invalid-message.txt'

    Set-Content -LiteralPath $validMessagePath -Value 'feat(sync): add manifest' -Encoding UTF8
    $validResult = Invoke-HubScript -ScriptPath $validatorPath -Arguments @('-MessageFile', $validMessagePath)
    Assert-True -Condition ($validResult.ExitCode -eq 0) -Message 'valid conventional commit must pass'

    Set-Content -LiteralPath $invalidMessagePath -Value 'feat: add manifest.' -Encoding UTF8
    $invalidResult = Invoke-HubScript -ScriptPath $validatorPath -Arguments @('-MessageFile', $invalidMessagePath)
    Assert-True -Condition ($invalidResult.ExitCode -ne 0) -Message 'commit without scope must fail'

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $hubRoot -c core.hooksPath=.githooks hook run commit-msg -- $validMessagePath 2>&1 | Out-Null
        $validHookExitCode = $LASTEXITCODE
        & git -C $hubRoot -c core.hooksPath=.githooks hook run commit-msg -- $invalidMessagePath 2>&1 | Out-Null
        $invalidHookExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-True -Condition ($validHookExitCode -eq 0) -Message 'repository commit-msg hook must invoke validator'
    Assert-True -Condition ($invalidHookExitCode -ne 0) -Message 'repository commit-msg hook must reject invalid message'

    $initializerPath = Join-Path $hubRoot 'scripts/init-project-sync.ps1'

    $notInitializedProjectRoot = Join-Path $tempRoot 'not initialized project'
    New-Item -ItemType Directory -Path $notInitializedProjectRoot | Out-Null
    $notInitializedStatus = Invoke-HubScript -ScriptPath $cliPath -Arguments @('status', '-ProjectRoot', $notInitializedProjectRoot)
    Assert-True -Condition ($notInitializedStatus.ExitCode -eq 0 -and $notInitializedStatus.Output -match 'State: not-initialized') -Message 'status must identify a project without manifest'

    $cliProjectRoot = Join-Path $tempRoot 'CLI project'
    New-Item -ItemType Directory -Path $cliProjectRoot | Out-Null
    $cliInit = Invoke-HubScript -ScriptPath $cliPath -Arguments @(
        'init', '-ProjectRoot', $cliProjectRoot, '-Profiles', 'standard-product'
    )
    Assert-True -Condition ($cliInit.ExitCode -eq 0) -Message "CLI init must pass: $($cliInit.Output)"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $cliProjectRoot '.ai-rules/manifest.json')) -Message 'CLI init must create manifest'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $cliProjectRoot 'AGENTS.md')) -Message 'CLI init must seed AGENTS.md by default'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $cliProjectRoot '.ai-rules/RULESET.md')) -Message 'CLI init must seed RULESET.md by default'
    $seededProjectRules = Get-Content -LiteralPath (Join-Path $cliProjectRoot '.ai-rules/PROJECT_RULES.md') -Raw -Encoding UTF8
    Assert-True -Condition (([regex]::Matches($seededProjectRules, '(?m)^## ')).Count -eq 6 -and $seededProjectRules.Length -lt 2500) -Message 'CLI init must seed the minimal PROJECT_RULES.md'
    $repeatCliInit = Invoke-HubScript -ScriptPath $cliPath -Arguments @('init', '-ProjectRoot', $cliProjectRoot)
    Assert-True -Condition ($repeatCliInit.ExitCode -ne 0 -and $repeatCliInit.Output -match 'already exists') -Message 'repeat CLI init must fail explicitly'

    $cliProjectBeforeStatus = Get-TreeSnapshot -Root $cliProjectRoot
    $unpinnedStatus = Invoke-HubScript -ScriptPath $cliPath -Arguments @('status', '-ProjectRoot', $cliProjectRoot)
    Assert-True -Condition ($unpinnedStatus.ExitCode -eq 0 -and $unpinnedStatus.Output -match 'State: unpinned') -Message 'status must identify an unpinned manifest'
    Assert-True -Condition ((Get-TreeSnapshot -Root $cliProjectRoot) -eq $cliProjectBeforeStatus) -Message 'status must not change project files'

    $cliApply = Invoke-HubScript -ScriptPath $cliPath -Arguments @('apply', '-ProjectRoot', $cliProjectRoot)
    Assert-True -Condition ($cliApply.ExitCode -eq 0) -Message "CLI apply must use existing sync: $($cliApply.Output)"
    $cliManifestPath = Join-Path $cliProjectRoot '.ai-rules/manifest.json'
    $cliManifest = Get-Content -LiteralPath $cliManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentHubRevision = (& git -C $hubRoot rev-parse HEAD).Trim()
    $cliManifest.source.revision = $currentHubRevision
    $cliManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cliManifestPath -Encoding UTF8
    $synchronizedSnapshot = Get-TreeSnapshot -Root $cliProjectRoot
    $synchronizedStatus = Invoke-HubScript -ScriptPath $cliPath -Arguments @('status', '-ProjectRoot', $cliProjectRoot)
    Assert-True -Condition ($synchronizedStatus.ExitCode -eq 0 -and $synchronizedStatus.Output -match 'State: synchronized') -Message "status must identify synchronized project: $($synchronizedStatus.Output)"
    Assert-True -Condition ((Get-TreeSnapshot -Root $cliProjectRoot) -eq $synchronizedSnapshot) -Message 'synchronized status must stay read-only'

    $updatePreview = Invoke-HubScript -ScriptPath $cliPath -Arguments @('update', '-ProjectRoot', $cliProjectRoot)
    Assert-True -Condition ($updatePreview.ExitCode -eq 0 -and $updatePreview.Output -match 'Current project revision:' -and $updatePreview.Output -match 'Target hub revision:' -and $updatePreview.Output -match 'No files were changed') -Message 'update preview must show both revisions and remain explicit'
    Assert-True -Condition ((Get-TreeSnapshot -Root $cliProjectRoot) -eq $synchronizedSnapshot) -Message 'update preview must not change manifest, lock, or upstream'

    $existingFilesProjectRoot = Join-Path $tempRoot 'project with existing local files'
    $existingFilesRulesRoot = Join-Path $existingFilesProjectRoot '.ai-rules'
    New-Item -ItemType Directory -Path $existingFilesRulesRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $existingFilesProjectRoot 'AGENTS.md') -Value '# Existing agent rules' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $existingFilesRulesRoot 'RULESET.md') -Value '# Existing ruleset' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $existingFilesRulesRoot 'PROJECT_RULES.md') -Value '# Existing project rules' -Encoding UTF8
    $existingFilesInit = Invoke-HubScript -ScriptPath $initializerPath -Arguments @(
        '-ProjectRoot', $existingFilesProjectRoot,
        '-Profiles', 'standard-product',
        '-SeedProjectFiles'
    )
    Assert-True -Condition ($existingFilesInit.ExitCode -eq 0) -Message "initializer must support an existing local rules directory: $($existingFilesInit.Output)"
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $existingFilesProjectRoot 'AGENTS.md') -Raw -Encoding UTF8).Trim() -eq '# Existing agent rules') -Message 'initializer must preserve existing root AGENTS.md'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $existingFilesRulesRoot 'RULESET.md') -Raw -Encoding UTF8).Trim() -eq '# Existing ruleset') -Message 'initializer must preserve existing local RULESET.md'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $existingFilesRulesRoot 'PROJECT_RULES.md') -Raw -Encoding UTF8).Trim() -eq '# Existing project rules') -Message 'initializer must preserve existing local PROJECT_RULES.md'

    $legacyProjectRoot = Join-Path $tempRoot 'legacy project'
    New-Item -ItemType Directory -Path $legacyProjectRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyProjectRoot '.ai-rules-hub.json') -Value '{}' -Encoding UTF8
    $legacyInit = Invoke-HubScript -ScriptPath $initializerPath -Arguments @('-ProjectRoot', $legacyProjectRoot)
    Assert-True -Condition ($legacyInit.ExitCode -ne 0) -Message 'initializer must stop on a legacy root manifest'
    Assert-True -Condition ($legacyInit.Output -match 'migrate it explicitly') -Message 'legacy error must require explicit migration'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $legacyProjectRoot '.ai-rules'))) -Message 'legacy detection must not create the new structure'

    $projectRoot = Join-Path $tempRoot 'target project with spaces'
    New-Item -ItemType Directory -Path $projectRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $projectRoot 'AGENTS.md') -Value '# Local agent rules' -Encoding UTF8

    $initResult = Invoke-HubScript -ScriptPath $initializerPath -Arguments @(
        '-ProjectRoot', $projectRoot,
        '-Topics', 'project-study',
        '-Profiles', 'standard-product',
        '-SeedProjectFiles'
    )
    Assert-True -Condition ($initResult.ExitCode -eq 0) -Message "initializer must pass: $($initResult.Output)"
    $localRulesRoot = Join-Path $projectRoot '.ai-rules'
    $manifestPath = Join-Path $localRulesRoot 'manifest.json'
    $rulesetPath = Join-Path $localRulesRoot 'RULESET.md'
    $projectRulesPath = Join-Path $localRulesRoot 'PROJECT_RULES.md'
    $lockPath = Join-Path $localRulesRoot 'lock.json'
    $upstreamRoot = Join-Path $localRulesRoot 'upstream'
    Assert-True -Condition (Test-Path -LiteralPath $localRulesRoot -PathType Container) -Message 'initializer must create local rules directory'
    Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message 'initializer must create nested manifest'
    Assert-True -Condition ((Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).schemaVersion -eq '0.2') -Message 'initializer must create manifest schema 0.2'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $projectRoot 'AGENTS.md') -Raw -Encoding UTF8).Trim() -eq '# Local agent rules') -Message 'initializer must not overwrite local AGENTS.md'
    Assert-True -Condition (Test-Path -LiteralPath $rulesetPath) -Message 'initializer must seed nested RULESET.md'
    Assert-True -Condition (Test-Path -LiteralPath $projectRulesPath) -Message 'initializer must seed nested PROJECT_RULES.md'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.ai-rules-hub.json'))) -Message 'initializer must not create old root manifest'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.ai-rules-hub.lock.json'))) -Message 'initializer must not create old root lock'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'RULESET.md'))) -Message 'initializer must not create root RULESET.md'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'PROJECT_RULES.md'))) -Message 'initializer must not create root PROJECT_RULES.md'

    $manifestBeforeSync = [System.IO.File]::ReadAllText($manifestPath)
    $rulesetBeforeSync = [System.IO.File]::ReadAllText($rulesetPath)
    $projectRulesBeforeSync = [System.IO.File]::ReadAllText($projectRulesPath)

    $syncPath = Join-Path $hubRoot 'scripts/sync-rules.ps1'
    $initialPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($initialPlan.ExitCode -eq 0) -Message "initial plan must pass for a path with spaces: $($initialPlan.Output)"
    Assert-True -Condition ($initialPlan.Output -match 'Plan only: no project files were changed') -Message 'plan must explain that it is read-only'
    Assert-True -Condition ($initialPlan.Output -match 'Summary: add=') -Message 'plan must print an action summary'
    Assert-True -Condition ($initialPlan.Output -match 'Managed root: \.ai-rules/upstream') -Message 'plan must identify upstream as the managed root'
    Assert-True -Condition (-not (Test-Path -LiteralPath $upstreamRoot)) -Message 'plan must not create upstream directory'
    Assert-True -Condition (-not (Test-Path -LiteralPath $lockPath)) -Message 'plan must not create nested lock'
    Assert-True -Condition ([System.IO.File]::ReadAllText($manifestPath) -eq $manifestBeforeSync) -Message 'plan must not change manifest'
    Assert-True -Condition ([System.IO.File]::ReadAllText($rulesetPath) -eq $rulesetBeforeSync) -Message 'plan must not change RULESET.md'
    Assert-True -Condition ([System.IO.File]::ReadAllText($projectRulesPath) -eq $projectRulesBeforeSync) -Message 'plan must not change PROJECT_RULES.md'

    $applyResult = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Apply')
    Assert-True -Condition ($applyResult.ExitCode -eq 0) -Message "first sync apply must pass: $($applyResult.Output)"

    $managedCorePath = Join-Path $upstreamRoot 'CORE.md'
    $managedProfilePath = Join-Path $upstreamRoot 'profiles/standard-product.md'
    Assert-True -Condition (Test-Path -LiteralPath $managedCorePath) -Message 'sync must copy core'
    Assert-True -Condition (Test-Path -LiteralPath $managedProfilePath) -Message 'sync must copy selected profile'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $upstreamRoot 'rules/PRODUCT.md')) -Message 'profile must pull topic dependencies'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $upstreamRoot 'rules/DOCUMENTATION.md')) -Message 'standard-product must pull documentation architecture rule'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $upstreamRoot 'rules/PROJECT_STUDY.md')) -Message 'sync must copy explicitly selected project-study topic'
    Assert-True -Condition (Test-Path -LiteralPath $lockPath) -Message 'apply must create lock'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $projectRoot 'AGENTS.md') -Raw -Encoding UTF8).Trim() -eq '# Local agent rules') -Message 'apply must not overwrite local AGENTS.md'
    Assert-True -Condition ([System.IO.File]::ReadAllText($manifestPath) -eq $manifestBeforeSync) -Message 'apply must not overwrite manifest'
    Assert-True -Condition ([System.IO.File]::ReadAllText($rulesetPath) -eq $rulesetBeforeSync) -Message 'apply must not overwrite nested RULESET.md'
    Assert-True -Condition ([System.IO.File]::ReadAllText($projectRulesPath) -eq $projectRulesBeforeSync) -Message 'apply must not overwrite nested PROJECT_RULES.md'

    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $hubRevision = (& git -C $hubRoot rev-parse HEAD).Trim()
    Assert-True -Condition ($lock.schemaVersion -eq '0.2') -Message 'lock must use schema 0.2'
    Assert-True -Condition ($lock.manifest -eq '.ai-rules/manifest.json') -Message 'lock must record nested manifest path'
    Assert-True -Condition ($lock.managedRoot -eq '.ai-rules/upstream') -Message 'lock must record upstream as managed root'
    Assert-True -Condition ($lock.source.revision -eq $hubRevision) -Message 'lock must contain exact hub revision'
    Assert-True -Condition ($lock.source.revision -match '^[0-9a-f]{40}$') -Message 'lock revision must be a full commit SHA'
    $coreLockEntry = @($lock.files | Where-Object { $_.target -eq '.ai-rules/upstream/CORE.md' })[0]
    Assert-True -Condition ($null -ne $coreLockEntry) -Message 'lock must contain managed core entry'
    Assert-True -Condition ($coreLockEntry.sha256 -eq (Get-NormalizedSha256 -Path $managedCorePath)) -Message 'lock must contain normalized managed-file SHA-256'

    $secondPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($secondPlan.ExitCode -eq 0) -Message 'second plan must pass'
    Assert-True -Condition ($secondPlan.Output -match 'unchanged') -Message 'second plan must report unchanged files'

    $lockBeforeSecondApply = [System.IO.File]::ReadAllText($lockPath)
    $secondApply = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Apply')
    $lockAfterSecondApply = [System.IO.File]::ReadAllText($lockPath)
    Assert-True -Condition ($secondApply.ExitCode -eq 0) -Message "second apply must pass: $($secondApply.Output)"
    Assert-True -Condition ($secondApply.Output -match 'Lock unchanged') -Message 'idempotent apply must report unchanged lock'
    Assert-True -Condition ($lockAfterSecondApply -eq $lockBeforeSecondApply) -Message 'idempotent apply must not rewrite lock content'

    $coreText = [System.IO.File]::ReadAllText($managedCorePath).Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($managedCorePath, $coreText.Replace("`n", "`r`n"), $utf8WithoutBom)
    $lineEndingPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($lineEndingPlan.ExitCode -eq 0) -Message 'line-ending-only change must not fail plan'
    Assert-True -Condition ($lineEndingPlan.Output -notmatch 'conflict') -Message 'LF and CRLF must have the same managed hash'

    Add-Content -LiteralPath $managedCorePath -Value "`nlocal change" -Encoding UTF8
    $conflictApply = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Apply')
    Assert-True -Condition ($conflictApply.ExitCode -ne 0) -Message 'apply must stop on locally modified managed file'
    Assert-True -Condition ((Get-Content -LiteralPath $managedCorePath -Raw -Encoding UTF8) -match 'local change') -Message 'conflicting target must remain untouched'
    Copy-Item -LiteralPath (Join-Path $hubRoot 'rules/CORE.md') -Destination $managedCorePath -Force

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Content -LiteralPath $managedProfilePath -Value "`nlocal profile change" -Encoding UTF8
    $manifest.profiles = @()
    $manifest.topics = @()
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $orphanPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($orphanPlan.ExitCode -eq 0) -Message 'orphan plan must remain read-only and pass'
    Assert-True -Condition ($orphanPlan.Output -match 'orphan') -Message 'removed selection must report orphan files'
    Assert-True -Condition ($orphanPlan.Output -match 'orphan-modified') -Message 'locally changed deselected file must report orphan-modified'

    $orphanApply = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Apply')
    Assert-True -Condition ($orphanApply.ExitCode -eq 0) -Message 'apply must preserve safe orphan files'
    Assert-True -Condition (Test-Path -LiteralPath $managedProfilePath) -Message 'apply must not delete orphan file'
    Assert-True -Condition ((Get-Content -LiteralPath $managedProfilePath -Raw -Encoding UTF8) -match 'local profile change') -Message 'apply must preserve modified orphan content'

    $orphanLock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profileLockEntry = @($orphanLock.files | Where-Object { $_.target -eq '.ai-rules/upstream/profiles/standard-product.md' })[0]
    Assert-True -Condition ($profileLockEntry.state -eq 'orphan') -Message 'lock must retain deselected file as orphan'

    $postApplyOrphanPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($postApplyOrphanPlan.Output -match 'orphan') -Message 'lock must retain orphan state after apply'

    $validLockJson = [System.IO.File]::ReadAllText($lockPath)
    $invalidLock = $validLockJson | ConvertFrom-Json
    $invalidLock.files[0].target = '.ai-rules/PROJECT_RULES.md'
    $invalidLock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lockPath -Encoding UTF8
    $outsideManagedPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($outsideManagedPlan.ExitCode -ne 0) -Message 'locked target outside upstream must fail'
    Assert-True -Condition ($outsideManagedPlan.Output -match 'outside the managed upstream directory') -Message 'outside-managed error must explain the lock boundary'
    [System.IO.File]::WriteAllText($lockPath, $validLockJson, (New-Object System.Text.UTF8Encoding($false)))

    $cleanHubRoot = Join-Path $tempRoot 'clean hub fixture'
    New-Item -ItemType Directory -Path $cleanHubRoot | Out-Null
    foreach ($fixtureDirectory in @('profiles', 'rules', 'scripts', 'sync', 'templates')) {
        Copy-Item -LiteralPath (Join-Path $hubRoot $fixtureDirectory) -Destination $cleanHubRoot -Recurse
    }
    Copy-Item -LiteralPath $cliPath -Destination (Join-Path $cleanHubRoot 'ai-rules.ps1')
    & git -C $cleanHubRoot init --quiet
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'clean update fixture must initialize a Git repository'
    & git -C $cleanHubRoot config core.autocrlf false
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'clean update fixture must keep copied line endings stable'
    & git -C $cleanHubRoot add --all
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'clean update fixture files must stage'
    & git -C $cleanHubRoot -c user.name='AI Rules Hub Tests' -c user.email='tests@example.invalid' commit --quiet -m 'test(sync): create clean fixture'
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'clean update fixture must create a commit'

    $cleanCliPath = Join-Path $cleanHubRoot 'ai-rules.ps1'
    $updateProjectRoot = Join-Path $tempRoot 'update apply project'
    New-Item -ItemType Directory -Path $updateProjectRoot | Out-Null
    $cleanInit = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('init', '-ProjectRoot', $updateProjectRoot, '-Profiles', 'standard-product')
    Assert-True -Condition ($cleanInit.ExitCode -eq 0) -Message "clean CLI init must pass: $($cleanInit.Output)"
    $cleanInitialApply = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('apply', '-ProjectRoot', $updateProjectRoot)
    Assert-True -Condition ($cleanInitialApply.ExitCode -eq 0) -Message "clean initial Apply must pass: $($cleanInitialApply.Output)"

    $updateManifestPath = Join-Path $updateProjectRoot '.ai-rules/manifest.json'
    $updateLockPath = Join-Path $updateProjectRoot '.ai-rules/lock.json'
    $initialCleanHubRevision = (& git -C $cleanHubRoot rev-parse HEAD).Trim()
    $initialUpdateManifest = Get-Content -LiteralPath $updateManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $initialUpdateManifest.source.revision = $initialCleanHubRevision
    $initialUpdateManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $updateManifestPath -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $cleanHubRoot 'fixture-revision.txt') -Value 'second clean revision' -Encoding UTF8
    & git -C $cleanHubRoot add fixture-revision.txt
    & git -C $cleanHubRoot -c user.name='AI Rules Hub Tests' -c user.email='tests@example.invalid' commit --quiet -m 'test(sync): advance fixture revision'
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'clean update fixture must advance to a second revision'
    $updateAvailableStatus = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('status', '-ProjectRoot', $updateProjectRoot)
    Assert-True -Condition ($updateAvailableStatus.ExitCode -eq 0 -and $updateAvailableStatus.Output -match 'State: update-available') -Message "status must identify a newer hub checkout: $($updateAvailableStatus.Output)"

    $updateApply = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('update', '-ProjectRoot', $updateProjectRoot, '-Apply')
    Assert-True -Condition ($updateApply.ExitCode -eq 0 -and $updateApply.Output -match 'Revision accepted and synchronization applied') -Message "update -Apply must pass in a clean hub: $($updateApply.Output)"
    $cleanHubRevision = (& git -C $cleanHubRoot rev-parse HEAD).Trim()
    $updatedManifest = Get-Content -LiteralPath $updateManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($updatedManifest.source.revision -eq $cleanHubRevision -and $updatedManifest.source.revision -match '^[0-9a-f]{40}$') -Message 'update -Apply must write the full current hub SHA'

    $beforeIdempotentUpdate = Get-TreeSnapshot -Root $updateProjectRoot
    $idempotentUpdate = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('update', '-ProjectRoot', $updateProjectRoot, '-Apply')
    Assert-True -Condition ($idempotentUpdate.ExitCode -eq 0) -Message "repeated update must pass: $($idempotentUpdate.Output)"
    Assert-True -Condition ((Get-TreeSnapshot -Root $updateProjectRoot) -eq $beforeIdempotentUpdate) -Message 'repeated update on the same revision must be idempotent'

    $updateManagedCorePath = Join-Path $updateProjectRoot '.ai-rules/upstream/CORE.md'
    Add-Content -LiteralPath $updateManagedCorePath -Value "`nlocal conflict" -Encoding UTF8
    $manifestBeforeConflict = [System.IO.File]::ReadAllBytes($updateManifestPath)
    $lockBeforeConflict = [System.IO.File]::ReadAllBytes($updateLockPath)
    $conflictingUpdate = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('update', '-ProjectRoot', $updateProjectRoot, '-Apply')
    Assert-True -Condition ($conflictingUpdate.ExitCode -ne 0 -and $conflictingUpdate.Output -match 'conflict') -Message 'update -Apply must stop before Apply on a managed conflict'
    Assert-True -Condition (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($updateManifestPath))) -eq ([Convert]::ToBase64String($manifestBeforeConflict))) -Message 'conflicting update must not change manifest'
    Assert-True -Condition (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($updateLockPath))) -eq ([Convert]::ToBase64String($lockBeforeConflict))) -Message 'conflicting update must not execute Apply or change lock'
    Copy-Item -LiteralPath (Join-Path $cleanHubRoot 'rules/CORE.md') -Destination $updateManagedCorePath -Force

    $failingManifest = Get-Content -LiteralPath $updateManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $failingManifest.source.revision = $null
    $failingManifest.topics = @('project-study')
    $failingManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $updateManifestPath -Encoding UTF8
    $manifestBeforeFailedApply = [System.IO.File]::ReadAllBytes($updateManifestPath)
    Set-ItemProperty -LiteralPath $updateLockPath -Name IsReadOnly -Value $true
    try {
        $failedUpdateApply = Invoke-HubScript -ScriptPath $cleanCliPath -Arguments @('update', '-ProjectRoot', $updateProjectRoot, '-Apply')
    }
    finally {
        Set-ItemProperty -LiteralPath $updateLockPath -Name IsReadOnly -Value $false
    }
    Assert-True -Condition ($failedUpdateApply.ExitCode -ne 0 -and $failedUpdateApply.Output -match 'Apply failed') -Message 'update must expose an underlying Apply failure'
    Assert-True -Condition (([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($updateManifestPath))) -eq ([Convert]::ToBase64String($manifestBeforeFailedApply))) -Message 'failed Apply must restore the original manifest bytes'

    $manifest.schemaVersion = '0.1'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $oldSchemaPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($oldSchemaPlan.ExitCode -ne 0) -Message 'old manifest schema must fail explicitly'
    $manifest.schemaVersion = '0.2'
    $manifest.source.revision = '1234567'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $shortRevisionPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($shortRevisionPlan.ExitCode -ne 0) -Message 'short source revision must fail'
    Assert-True -Condition ($shortRevisionPlan.Output -match 'full 40-character Git commit SHA') -Message 'invalid revision error must explain the required format'

    Write-Host "Tooling tests passed: $assertionCount assertions." -ForegroundColor Green
}
finally {
    $tempRootFull = [System.IO.Path]::GetFullPath($tempRoot)
    $tempPrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
    $tempLeaf = Split-Path -Leaf $tempRootFull
    if (
        $tempRootFull.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        $tempLeaf.StartsWith('ai-rules-hub-tests-', [System.StringComparison]::Ordinal)
    ) {
        Remove-Item -LiteralPath $tempRootFull -Recurse -Force
    }
    else {
        Write-Warning "Temporary directory was not removed because its path failed safety validation: $tempRootFull"
    }
}

exit 0
