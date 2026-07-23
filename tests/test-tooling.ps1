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

    $projectRoot = Join-Path $tempRoot 'target-project'
    New-Item -ItemType Directory -Path $projectRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $projectRoot 'AGENTS.md') -Value '# Local agent rules' -Encoding UTF8

    $initializerPath = Join-Path $hubRoot 'scripts/init-project-sync.ps1'
    $initResult = Invoke-HubScript -ScriptPath $initializerPath -Arguments @(
        '-ProjectRoot', $projectRoot,
        '-Profiles', 'standard-product',
        '-SeedProjectFiles'
    )
    Assert-True -Condition ($initResult.ExitCode -eq 0) -Message "initializer must pass: $($initResult.Output)"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $projectRoot '.ai-rules-hub.json')) -Message 'initializer must create manifest'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $projectRoot 'AGENTS.md') -Raw -Encoding UTF8).Trim() -eq '# Local agent rules') -Message 'initializer must not overwrite local AGENTS.md'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $projectRoot 'RULESET.md')) -Message 'initializer must seed missing RULESET.md'

    $syncPath = Join-Path $hubRoot 'scripts/sync-rules.ps1'
    $applyResult = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Apply')
    Assert-True -Condition ($applyResult.ExitCode -eq 0) -Message "first sync apply must pass: $($applyResult.Output)"

    $managedCorePath = Join-Path $projectRoot '.ai-rules/rules/CORE.md'
    $managedProfilePath = Join-Path $projectRoot '.ai-rules/profiles/standard-product.md'
    Assert-True -Condition (Test-Path -LiteralPath $managedCorePath) -Message 'sync must copy core'
    Assert-True -Condition (Test-Path -LiteralPath $managedProfilePath) -Message 'sync must copy selected profile'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $projectRoot '.ai-rules/rules/PRODUCT.md')) -Message 'profile must pull topic dependencies'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $projectRoot '.ai-rules-hub.lock.json')) -Message 'apply must create lock'

    $secondPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($secondPlan.ExitCode -eq 0) -Message 'second plan must pass'
    Assert-True -Condition ($secondPlan.Output -match 'unchanged') -Message 'second plan must report unchanged files'

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

    $manifestPath = Join-Path $projectRoot '.ai-rules-hub.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.profiles = @()
    $manifest.topics = @()
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $orphanPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($orphanPlan.ExitCode -eq 0) -Message 'orphan plan must remain read-only and pass'
    Assert-True -Condition ($orphanPlan.Output -match 'orphan') -Message 'removed selection must report orphan files'

    $orphanApply = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Apply')
    Assert-True -Condition ($orphanApply.ExitCode -eq 0) -Message 'apply must preserve safe orphan files'
    Assert-True -Condition (Test-Path -LiteralPath $managedProfilePath) -Message 'apply must not delete orphan file'

    $postApplyOrphanPlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($postApplyOrphanPlan.Output -match 'orphan') -Message 'lock must retain orphan state after apply'

    $manifest.destination = '../escape'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $escapePlan = Invoke-HubScript -ScriptPath $syncPath -Arguments @('-ProjectRoot', $projectRoot, '-Mode', 'Plan')
    Assert-True -Condition ($escapePlan.ExitCode -ne 0) -Message 'destination path traversal must fail'

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
