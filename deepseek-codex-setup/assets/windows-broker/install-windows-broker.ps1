#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $InstallDirectory,
    [string] $BrokerConfigPath,
    [string] $CodexExecutable,
    [string] $NodeExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failureCode = 'installation_failed'
$mutex = $null
$lockHeld = $false
$document = $null
$temporaryFiles = [Collections.Generic.List[string]]::new()

function Absolute-Path([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\x00-\x1F*?<>|"\[\]]' -or
        $Value -match '^\\\\[?.]\\' -or -not [IO.Path]::IsPathFullyQualified($Value)) { throw 'invalid_path' }
    $fullPath = [IO.Path]::GetFullPath($Value)
    if ($fullPath.Substring(2).Contains(':')) { throw 'invalid_path' }
    return $fullPath
}
function Executable-Path([string] $Value) {
    $fullPath = Absolute-Path $Value
    if ([IO.Path]::GetExtension($fullPath) -ine '.exe' -or -not [IO.File]::Exists($fullPath)) { throw 'executable_required' }
    return $fullPath
}
function Discover-Executable([string] $Name, [string] $NodePath) {
    $command = Get-Command ($Name + '.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return (Executable-Path $command.Source) }
    if ($Name -eq 'codex') {
        $discoveryRoots = [Collections.Generic.List[string]]::new()
        $managedRoot = [Environment]::GetEnvironmentVariable('CODEX_MANAGED_PACKAGE_ROOT')
        if (-not [string]::IsNullOrWhiteSpace($managedRoot)) { $discoveryRoots.Add((Absolute-Path $managedRoot)) }
        foreach ($shimName in @('codex.cmd', 'codex.bat')) {
            $shim = Get-Command $shimName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $shim) {
                # Infer the standard npm global layout without executing the shim.
                $discoveryRoots.Add((Join-Path ([IO.Path]::GetDirectoryName($shim.Source)) 'node_modules/@openai/codex'))
            }
        }
        foreach ($packageRoot in $discoveryRoots) {
            $packageRoots = [Collections.Generic.List[string]]::new()
            $packageRoots.Add($packageRoot)
            # Resolve an installed npm platform package using Node's own resolver;
            # only package metadata is read, never provider configuration.
            $resolver = 'const p=require("node:path");const r=require("node:module").createRequire(p.join(process.argv[1],"package.json"));try{process.stdout.write(p.dirname(r.resolve("@openai/codex-win32-"+(process.arch==="arm64"?"arm64":"x64")+"/package.json")))}catch{}'
            $info = [Diagnostics.ProcessStartInfo]::new($NodePath)
            $info.UseShellExecute = $false; $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            foreach ($argument in @('-e', $resolver, $packageRoot)) { $info.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::Start($info)
            try {
                $resolved = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'resolver_timeout' }
                $resolvedRoot = $resolved.GetAwaiter().GetResult(); $null = $errors.GetAwaiter().GetResult()
                if ($process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedRoot)) { $packageRoots.Add((Absolute-Path $resolvedRoot)) }
            } finally { $process.Dispose() }
            $relativePaths = @('codex.exe', 'bin/codex.exe')
            if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq 'Arm64') {
                $relativePaths += @('vendor/aarch64-pc-windows-msvc/bin/codex.exe', 'vendor/aarch64-pc-windows-msvc/codex/codex.exe')
            }
            $relativePaths += @('vendor/x86_64-pc-windows-msvc/bin/codex.exe', 'vendor/x86_64-pc-windows-msvc/codex/codex.exe')
            foreach ($resolvedPackageRoot in $packageRoots) {
                foreach ($relative in $relativePaths) {
                    $candidate = Join-Path $resolvedPackageRoot $relative
                    if ([IO.File]::Exists($candidate)) { return (Executable-Path $candidate) }
                }
            }
        }
    }
    throw 'executable_unavailable'
}
function Assert-Version([string] $Executable, [string] $Kind) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.ArgumentList.Add('--version')
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'version_timeout' }
        $versionText = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        $nodeVersion = [regex]::Match($versionText, '^v(\d+)\.')
        if ($process.ExitCode -ne 0 -or
            ($Kind -eq 'node' -and -not $nodeVersion.Success) -or
            ($Kind -eq 'codex' -and $versionText -notmatch '^codex(?:-cli)?\s')) { throw 'invalid_executable' }
        if ($Kind -eq 'node' -and [int]$nodeVersion.Groups[1].Value -lt 18) { throw 'node_18_required' }
    } finally { $process.Dispose() }
}
function Bytes-Hash([byte[]] $Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}
function Assert-Unchanged([string] $Path, [byte[]] $Before) {
    if ($null -eq $Before) {
        if ([IO.File]::Exists($Path)) { throw 'concurrent_change' }
    } elseif (-not [IO.File]::Exists($Path) -or (Bytes-Hash ([IO.File]::ReadAllBytes($Path))) -cne (Bytes-Hash $Before)) {
        throw 'concurrent_change'
    }
}
function Write-Atomic([string] $Path, [byte[]] $Bytes, [byte[]] $Before) {
    Assert-Unchanged $Path $Before
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.install-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $temporaryFiles.Add($temp)
    $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    Assert-Unchanged $Path $Before
    if ($null -eq $Before) { [IO.File]::Move($temp, $Path) }
    else { [IO.File]::Replace($temp, $Path, [NullString]::Value, $false) }
}

