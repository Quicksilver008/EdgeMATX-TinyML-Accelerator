#!/usr/bin/env pwsh
# run_riscv_handoff_check.ps1
#
# One-command gate for the full RISC-V subsystem:
#   1. Accelerator standalone regression  (tb_matrix_accel_4x4  — 19 cases)
#   2. Pipeline integration gate          (4 TBs via run_pipeline_tests.ps1)
#
# Usage (from workspace root):
#   .\RISC-V\run_riscv_handoff_check.ps1
#
# All tests must pass for exit code 0.

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Split-Path -Parent $Root)   # workspace root

$pass = 0
$fail = 0

function Run-Step {
    param([string]$Label, [string]$ScriptFile, [string]$PassPattern)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  $Label"
    Write-Host "============================================================"

    $out = pwsh -ExecutionPolicy Bypass -File $ScriptFile 2>&1
    $exitCode = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }

    $found = $out | Select-String -SimpleMatch $PassPattern
    if ($exitCode -eq 0 -and $found) {
        Write-Host "  => PASS"
        return $true
    } else {
        Write-Host "  => FAIL (exit=$exitCode, pattern='$PassPattern' $(if ($found) {'found'} else {'NOT found'}))"
        return $false
    }
}

# ─── Step 1: Accelerator standalone regression ───────────────────────────────
$ok = Run-Step `
    "Accelerator standalone regression  [accelerator/scripts/run_midsem_sim.ps1]" `
    "RISC-V\accelerator\scripts\run_midsem_sim.ps1" `
    "pass=19 total=19"
if ($ok) { $pass++ } else { $fail++ }

# ─── Step 2: Pipeline integration gate ───────────────────────────────────────
$ok = Run-Step `
    "Pipeline integration gate  [pipeline_top/scripts/run_pipeline_tests.ps1]" `
    "RISC-V\pipeline_top\scripts\run_pipeline_tests.ps1" `
    "ALL PIPELINE TESTS PASSED"
if ($ok) { $pass++ } else { $fail++ }

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================"
Write-Host "  RISC-V HANDOFF CHECK SUMMARY"
Write-Host "============================================================"
Write-Host ("  Passed : {0} / {1}" -f $pass, ($pass + $fail))
Write-Host ("  Failed : {0} / {1}" -f $fail, ($pass + $fail))
Write-Host "============================================================"

if ($fail -gt 0) {
    Write-Host "  HANDOFF CHECK FAILED"
    exit 1
} else {
    Write-Host "  HANDOFF CHECK PASSED"
    exit 0
}
