#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($args.Count -ne 0) {
    '{"ok":false,"error":"INVALID_ARGUMENTS"}'
    exit 1
}
try {
    Import-Module (Join-Path $PSScriptRoot 'DeepSeekModelTools.psm1') -Force -ErrorAction Stop
    $result = Invoke-DeepSeekModelCheck
    $result | ConvertTo-Json -Depth 4 -Compress
    if (-not $result.ok) { exit 1 }
} catch {
    '{"ok":false,"error":"CHECK_FAILED"}'
    exit 1
}
