#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $WorkspacePath,
    [string] $ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failureCode = 'preflight_failed'
$mutex = $null
$lockHeld = $false
$document = $null
$temporaryPath = $null

function Get-AbsoluteLiteralPath([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value.IndexOfAny([char[]]'*?[]<>|"') -ge 0 -or
        $Value -match '[\x00-\x1F]' -or
        $Value.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $Value -match '^\\\\[?.]\\' -or
        -not [System.IO.Path]::IsPathFullyQualified($Value)) { throw 'invalid_path' }
    $fullPath = [System.IO.Path]::GetFullPath($Value)
    # Reject alternate data streams and Windows device paths.
    if ($fullPath.Substring(2).Contains(':')) { throw 'invalid_path' }
    return $fullPath
}

function Test-Covered([string] $Candidate, [string] $Root) {
    $trimmedRoot = $Root.TrimEnd('\', '/')
    return $Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.Equals($trimmedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith($trimmedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

try {
    if (-not $IsWindows) { $failureCode = 'windows_required'; throw 'unsupported' }
    # Open directories with LIST_DIRECTORY access; resolve every junction/symlink
    # component using the opened handle without enumerating directory contents.
    if (-not ('DeepSeekWorkspacePreflight.NativePaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace DeepSeekWorkspacePreflight {
    public static class NativePaths {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access,
            uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
            StringBuilder path, uint length, uint flags);
        public static string DirectoryPath(string path) {
            if ((File.GetAttributes(path) & FileAttributes.Directory) == 0)
                throw new IOException("directory_required");
            using (var handle = CreateFileW(path, 1, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new IOException("directory_unavailable");
                var buffer = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity)
                    throw new IOException("canonical_path_unavailable");
                string result = buffer.ToString();
                if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                    result = @"\\" + result.Substring(8);
                else if (result.StartsWith(@"\\?\", StringComparison.Ordinal)) result = result.Substring(4);
                if (!Path.IsPathFullyQualified(result)) throw new IOException("canonical_path_unavailable");
                return result.Length > Path.GetPathRoot(result).Length ? result.TrimEnd('\\') : result;
            }
        }
    }
}
'@ | Out-Null
    }

    $failureCode = 'workspace_invalid_or_unavailable'
    $workspace = [DeepSeekWorkspacePreflight.NativePaths]::DirectoryPath((Get-AbsoluteLiteralPath $WorkspacePath))
    $failureCode = 'workspace_too_broad'
    $profilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $canonicalProfile = [DeepSeekWorkspacePreflight.NativePaths]::DirectoryPath($profilePath)
    if ($workspace.TrimEnd('\').Equals([IO.Path]::GetPathRoot($workspace).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Covered $canonicalProfile $workspace)) { throw 'broad_workspace' }

    $failureCode = 'config_invalid_or_unavailable'
    if (-not $PSBoundParameters.ContainsKey('ConfigPath')) {
        $selectedConfig = [Environment]::GetEnvironmentVariable('MIXAGENTS_BROKER_CONFIG')
        if ($null -eq $selectedConfig) {
            $appDataPath = [Environment]::GetEnvironmentVariable('APPDATA')
            if ([string]::IsNullOrWhiteSpace($appDataPath)) { throw 'missing_appdata' }
            $selectedConfig = Join-Path $appDataPath 'MixAgents/broker.json'
        }
    } else { $selectedConfig = $ConfigPath }
    $config = Get-AbsoluteLiteralPath $selectedConfig
    $attributes = [IO.File]::GetAttributes($config)
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'regular_config_file_required' }
    $configDirectory = [DeepSeekWorkspacePreflight.NativePaths]::DirectoryPath([IO.Path]::GetDirectoryName($config))
    $config = Join-Path $configDirectory ([IO.Path]::GetFileName($config))

    $failureCode = 'config_busy'
    $lockHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($config.ToUpperInvariant())))
    $mutex = [Threading.Mutex]::new($false, ('Local\Codex.DeepSeek.Workspace.' + $lockHash))
    try { $lockHeld = $mutex.WaitOne(10000) }
    catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'lock_timeout' }

    $failureCode = 'config_invalid_or_unavailable'
    $originalBytes = [IO.File]::ReadAllBytes($config)
    $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
    $failureCode = 'config_invalid_json'
    # Strict UTF-8 decoding, with optional UTF-8 BOM; never emit the config text.
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $jsonText = $encoding.GetString($originalBytes).TrimStart([char]0xFEFF)
    $document = [System.Text.Json.JsonDocument]::Parse($jsonText)
    $failureCode = 'config_invalid_structure'
    if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'object_required' }
    $existingRoots = [Collections.Generic.List[string]]::new()
    $foundRoots = $false
    foreach ($property in $document.RootElement.EnumerateObject()) {
        if ($property.Name -ceq 'workspaceRoots') {
            if ($foundRoots) { throw 'duplicate_roots' }
            $foundRoots = $true
            if ($property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Null) { continue }
            if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'array_required' }
            foreach ($entry in $property.Value.EnumerateArray()) {
                if ($entry.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'string_required' }
                $existingRoots.Add($entry.GetString())
            }
        }
    }

    $alreadyCovered = $false
    $failureCode = 'existing_root_invalid'
    foreach ($root in $existingRoots) {
        # Invalid syntax is a configuration error; stale or inaccessible directories
        # remain untouched, but cannot establish coverage for the requested path.
        $literalRoot = Get-AbsoluteLiteralPath $root
        try { $canonicalRoot = [DeepSeekWorkspacePreflight.NativePaths]::DirectoryPath($literalRoot) }
        catch { continue }
        if (Test-Covered $workspace $canonicalRoot) { $alreadyCovered = $true }
    }
    $backup = $null
    if (-not $alreadyCovered) {
        $failureCode = 'config_write_failed'
        $stream = [IO.MemoryStream]::new()
        $writerOptions = [System.Text.Json.JsonWriterOptions]::new()
        $writerOptions.Indented = $true
        $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $writerOptions)
        try {
            $writer.WriteStartObject()
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if ($property.Name -cne 'workspaceRoots') { $property.WriteTo($writer) }
            }
            $writer.WriteStartArray('workspaceRoots')
            foreach ($root in $existingRoots) { $writer.WriteStringValue($root) }
            $writer.WriteStringValue($workspace)
            $writer.WriteEndArray()
            $writer.WriteEndObject()
            $writer.Flush()
            $updatedBytes = $stream.ToArray()
        } finally { $writer.Dispose(); $stream.Dispose() }

        $suffix = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.' + [Guid]::NewGuid().ToString('N')
        $temporaryPath = Join-Path $configDirectory ('.' + [IO.Path]::GetFileName($config) + '.' + $suffix + '.tmp')
        $backup = Join-Path $configDirectory ([IO.Path]::GetFileName($config) + '.workspace-' + $suffix + '.bak')
        $fileStream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $fileStream.Write($updatedBytes, 0, $updatedBytes.Length); $fileStream.Flush($true) }
        finally { $fileStream.Dispose() }

        $failureCode = 'config_changed_concurrently'
        $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($config)))
        if ($currentHash -cne $originalHash) { throw 'concurrent_change' }
        $failureCode = 'config_write_failed'
        # Same-volume ReplaceFile gives an atomic replacement and original-byte backup.
        [IO.File]::Replace($temporaryPath, $config, $backup, $false)
        $temporaryPath = $null
    }

    [ordered]@{ changed = (-not $alreadyCovered); root = $workspace; config = $config; backup = $backup; reconnectRequired = (-not $alreadyCovered) } | ConvertTo-Json -Compress
} catch {
    # Fixed errors only: exception messages may contain configuration or secret data.
    [ordered]@{ error = $failureCode } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($null -ne $document) { $document.Dispose() }
    if ($null -ne $temporaryPath -and [IO.File]::Exists($temporaryPath)) {
        try { [IO.File]::Delete($temporaryPath) } catch { }
    }
    if ($lockHeld -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
