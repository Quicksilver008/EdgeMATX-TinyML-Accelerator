Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$shimScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $shimScriptDir)
$target = Join-Path $repoRoot "accel_standalone\scripts\run_midsem_sim.ps1"

if (-not (Test-Path $target)) {
    throw "Target script not found: $target"
}

Write-Host "DEPRECATED: 'midsem_sim' is now 'accel_standalone'."
Write-Host "Forwarding to: $target"

& powershell -ExecutionPolicy Bypass -File $target @args
exit $LASTEXITCODE
