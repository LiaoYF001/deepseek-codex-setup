#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testDirectory = Join-Path $PSScriptRoot ('workspace-fixtures-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\delegate-deepseek\scripts\ensure_workspace.ps1'
$shellPath = (Get-Process -Id $PID).Path
$results = [Collections.Generic.List[object]]::new()

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function New-Directory([string] $Name) {
    $path = Join-Path $testDirectory $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}
function Write-Config([string] $Path, [object] $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
}
function Hash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Start-Helper([string] $Workspace, [string] $Config, [string] $Mode = 'explicit') {
    $info = [Diagnostics.ProcessStartInfo]::new($shellPath)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helperPath, '-WorkspacePath', $Workspace)) { $info.ArgumentList.Add($argument) }
    if ($Mode -eq 'explicit') {
        $info.ArgumentList.Add('-ConfigPath'); $info.ArgumentList.Add($Config)
    } elseif ($Mode -eq 'override') {
        $info.Environment['MIXAGENTS_BROKER_CONFIG'] = $Config
    } elseif ($Mode -eq 'default') {
        $info.Environment.Remove('MIXAGENTS_BROKER_CONFIG') | Out-Null
        $info.Environment['APPDATA'] = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($Config))
    }
    return [Diagnostics.Process]::Start($info)
}
function Finish-Helper([Diagnostics.Process] $Process) {
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    $exitCode = $Process.ExitCode
    $Process.Dispose()
    Assert ([string]::IsNullOrWhiteSpace($stderr)) 'Helper emitted stderr.'
    Assert (-not $stdout.Contains('routing-fixture-never-output')) 'Helper exposed fixture content.'
    return @{ code = $exitCode; result = ($stdout | ConvertFrom-Json -AsHashtable) }
}
function Run-Helper([string] $Workspace, [string] $Config, [string] $Mode = 'explicit') {
    return Finish-Helper (Start-Helper $Workspace $Config $Mode)
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $results.Add(@{ name = $Name; status = 'passed' }) }
    catch { $results.Add(@{ name = $Name; status = 'failed'; reason = $_.Exception.Message }) }
}
function Assert-FailureUnchanged([string] $Workspace, [string] $Config, [string] $ErrorCode) {
    $before = Hash $Config
    $response = Run-Helper $Workspace $Config
    Assert ($response.code -eq 1) 'Expected exit 1.'
    Assert ($response.result.Count -eq 1 -and $response.result.error -eq $ErrorCode) 'Expected fixed error only.'
    Assert ((Hash $Config) -eq $before) 'Failure modified the config.'
}

