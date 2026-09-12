#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Route,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][string]$ExpectedModel,
    [Parameter(Mandatory)][string]$CompatibilityEvidenceUrl,
    [long]$ContextWindow
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'DeepSeekModelTools.psm1') -Force -ErrorAction Stop
    $result = Set-DeepSeekRouteModel @PSBoundParameters
    $result | ConvertTo-Json -Depth 4 -Compress
    if (-not $result.ok) { exit 1 }
} catch {
    '{"ok":false,"error":"UPDATE_FAILED"}'
    exit 1
}