try {
    if (-not $IsWindows) { $failureCode = 'windows_required'; throw 'unsupported' }
    $failureCode = 'invalid_install_directory'
    if (-not $PSBoundParameters.ContainsKey('InstallDirectory')) {
        $codexHomePath = [Environment]::GetEnvironmentVariable('CODEX_HOME')
        if ([string]::IsNullOrWhiteSpace($codexHomePath)) { $codexHomePath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
        $InstallDirectory = Join-Path (Absolute-Path $codexHomePath) 'tools/mixagents-windows'
    }
    $installation = (Absolute-Path $InstallDirectory).TrimEnd('\', '/')
    if ($installation -match '[%!^&()]' -or $installation -eq [IO.Path]::GetPathRoot($installation).TrimEnd('\')) { throw 'batch_unsafe_path' }
    $sourcePath = Join-Path $PSScriptRoot 'launch-broker-codex.mjs'
    if (-not [IO.File]::Exists($sourcePath)) { $failureCode = 'launcher_asset_missing'; throw 'missing_asset' }
    $launcherBytes = [IO.File]::ReadAllBytes($sourcePath)

    $failureCode = 'config_invalid_or_unavailable'
    if (-not $PSBoundParameters.ContainsKey('BrokerConfigPath')) {
        $BrokerConfigPath = [Environment]::GetEnvironmentVariable('MIXAGENTS_BROKER_CONFIG')
        if ([string]::IsNullOrWhiteSpace($BrokerConfigPath)) { $BrokerConfigPath = Join-Path ([Environment]::GetEnvironmentVariable('APPDATA')) 'MixAgents/broker.json' }
    }
    $config = Absolute-Path $BrokerConfigPath
    if (-not [IO.File]::Exists($config) -or ([IO.File]::GetAttributes($config) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'regular_config_required' }

    $failureCode = 'node_invalid_or_unavailable'
    $node = if ($PSBoundParameters.ContainsKey('NodeExecutable')) { Executable-Path $NodeExecutable } else { Discover-Executable 'node' }
    if ($node -match '[%!^&()]' -or $node -match '[^\x20-\x7E]') { throw 'batch_unsafe_path' }
    Assert-Version $node 'node'
    $failureCode = 'codex_invalid_or_unavailable'
    $codex = if ($PSBoundParameters.ContainsKey('CodexExecutable')) { Executable-Path $CodexExecutable } else { Discover-Executable 'codex' $node }
    Assert-Version $codex 'codex'

    $failureCode = 'config_busy'
    $lockHash = Bytes-Hash ([Text.Encoding]::UTF8.GetBytes($config.ToUpperInvariant()))
    $mutex = [Threading.Mutex]::new($false, ('Local\Codex.MixAgents.WindowsInstaller.' + $lockHash))
    try { $lockHeld = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'lock_timeout' }

    $failureCode = 'config_invalid_json'
    $originalConfig = [IO.File]::ReadAllBytes($config)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $document = [System.Text.Json.JsonDocument]::Parse($utf8.GetString($originalConfig).TrimStart([char]0xFEFF))
    $failureCode = 'config_invalid_structure'
    if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'object_required' }
    $commandPath = Join-Path $installation 'broker-codex.cmd'
    $launcherPath = Join-Path $installation 'launch-broker-codex.mjs'
    $settingsPath = Join-Path $installation 'settings.json'
    $foundCodexBin = $false
    $configChanged = $true
    foreach ($property in $document.RootElement.EnumerateObject()) {
        if ($property.Name -ceq 'codexBin') {
            if ($foundCodexBin) { throw 'duplicate_codex_bin' }
            $foundCodexBin = $true
            if ($property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                $configChanged = $property.Value.GetString() -cne $commandPath
            }
        }
    }
    $updatedConfig = $originalConfig
    if ($configChanged) {
        $memory = [IO.MemoryStream]::new()
        $options = [System.Text.Json.JsonWriterOptions]::new(); $options.Indented = $true
        $writer = [System.Text.Json.Utf8JsonWriter]::new($memory, $options)
        try {
            $writer.WriteStartObject()
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if ($property.Name -cne 'codexBin') { $property.WriteTo($writer) }
            }
            $writer.WriteString('codexBin', $commandPath)
            $writer.WriteEndObject(); $writer.Flush()
            $updatedConfig = $memory.ToArray()
        } finally { $writer.Dispose(); $memory.Dispose() }
    }
    # The wrapper stays ASCII. %~dp0 supports a Unicode installation directory
    # without depending on cmd.exe's active code page.
    $commandText = "@echo off`r`nsetlocal DisableDelayedExpansion`r`n" + '"' + $node + '" "%~dp0launch-broker-codex.mjs" %*' + "`r`nexit /b %errorlevel%`r`n"
    $settingsText = [ordered]@{ schemaVersion = 1; codexExecutable = $codex } | ConvertTo-Json -Compress
    $targets = @(
        @{ path = $launcherPath; name = 'launch-broker-codex.mjs'; bytes = $launcherBytes },
        @{ path = $settingsPath; name = 'settings.json'; bytes = $utf8.GetBytes($settingsText) },
        @{ path = $commandPath; name = 'broker-codex.cmd'; bytes = $utf8.GetBytes($commandText) }
    )
    $failureCode = 'installed_file_invalid'
    foreach ($target in $targets) {
        $target.before = $null
        if ([IO.File]::Exists($target.path)) {
            if (([IO.File]::GetAttributes($target.path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'regular_file_required' }
            $target.before = [IO.File]::ReadAllBytes($target.path)
        }
        $target.changed = $null -eq $target.before -or (Bytes-Hash $target.before) -cne (Bytes-Hash $target.bytes)
    }
    $changedTargets = @($targets | Where-Object { $_.changed })
    $backupDirectory = $null
    if ($configChanged -or $changedTargets.Count -gt 0) {
        $failureCode = 'backup_failed'
        [IO.Directory]::CreateDirectory($installation) | Out-Null
        $backupDirectory = Join-Path $installation ('backups/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $backupDirectory 'broker.json'), $originalConfig)
        foreach ($target in $targets) {
            if ($null -ne $target.before) { [IO.File]::WriteAllBytes((Join-Path $backupDirectory $target.name), $target.before) }
        }
        $failureCode = 'concurrent_change_or_write_failed'
        Assert-Unchanged $config $originalConfig
        foreach ($target in $changedTargets) { Write-Atomic $target.path $target.bytes $target.before }
        if ($configChanged) { Write-Atomic $config $updatedConfig $originalConfig }
    }
    [ordered]@{
        changed = ($configChanged -or $changedTargets.Count -gt 0)
        codexBin = $commandPath
        config = $config
        configChanged = $configChanged
        changedFiles = @($changedTargets | ForEach-Object { $_.name })
        backupDirectory = $backupDirectory
        reconnectRequired = ($configChanged -or $changedTargets.Count -gt 0)
    } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
} catch {
    [ordered]@{ error = $failureCode } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($null -ne $document) { $document.Dispose() }
    foreach ($temp in $temporaryFiles) {
        if ([IO.File]::Exists($temp)) { try { [IO.File]::Delete($temp) } catch { } }
    }
    if ($lockHeld) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
