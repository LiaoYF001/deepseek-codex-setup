#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skillPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\check-deepseek-models'
$module = Import-Module (Join-Path $skillPath 'scripts\DeepSeekModelTools.psm1') -Force -PassThru
$fixtureRoot = Join-Path $PSScriptRoot ('fixtures-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$fixturePath = Join-Path $fixtureRoot 'broker.json'
$priorOverride = $env:MIXAGENTS_BROKER_CONFIG
$env:MIXAGENTS_BROKER_CONFIG = $fixturePath
$script:count = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:count++
    "PASS: $Name"
}

# Mocks reside only inside this test process; no User environment access or network call.
& $module {
    $script:FakeSid = 'S-1-5-21-1-2-3-1001'
    $script:FakeBinding = @{ownerSid = $script:FakeSid}
    $script:FakeCredentials = '{"DEEPSEEK_API_KEY":"sk-unit-test-only-no-provider-secret"}'
    $script:FakeReply = @{Status = 200; Body = '{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}'}
    $script:RequestCount = 0
    $script:CredentialReads = 0
    $script:ThrowNetwork = $false
    function script:Get-CurrentWindowsSid { return $script:FakeSid }
    function script:Get-OwnerBinding { return $script:FakeBinding }
    function script:Get-UserCredentialMapValue { $script:CredentialReads++; return $script:FakeCredentials }
    function script:Send-FixedModelListRequest([string]$Secret) {
        $script:RequestCount++
        if ($script:ThrowNetwork) { throw "private raw error contains $Secret" }
        return $script:FakeReply
    }
}