try {
$taskPath = New-Directory 'task'
$childPath = New-Directory 'task/child'
$siblingPath = New-Directory 'task-sibling'
$configPath = Join-Path $testDirectory 'broker.json'
$fixture = [ordered]@{
    workspaceRoots = @()
    routes = @{ deepseek = @{ model = 'fixture'; maxTokens = 12345; sandbox = 'read-only'; enabled = $true; nested = @('routing-fixture-never-output', $null, @{ x = 2.5 }) } }
    providerSelection = 'unchanged'
    futureField = @{ largeNumber = 9007199254740993L; unicode = '保持原配置'; other = $false }
}
Write-Config $configPath $fixture

Test-Case 'merge_preserves_fields_and_original_backup' {
    $originalHash = Hash $configPath
    $response = Run-Helper $taskPath $configPath
    Assert ($response.code -eq 0 -and $response.result.changed -and $response.result.reconnectRequired) 'Initial merge failed.'
    $actual = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    Assert ($actual.workspaceRoots.Count -eq 1 -and $actual.workspaceRoots[0] -eq $taskPath) 'Incorrect root.'
    Assert (($actual.routes | ConvertTo-Json -Depth 30 -Compress) -eq ($fixture.routes | ConvertTo-Json -Depth 30 -Compress)) 'Routes changed.'
    Assert (($actual.futureField | ConvertTo-Json -Depth 30 -Compress) -eq ($fixture.futureField | ConvertTo-Json -Depth 30 -Compress)) 'Unrelated field changed.'
    Assert ($actual.providerSelection -eq $fixture.providerSelection) 'Provider field changed.'
    Assert ((Hash $response.result.backup) -eq $originalHash) 'Backup differs from original bytes.'
}
Test-Case 'exact_idempotency_retains_file_hash_and_timestamp' {
    $before = Hash $configPath
    $timestamp = (Get-Item -LiteralPath $configPath).LastWriteTimeUtc
    $response = Run-Helper $taskPath $configPath
    Assert ($response.code -eq 0 -and -not $response.result.changed -and -not $response.result.reconnectRequired -and $null -eq $response.result.backup) 'Exact root was not idempotent.'
    Assert ((Hash $configPath) -eq $before -and (Get-Item -LiteralPath $configPath).LastWriteTimeUtc -eq $timestamp) 'Idempotent run wrote config.'
}
Test-Case 'ancestor_covers_child_without_write' {
    $before = Hash $configPath
    $response = Run-Helper $childPath $configPath
    Assert ($response.code -eq 0 -and -not $response.result.changed -and (Hash $configPath) -eq $before) 'Child coverage failed.'
}
Test-Case 'sibling_prefix_requires_its_own_root' {
    $response = Run-Helper $siblingPath $configPath
    $actual = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    Assert ($response.code -eq 0 -and $response.result.changed -and $actual.workspaceRoots.Count -eq 2) 'Sibling boundary was incorrect.'
    Assert ($actual.workspaceRoots[0] -eq $taskPath -and $actual.workspaceRoots[1] -eq $siblingPath) 'Existing root was changed.'
}
Test-Case 'junction_alias_is_canonical_and_idempotent' {
    $alias = Join-Path $testDirectory 'task-alias'
    New-Item -ItemType Junction -Path $alias -Target $taskPath | Out-Null
    $before = Hash $configPath
    $response = Run-Helper (Join-Path $alias 'child') $configPath
    Assert ($response.code -eq 0 -and -not $response.result.changed -and $response.result.root -eq $childPath) 'Junction alias was not resolved.'
    Assert ((Hash $configPath) -eq $before) 'Alias run modified config.'
}
Test-Case 'existing_junction_root_covers_real_directory' {
    $aliasConfig = Join-Path $testDirectory 'alias.json'
    Write-Config $aliasConfig @{ workspaceRoots = @((Join-Path $testDirectory 'task-alias')); routes = $fixture.routes }
    $before = Hash $aliasConfig
    $response = Run-Helper $childPath $aliasConfig
    Assert ($response.code -eq 0 -and -not $response.result.changed -and (Hash $aliasConfig) -eq $before) 'Existing alias coverage failed.'
}
foreach ($variant in @('missing', 'null')) {
    $caseVariant = $variant
    Test-Case ($variant + '_roots_can_be_initialized') {
        $path = Join-Path $testDirectory ($caseVariant + '.json')
        $value = @{ routes = $fixture.routes }
        if ($caseVariant -eq 'null') { $value.workspaceRoots = $null }
        Write-Config $path $value
        $response = Run-Helper $taskPath $path
        Assert ($response.code -eq 0 -and $response.result.changed) 'Optional roots failed.'
    }
}
$badConfigs = @(
    @{ name = 'malformed_json'; text = '{"workspaceRoots":['; error = 'config_invalid_json' },
    @{ name = 'array_document'; text = '[]'; error = 'config_invalid_structure' },
    @{ name = 'roots_string'; text = '{"workspaceRoots":"C:/"}'; error = 'config_invalid_structure' },
    @{ name = 'root_not_string'; text = '{"workspaceRoots":[42]}'; error = 'config_invalid_structure' },
    @{ name = 'duplicate_roots'; text = '{"workspaceRoots":[],"workspaceRoots":[]}'; error = 'config_invalid_structure' },
    @{ name = 'relative_existing_root'; text = '{"workspaceRoots":["relative"]}'; error = 'existing_root_invalid' },
    @{ name = 'invalid_character_existing_root'; text = '{"workspaceRoots":["C:/bad<root"]}'; error = 'existing_root_invalid' }
)
foreach ($bad in $badConfigs) {
    Test-Case $bad.name {
        $path = Join-Path $testDirectory ($bad.name + '.json')
        [IO.File]::WriteAllText($path, $bad.text)
        Assert-FailureUnchanged $taskPath $path $bad.error
    }
}
Test-Case 'deleted_existing_root_preserved_with_new_root_and_idempotency' {
    $deletedRoot = New-Directory 'deleted-old-root'
    [IO.Directory]::Delete($deletedRoot, $false)
    $path = Join-Path $testDirectory 'deleted-root.json'
    Write-Config $path @{ workspaceRoots = @($deletedRoot); routes = $fixture.routes }
    $first = Run-Helper $taskPath $path
    $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    Assert ($first.code -eq 0 -and $first.result.changed) 'Deleted root blocked the addition.'
    Assert ($actual.workspaceRoots.Count -eq 2 -and $actual.workspaceRoots[0] -ceq $deletedRoot -and $actual.workspaceRoots[1] -eq $taskPath) 'Deleted root was not preserved.'
    $before = Hash $path
    $second = Run-Helper $taskPath $path
    Assert ($second.code -eq 0 -and -not $second.result.changed -and (Hash $path) -eq $before) 'Deleted-root fixture was not idempotent.'
}
Test-Case 'drive_root_rejected' { Assert-FailureUnchanged ([IO.Path]::GetPathRoot($taskPath)) $configPath 'workspace_too_broad' }
Test-Case 'user_home_rejected' { Assert-FailureUnchanged ([Environment]::GetFolderPath('UserProfile')) $configPath 'workspace_too_broad' }
Test-Case 'home_junction_rejected' {
    $homeAlias = Join-Path $testDirectory 'home-alias'
    New-Item -ItemType Junction -Path $homeAlias -Target ([Environment]::GetFolderPath('UserProfile')) | Out-Null
    Assert-FailureUnchanged $homeAlias $configPath 'workspace_too_broad'
}
Test-Case 'relative_workspace_rejected' { Assert-FailureUnchanged 'task' $configPath 'workspace_invalid_or_unavailable' }
Test-Case 'wildcard_workspace_rejected' { Assert-FailureUnchanged (Join-Path $testDirectory 'task*') $configPath 'workspace_invalid_or_unavailable' }
Test-Case 'missing_workspace_rejected' { Assert-FailureUnchanged (Join-Path $testDirectory 'does-not-exist') $configPath 'workspace_invalid_or_unavailable' }
Test-Case 'file_workspace_rejected' { Assert-FailureUnchanged $configPath $configPath 'workspace_invalid_or_unavailable' }
Test-Case 'inaccessible_workspace_rejected_without_mutation' {
    $deniedPath = New-Directory 'denied'
    $originalAcl = Get-Acl -LiteralPath $deniedPath
    try {
        $testAcl = Get-Acl -LiteralPath $deniedPath
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::ListDirectory, [Security.AccessControl.AccessControlType]::Deny)
        $testAcl.AddAccessRule($rule)
        Set-Acl -LiteralPath $deniedPath -AclObject $testAcl
        Assert-FailureUnchanged $deniedPath $configPath 'workspace_invalid_or_unavailable'
    } finally { Set-Acl -LiteralPath $deniedPath -AclObject $originalAcl }
}
Test-Case 'inaccessible_existing_root_preserved_with_new_root_and_idempotency' {
    $deniedRoot = New-Directory 'denied-old-root'
    $path = Join-Path $testDirectory 'denied-root.json'
    Write-Config $path @{ workspaceRoots = @($deniedRoot); routes = $fixture.routes }
    $originalAcl = Get-Acl -LiteralPath $deniedRoot
    try {
        $testAcl = Get-Acl -LiteralPath $deniedRoot
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::ListDirectory, [Security.AccessControl.AccessControlType]::Deny)
        $testAcl.AddAccessRule($rule)
        Set-Acl -LiteralPath $deniedRoot -AclObject $testAcl
        $first = Run-Helper $taskPath $path
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        Assert ($first.code -eq 0 -and $first.result.changed) 'Inaccessible old root blocked the addition.'
        Assert ($actual.workspaceRoots.Count -eq 2 -and $actual.workspaceRoots[0] -ceq $deniedRoot -and $actual.workspaceRoots[1] -eq $taskPath) 'Inaccessible old root was not preserved.'
        $before = Hash $path
        $second = Run-Helper $taskPath $path
        Assert ($second.code -eq 0 -and -not $second.result.changed -and (Hash $path) -eq $before) 'Inaccessible-root fixture was not idempotent.'
    } finally { Set-Acl -LiteralPath $deniedRoot -AclObject $originalAcl }
}
Test-Case 'environment_override_selects_only_fixture_config' {
    $path = Join-Path $testDirectory 'override.json'
    Write-Config $path @{ workspaceRoots = @() }
    $response = Run-Helper $taskPath $path 'override'
    Assert ($response.code -eq 0 -and $response.result.config -eq $path -and $response.result.changed) 'Config override ignored.'
}
Test-Case 'default_appdata_selects_only_fixture_config' {
    $appdata = New-Directory 'appdata/MixAgents'
    $path = Join-Path $appdata 'broker.json'
    Write-Config $path @{ workspaceRoots = @() }
    $response = Run-Helper $taskPath $path 'default'
    Assert ($response.code -eq 0 -and $response.result.config -eq $path -and $response.result.changed) 'Default config path incorrect.'
}
Test-Case 'concurrent_helpers_preserve_both_additions' {
    $path = Join-Path $testDirectory 'concurrent.json'
    Write-Config $path @{ workspaceRoots = @(); routes = $fixture.routes }
    $first = Start-Helper $taskPath $path
    $second = Start-Helper $siblingPath $path
    $one = Finish-Helper $first
    $two = Finish-Helper $second
    $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    Assert ($one.code -eq 0 -and $two.code -eq 0 -and $actual.workspaceRoots.Count -eq 2) 'Concurrent additions were lost.'
    Assert ($actual.workspaceRoots -contains $taskPath -and $actual.workspaceRoots -contains $siblingPath) 'Concurrent roots incorrect.'
}

$failed = @($results | Where-Object { $_.status -ne 'passed' })
# The shareable report includes only names/statuses; never fixture or user paths.
$publicResults = @($results | ForEach-Object { [ordered]@{ name = $_.name; status = $_.status } })
$report = [ordered]@{ passed = $results.Count - $failed.Count; failed = $failed.Count; results = $publicResults }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'workspace-preflight-results.json') -Encoding utf8
$report | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0) { exit 1 }
} finally {
    # All fixture junctions are top-level: unlink them, never recursively delete a target.
    $resolvedFixture = [IO.Path]::GetFullPath($testDirectory)
    $allowedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if (-not [IO.Path]::GetDirectoryName($resolvedFixture).Equals($allowedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixture) -notmatch '^workspace-fixtures-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup target' }
    if ([IO.Directory]::Exists($resolvedFixture)) {
        foreach ($alias in @(Get-ChildItem -LiteralPath $resolvedFixture -Force -Directory | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
            [IO.Directory]::Delete($alias.FullName, $false)
        }
        $remainingLinks = @(Get-ChildItem -LiteralPath $resolvedFixture -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($remainingLinks.Count -ne 0) { throw 'Unexpected fixture reparse point; preserving fixture for inspection' }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
