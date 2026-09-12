#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Failure([string]$Code) { return @{ ok = $false; error = $Code } }

function Get-CurrentWindowsSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-OwnerBinding {
    $path = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MixAgents\credential-owner.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    return ([IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
}

function Get-UserCredentialMapValue {
    return [Environment]::GetEnvironmentVariable('MIXAGENTS_BROKER_CREDENTIALS_JSON', 'User')
}

function Send-FixedModelListRequest([string]$Secret) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    $client.MaxResponseContentBufferSize = 1048576
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.deepseek.com/models')
    $response = $null
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Secret)
        $request.Headers.Accept.ParseAdd('application/json')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        return @{ Status = [int]$response.StatusCode; Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

function Invoke-DeepSeekModelCheck {
    [CmdletBinding()]
    param()
    try {
        $binding = Get-OwnerBinding
        if ($null -eq $binding) { return (New-Failure 'OWNER_BINDING_MISSING') }
        if ($binding -isnot [System.Collections.IDictionary] -or
            -not $binding.Contains('ownerSid') -or $binding.ownerSid -isnot [string] -or
            [string]::IsNullOrWhiteSpace($binding.ownerSid)) {
            return (New-Failure 'OWNER_BINDING_INVALID')
        }
        # Windows supports multiple account SID forms, including local/domain and Entra IDs.
        $parsedOwnerSid = [Security.Principal.SecurityIdentifier]::new($binding.ownerSid)
        if ($parsedOwnerSid.Value -cne $binding.ownerSid) { return (New-Failure 'OWNER_BINDING_INVALID') }
        if ((Get-CurrentWindowsSid) -cne $binding.ownerSid) { return (New-Failure 'OWNER_MISMATCH') }
    } catch { return (New-Failure 'OWNER_BINDING_INVALID') }

    $raw = $null
    $secret = $null
    $credentials = $null
    try {
        $raw = Get-UserCredentialMapValue
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-Failure 'CREDENTIALS_MISSING') }
        $credentials = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($credentials -isnot [System.Collections.IDictionary] -or -not $credentials.Contains('DEEPSEEK_API_KEY')) {
            return (New-Failure 'CREDENTIALS_INVALID')
        }
        $secret = $credentials.DEEPSEEK_API_KEY
        if ($secret -isnot [string] -or $secret.Length -lt 16 -or $secret.Length -gt 1024 -or $secret -notmatch '^[\x21-\x7E]+$') {
            return (New-Failure 'CREDENTIALS_INVALID')
        }
    } catch { return (New-Failure 'CREDENTIALS_INVALID') }
    try {
        $reply = Send-FixedModelListRequest -Secret $secret
    } catch { return (New-Failure 'NETWORK_ERROR') }
    finally { $raw = $null; $secret = $null; $credentials = $null }

    if ($reply.Status -ge 300 -and $reply.Status -lt 400) { return (New-Failure 'REDIRECT_REJECTED') }
    if ($reply.Status -in 401, 403) { return (New-Failure 'AUTHENTICATION_FAILED') }
    if ($reply.Status -eq 429) { return (New-Failure 'RATE_LIMITED') }
    if ($reply.Status -ne 200) { return (New-Failure 'HTTP_ERROR') }
    try {
        if ($reply.Body -isnot [string] -or $reply.Body.Length -gt 1048576) { return (New-Failure 'RESPONSE_INVALID') }
        $payload = $reply.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($payload -isnot [System.Collections.IDictionary] -or -not $payload.Contains('data') -or $payload.data -isnot [array]) {
            return (New-Failure 'RESPONSE_INVALID')
        }
        $ids = [Collections.Generic.List[string]]::new()
        foreach ($entry in $payload.data) {
            if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('id') -or
                $entry.id -isnot [string] -or $entry.id -cnotmatch '^deepseek-[a-z0-9][a-z0-9._-]{0,95}$') {
                return (New-Failure 'RESPONSE_INVALID')
            }
            if (-not $ids.Contains($entry.id)) { $ids.Add($entry.id) }
        }
        return @{ ok = $true; models = @($ids.ToArray()) }
    } catch { return (New-Failure 'RESPONSE_INVALID') }
}

function Get-BrokerConfigPath {
    $override = [Environment]::GetEnvironmentVariable('MIXAGENTS_BROKER_CONFIG', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (-not [IO.Path]::IsPathFullyQualified($override)) { throw 'CONFIG_PATH_INVALID' }
        return [IO.Path]::GetFullPath($override)
    }
    return Join-Path $env:APPDATA 'MixAgents\broker.json'
}

function Test-WrittenConfig([string]$Path, [string]$ExpectedJson) {
    $actual = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    return (($actual | ConvertTo-Json -Depth 100 -Compress) -ceq $ExpectedJson)
}