$baseline = @'
{
  "defaultRoute": "deepseek-flash",
  "codexBin": "codex",
  "customSetting": {"nested": [1, 2]},
  "routes": {
    "deepseek-flash": {
      "provider": "deepseek", "model": "deepseek-flash",
      "baseUrl": "https://api.deepseek.com", "envKey": "DEEPSEEK_API_KEY",
      "contextWindow": 1000000, "maxAccess": "read-only", "tags": ["fast"]
    },
    "other": {"provider": "different", "model": "existing", "baseUrl": "https://example.invalid"}
  }
}
'@
$evidenceUrl = 'https://api-docs.deepseek.com/guides/responses_api'
function Reset-Config { [IO.File]::WriteAllText($fixturePath, $baseline, [Text.UTF8Encoding]::new($false)) }
function Update-Route {
    Set-DeepSeekRouteModel -Route 'deepseek-flash' -Model 'deepseek-v4-pro' -ExpectedModel 'deepseek-flash' -CompatibilityEvidenceUrl $evidenceUrl
}
try {
    Reset-Config
    $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePath))
    $r = Invoke-DeepSeekModelCheck
    Assert-True ($r.ok -and $r.models.Count -eq 2 -and $r.models[0] -ceq 'deepseek-flash') 'check returns account model IDs'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePath)) -ceq $beforeBytes) 'checking never changes config bytes'
    Assert-True (@(Get-ChildItem -LiteralPath $fixtureRoot).Count -eq 1) 'checking creates no config backup or side effects'

    # Synthetic Windows account SIDs only; no real account identity is read.
    & $module { $script:FakeSid = 'S-1-12-1-1-2-3-4'; $script:FakeBinding = @{ownerSid = $script:FakeSid} }
    Assert-True ((Invoke-DeepSeekModelCheck).ok) 'alternate Entra-style Windows SID accepted when exact identity matches'
    & $module { $script:FakeBinding = @{ownerSid = 'S-1-12-1-5-6-7-8'} }
    $readsBeforeAlternateMismatch = & $module { $script:CredentialReads }
    Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'OWNER_MISMATCH') 'alternate valid SID mismatch rejected'
    Assert-True ((& $module { $script:CredentialReads }) -eq $readsBeforeAlternateMismatch) 'alternate SID mismatch does not read credentials'
    foreach ($invalidSid in @('', ' ', 'S-1-5-21-99999999999999999999999-2-3-4', 'S-1-12-1-not-a-number')) {
        & $module { param($value) $script:FakeBinding = @{ownerSid = $value} } $invalidSid
        Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'OWNER_BINDING_INVALID') 'invalid Windows SID rejected by format validation'
    }
    & $module { $script:FakeSid = 'S-1-5-21-1-2-3-1001'; $script:FakeBinding = @{ownerSid = $script:FakeSid} }
    & $module { $script:FakeBinding = $null }
    $reads = & $module { $script:CredentialReads }
    $r = Invoke-DeepSeekModelCheck
    Assert-True ($r.error -ceq 'OWNER_BINDING_MISSING') 'missing owner binding fails closed'
    Assert-True ((& $module { $script:CredentialReads }) -eq $reads) 'owner failure does not read credentials'
    & $module { $script:FakeBinding = @{ownerSid = 'S-1-5-21-1-2-3-9999'} }
    Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'OWNER_MISMATCH') 'other Windows SID cannot retrieve credential'
    & $module { $script:FakeBinding = @{ownerSid = 'not-a-sid'} }
    Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'OWNER_BINDING_INVALID') 'invalid owner marker rejected'
    & $module { $script:FakeBinding = @{ownerSid = $script:FakeSid}; $script:FakeCredentials = $null }
    Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'CREDENTIALS_MISSING') 'missing credentials report fixed error'
    foreach ($invalid in @('not json', '[]', '{}', '{"DEEPSEEK_API_KEY":42}', '{"DEEPSEEK_API_KEY":"short"}', '{"DEEPSEEK_API_KEY":"contains spaces not allowed"}')) {
        & $module { param($value) $script:FakeCredentials = $value } $invalid
        Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'CREDENTIALS_INVALID') 'invalid credential map/key rejected'
    }
    & $module { $script:FakeCredentials = '{"DEEPSEEK_API_KEY":"sk-unit-test-only-no-provider-secret"}' }
    foreach ($pair in @(@(301,'REDIRECT_REJECTED'), @(302,'REDIRECT_REJECTED'), @(307,'REDIRECT_REJECTED'), @(401,'AUTHENTICATION_FAILED'), @(403,'AUTHENTICATION_FAILED'), @(429,'RATE_LIMITED'), @(500,'HTTP_ERROR'))) {
        & $module { param($status) $script:FakeReply = @{Status=$status; Body='raw private error'} } $pair[0]
        Assert-True ((Invoke-DeepSeekModelCheck).error -ceq $pair[1]) "HTTP $($pair[0]) sanitized/rejected"
    }
    & $module { $script:ThrowNetwork = $true }
    $r = Invoke-DeepSeekModelCheck
    Assert-True ($r.error -ceq 'NETWORK_ERROR' -and ($r | ConvertTo-Json) -notmatch 'sk-unit-test|private raw') 'network exceptions never expose raw errors or credentials'
    & $module { $script:ThrowNetwork = $false }
    foreach ($invalidBody in @('not json','{}','{"data":{}}','{"data":[{"id":"deepseek-flash\nprivate"}]}','{"data":[{"id":"https://malicious.invalid"}]}')) {
        & $module { param($body) $script:FakeReply = @{Status=200; Body=$body} } $invalidBody
        Assert-True ((Invoke-DeepSeekModelCheck).error -ceq 'RESPONSE_INVALID') 'malformed response/model ID rejected'
    }
    & $module { $script:FakeReply = @{Status=200; Body='{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}'} }

    $r = Update-Route
    Assert-True ($r.ok -and $r.changed) 'explicit model switch succeeds'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($r.backup)) -ceq $beforeBytes) 'backup preserves exact original bytes'
    $actual = [IO.File]::ReadAllText($fixturePath) | ConvertFrom-Json -AsHashtable
    $expected = $baseline | ConvertFrom-Json -AsHashtable
    $expected.routes['deepseek-flash'].model = 'deepseek-v4-pro'
    Assert-True (($actual | ConvertTo-Json -Depth 100 -Compress) -ceq ($expected | ConvertTo-Json -Depth 100 -Compress)) 'switch changes target model only, preserving all other routes/fields'
    Reset-Config
    $r = Set-DeepSeekRouteModel -Route 'deepseek-flash' -Model 'deepseek-v4-pro' -ExpectedModel 'deepseek-flash' -CompatibilityEvidenceUrl $evidenceUrl -ContextWindow 2000000
    Assert-True ($r.ok -and $r.contextChanged -and (([IO.File]::ReadAllText($fixturePath) | ConvertFrom-Json).routes.'deepseek-flash'.contextWindow -eq 2000000)) 'documented context change supported explicitly'
    Reset-Config
    $r = Set-DeepSeekRouteModel -Route 'deepseek-flash' -Model 'deepseek-not-available' -ExpectedModel 'deepseek-flash' -CompatibilityEvidenceUrl $evidenceUrl
    Assert-True ($r.error -ceq 'MODEL_NOT_AVAILABLE' -and [IO.File]::ReadAllText($fixturePath) -ceq $baseline) 'unavailable model leaves config unchanged'
    $r = Set-DeepSeekRouteModel -Route 'deepseek-flash' -Model 'deepseek-v4-pro' -ExpectedModel 'old-model' -CompatibilityEvidenceUrl $evidenceUrl
    Assert-True ($r.error -ceq 'CURRENT_MODEL_CHANGED') 'stale expected model is rejected'
    $r = Set-DeepSeekRouteModel -Route 'deepseek-flash' -Model 'deepseek-v4-pro' -ExpectedModel 'deepseek-flash' -CompatibilityEvidenceUrl 'https://api-docs.deepseek.com.evil.invalid/guides/responses_api'
    Assert-True ($r.error -ceq 'COMPATIBILITY_EVIDENCE_REQUIRED') 'nonofficial evidence URL rejected'
    $r = Set-DeepSeekRouteModel -Route 'other' -Model 'deepseek-v4-pro' -ExpectedModel 'existing' -CompatibilityEvidenceUrl $evidenceUrl
    Assert-True ($r.error -ceq 'ROUTE_NOT_OFFICIAL_DEEPSEEK') 'other providers cannot be changed'
    & $module { $script:FakeCredentials = $null }
    $r = Update-Route
    Assert-True ($r.error -ceq 'CREDENTIALS_MISSING' -and [IO.File]::ReadAllText($fixturePath) -ceq $baseline) 'authentication failure blocks mutation'
    & $module { $script:FakeCredentials = '{"DEEPSEEK_API_KEY":"sk-unit-test-only-no-provider-secret"}' }
    $env:MIXAGENTS_BROKER_CONFIG = 'relative\broker.json'
    Assert-True ((Update-Route).error -ceq 'CONFIG_INVALID') 'relative global config override rejected'
    $env:MIXAGENTS_BROKER_CONFIG = $fixturePath

    & $module {
        $script:ValidationCalls = 0
        function script:Test-WrittenConfig([string]$Path, [string]$ExpectedJson) {
            $script:ValidationCalls++
            return ($script:ValidationCalls -ne 2)
        }
    }
    $r = Update-Route
    Assert-True ($r.error -ceq 'UPDATE_ROLLED_BACK') 'failed postwrite validation triggers rollback'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePath)) -ceq $beforeBytes) 'rollback restores exact original bytes'
    Assert-True (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.tmp.*').Count -eq 0) 'temporary files cleaned after rollback'

    & $module {
        $script:ValidationCalls = 0
        function script:Test-WrittenConfig([string]$Path, [string]$ExpectedJson) {
            $script:ValidationCalls++
            if ($script:ValidationCalls -eq 2) {
                [IO.File]::WriteAllText($Path, '{"changedExternally":true}', [Text.UTF8Encoding]::new($false))
                return $false
            }
            return $true
        }
    }
    $r = Update-Route
    Assert-True ($r.error -ceq 'CONFIG_CONFLICT_AFTER_WRITE') 'external edit during postwrite validation reports conflict'
    Assert-True ([IO.File]::ReadAllText($fixturePath) -ceq '{"changedExternally":true}') 'rollback never overwrites detected external edit'
    Assert-True (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.tmp.*').Count -eq 0) 'temporary files cleaned after external conflict'

    Reset-Config
    $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($fixturePath).ToUpperInvariant())))
    $lockName = "Global\MixAgents.DeepSeekModel.$lockKey"
    $childCode = '$m = [Threading.Mutex]::new($true, ''' + $lockName + '''); [Console]::Out.WriteLine(''LOCK_READY''); [void][Console]::In.ReadLine(); $m.ReleaseMutex(); $m.Dispose()'
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-EncodedCommand')
    $psi.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode)))
    $child = [Diagnostics.Process]::Start($psi)
    try {
        Assert-True ($child.StandardOutput.ReadLine() -ceq 'LOCK_READY') 'second process acquired fixture config lock'
        $requestsBeforeLock = & $module { $script:RequestCount }
        $r = Update-Route
        Assert-True ($r.error -ceq 'CONFIG_BUSY') 'concurrent helper cannot enter active config transaction'
        Assert-True ((& $module { $script:RequestCount }) -eq $requestsBeforeLock) 'lock conflict stops before credentials/network query'
        Assert-True ([IO.File]::ReadAllText($fixturePath) -ceq $baseline) 'lock conflict preserves original config'
    } finally {
        $child.StandardInput.WriteLine('release')
        if (-not $child.WaitForExit(5000)) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
    }

    "TOTAL: $script:count assertions passed; no real credentials or provider requests used."
} finally {
    $env:MIXAGENTS_BROKER_CONFIG = $priorOverride
    Remove-Module $module.Name -Force
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $allowedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup target' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