function Set-DeepSeekRouteModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Route,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$ExpectedModel,
        [Parameter(Mandatory)][string]$CompatibilityEvidenceUrl,
        [long]$ContextWindow
    )
    if ($Model -cnotmatch '^deepseek-[a-z0-9][a-z0-9._-]{0,95}$' -or [string]::IsNullOrWhiteSpace($Route)) {
        return (New-Failure 'INVALID_ARGUMENTS')
    }
    try {
        $evidence = [uri]$CompatibilityEvidenceUrl
        if (-not $evidence.IsAbsoluteUri -or $evidence.Scheme -cne 'https' -or
            $evidence.DnsSafeHost -cne 'api-docs.deepseek.com' -or -not $evidence.IsDefaultPort -or
            $evidence.UserInfo -ne '' -or $evidence.AbsolutePath -notmatch '^/(zh-cn/)?(guides|api|quick_start|news)/') {
            return (New-Failure 'COMPATIBILITY_EVIDENCE_REQUIRED')
        }
    } catch { return (New-Failure 'COMPATIBILITY_EVIDENCE_REQUIRED') }
    if ($PSBoundParameters.ContainsKey('ContextWindow') -and ($ContextWindow -lt 1 -or $ContextWindow -gt 100000000)) {
        return (New-Failure 'CONTEXT_WINDOW_INVALID')
    }
    try { $path = Get-BrokerConfigPath } catch { return (New-Failure 'CONFIG_INVALID') }
    $configLock = $null
    $lockHeld = $false
    try {
    try {
        $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($path).ToUpperInvariant())))
        $configLock = [Threading.Mutex]::new($false, "Global\MixAgents.DeepSeekModel.$lockKey")
        try { $lockHeld = $configLock.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        if (-not $lockHeld) { return (New-Failure 'CONFIG_BUSY') }
    } catch { return (New-Failure 'CONFIG_LOCK_FAILED') }
    try {
        if (-not [IO.File]::Exists($path)) { return (New-Failure 'CONFIG_MISSING') }
        $originalBytes = [IO.File]::ReadAllBytes($path)
        $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
        $config = [Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($config -isnot [System.Collections.IDictionary] -or -not $config.Contains('routes') -or
            $config.routes -isnot [System.Collections.IDictionary] -or -not $config.routes.Contains($Route)) {
            return (New-Failure 'ROUTE_MISSING')
        }
        $target = $config.routes[$Route]
        if ($target -isnot [System.Collections.IDictionary] -or -not $target.Contains('model') -or
            -not $target.Contains('baseUrl') -or $target.baseUrl -notin 'https://api.deepseek.com', 'https://api.deepseek.com/') {
            return (New-Failure 'ROUTE_NOT_OFFICIAL_DEEPSEEK')
        }
        if ($target.model -cne $ExpectedModel) { return (New-Failure 'CURRENT_MODEL_CHANGED') }
    } catch { return (New-Failure 'CONFIG_INVALID') }

    $available = Invoke-DeepSeekModelCheck
    if (-not $available.ok) { return $available }
    if ($Model -cnotin $available.models) { return (New-Failure 'MODEL_NOT_AVAILABLE') }
    $contextChanged = $PSBoundParameters.ContainsKey('ContextWindow') -and
        (-not $target.Contains('contextWindow') -or $target.contextWindow -ne $ContextWindow)
    if ($target.model -ceq $Model -and -not $contextChanged) {
        return @{ ok = $true; changed = $false; route = $Route; model = $Model }
    }
    $target.model = $Model
    if ($contextChanged) { $target.contextWindow = $ContextWindow }
    $desired = $config | ConvertTo-Json -Depth 100 -Compress
    $temp = "$path.tmp.$([guid]::NewGuid().ToString('N'))"
    $backup = "$path.bak.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).$([guid]::NewGuid().ToString('N'))"
    $replaced = $false
    try {
        [IO.File]::WriteAllText($temp, ($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        if (-not (Test-WrittenConfig -Path $temp -ExpectedJson $desired)) { return (New-Failure 'PREWRITE_VALIDATION_FAILED') }
        $writtenHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($temp)))
        $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path)))
        if ($currentHash -cne $originalHash) { return (New-Failure 'CONFIG_CHANGED') }
        [IO.File]::Replace($temp, $path, $backup)
        $replaced = $true
        if (-not (Test-WrittenConfig -Path $path -ExpectedJson $desired)) { throw 'POSTWRITE_VALIDATION_FAILED' }
        return @{ ok = $true; changed = $true; route = $Route; previousModel = $ExpectedModel; model = $Model; contextChanged = [bool]$contextChanged; backup = $backup }
    } catch {
        if ($replaced) {
            try {
                [IO.File]::WriteAllBytes($temp, $originalBytes)
                if (-not [IO.File]::Exists($path)) { return (New-Failure 'CONFIG_CONFLICT_AFTER_WRITE') }
                $rollbackCurrentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path)))
                if ($rollbackCurrentHash -cne $writtenHash) { return (New-Failure 'CONFIG_CONFLICT_AFTER_WRITE') }
                [IO.File]::Replace($temp, $path, [NullString]::Value)
                if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path))) -cne $originalHash) {
                    return (New-Failure 'ROLLBACK_FAILED')
                }
                return (New-Failure 'UPDATE_ROLLED_BACK')
            } catch { return (New-Failure 'ROLLBACK_FAILED') }
        }
        return (New-Failure 'UPDATE_FAILED')
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
    } finally {
        if ($lockHeld) { $configLock.ReleaseMutex() }
        if ($null -ne $configLock) { $configLock.Dispose() }
    }
}

Export-ModuleMember -Function Invoke-DeepSeekModelCheck, Set-DeepSeekRouteModel
