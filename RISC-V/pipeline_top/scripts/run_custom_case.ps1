#!/usr/bin/env pwsh
# run_custom_case.ps1
# Run a user-supplied 4x4 Q5.10 matrix-multiply case through both the
# ACCEL and SW paths and produce a JSON + Markdown summary.
#
# Usage (from anywhere):
#   .\RISC-V\pipeline_top\scripts\run_custom_case.ps1 [-InputJson <path>] [-CaseName <name>]
#
# Defaults:
#   -InputJson  RISC-V/pipeline_top/tests/input.json
#   -CaseName   custom

param(
    [string]$InputJson = "",
    [string]$CaseName  = "custom"
)

$ErrorActionPreference = "Stop"

# ── Paths ────────────────────────────────────────────────────────────────────
$Root  = (Resolve-Path "$PSScriptRoot\..\..\.." ).Path
$PTop  = "$Root\RISC-V\pipeline_top"
$FwDir = "$PTop\firmware"
$TbDir = "$PTop\tb"

if ($InputJson -eq "") {
    $InputJson = "$PTop\tests\input.json"
}
$InputJson = (Resolve-Path $InputJson).Path

$VhOut    = "$TbDir\custom_case_data.vh"
$ExpJson  = "$PTop\results\custom_cases\${CaseName}_expected.json"
$SumJson  = "$PTop\results\custom_cases\${CaseName}_summary.json"
$SumMd    = "$PTop\results\custom_cases\${CaseName}_summary.md"
$OutVvp   = "$Root\custom_case.vvp"

Set-Location $Root

Write-Host ""
Write-Host "=== Custom Case: $CaseName ==="
Write-Host "    Input : $InputJson"
Write-Host "    Output: $SumMd"

# ── Step 1: Generate Verilog header + expected JSON from real input ───────────
Write-Host ""
Write-Host "=== [1/4] Generating Q5.10 case data ==="

$genScript = "$PTop\tests\gen_custom_case.py"
python $genScript `
    --input     $InputJson `
    --vh-out    $VhOut `
    --json-out  $ExpJson `
    --case-name $CaseName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "gen_custom_case.py failed"; exit 1
}

# ── Step 2: Build firmware_sw_bench.hex via WSL ───────────────────────────────
Write-Host ""
Write-Host "=== [2/4] Building firmware ==="

$_drive  = $Root.Substring(0,1).ToLower()
$fwPath  = "/mnt/$_drive" + ($Root.Substring(2) -replace '\\','/') + "/RISC-V/pipeline_top/firmware"
wsl -- bash -c "cd $fwPath && make -B firmware_sw_bench.hex 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Firmware build failed"; exit 1
}
Write-Host "Firmware built OK"

# ── Step 3: Compile simulation ────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [3/4] Compiling simulation ==="

$rtl_files = @(
    "RISC-V/core/rtl/data_memory.v",
    "RISC-V/core/rtl/alu.v",
    "RISC-V/core/rtl/alu_control.v",
    "RISC-V/core/rtl/Control_Unit.v",
    "RISC-V/core/rtl/forwarding_unit.v",
    "RISC-V/core/rtl/hazard_detection_unit.v",
    "RISC-V/core/rtl/instruction_decoder.v",
    "RISC-V/core/rtl/register_bank.v",
    "RISC-V/pipeline_top/src/rv32_pipeline_top.v",
    "accel_standalone/rtl/pe_cell_q5_10.v",
    "accel_standalone/rtl/systolic_array_4x4_q5_10.v",
    "accel_standalone/rtl/issue_logic_4x4_q5_10.v",
    "accel_standalone/rtl/matrix_accel_4x4_q5_10.v",
    "RISC-V/accelerator/rtl/pcpi_tinyml_accel.v",
    "RISC-V/pipeline_top/src/rv32_pipeline_pcpi_system.v",
    "RISC-V/pipeline_top/tb/tb_custom_case.v"
)

$result = iverilog -g2012 -I "$Root\RISC-V\pipeline_top\tb" -o $OutVvp @rtl_files 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Compilation failed:`n$result"; exit 1
}
Write-Host "Compilation OK"

# ── Step 4: Run simulation ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== [4/4] Running simulation ==="

Push-Location $PTop
$rawOutput = vvp $OutVvp 2>&1
Pop-Location

# Display lines relevant to the run
$rawOutput -split "`n" | Where-Object {
    $_ -match 'CUSTOM_CASE|ERROR|WARN' -and $_ -notmatch '\$finish'
} | ForEach-Object { Write-Host $_.TrimEnd() }

# ── Parse results ──────────────────────────────────────────────────────────────
$accelCycles = 0
$swCycles    = 0
$speedupInt  = 0
$speedupFrac = 0
$accelPass   = 0
$swPass      = 0
$accelVerify = "UNKNOWN"
$swVerify    = "UNKNOWN"

foreach ($line in ($rawOutput -split "`n")) {
    if ($line -match 'CUSTOM_CASE \[ACCEL\] cycles=(\d+)') {
        $accelCycles = [int]$Matches[1]
    }
    if ($line -match 'CUSTOM_CASE \[SW\]\s+cycles=(\d+)') {
        $swCycles = [int]$Matches[1]
    }
    if ($line -match 'CUSTOM_CASE speedup_int=(\d+)\s+speedup_frac=(\d+)\s+cycles_accel=(\d+)\s+cycles_sw=(\d+)') {
        $speedupInt  = [int]$Matches[1]
        $speedupFrac = [int]$Matches[2]
    }
    if ($line -match 'CUSTOM_CASE \[ACCEL\] verify: (\d+)/16 (PASS|FAIL)') {
        $accelPass   = [int]$Matches[1]
        $accelVerify = $Matches[2]
    }
    if ($line -match 'CUSTOM_CASE \[SW\]\s+verify: (\d+)/16 (PASS|FAIL)') {
        $swPass    = [int]$Matches[1]
        $swVerify  = $Matches[2]
    }
}

if ($accelCycles -eq 0) {
    Write-Error "Simulation did not produce ACCEL cycle count — check output above"; exit 1
}

$speedupStr  = "${speedupInt}.${speedupFrac}"
$overallPass = ($accelVerify -eq "PASS") -and ($swVerify -eq "PASS")
$status      = if ($overallPass) {"PASS"} else {"FAIL"}

# ── Load expected JSON and build summary ──────────────────────────────────────
$expected = Get-Content $ExpJson -Raw | ConvertFrom-Json

$summaryData = [ordered]@{
    case_name        = $CaseName
    status           = $status
    accel_cycles     = $accelCycles
    sw_cycles        = $swCycles
    speedup          = $speedupStr
    accel_verify     = "$accelPass/16 $accelVerify"
    sw_verify        = "$swPass/16 $swVerify"
    input_json       = $InputJson
    generated_at_utc = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")
    a_q5_10_4x4      = $expected.input.a_q5_10_4x4
    b_q5_10_4x4      = $expected.input.b_q5_10_4x4
    expected_c       = $expected.expected_c
}
$summaryData | ConvertTo-Json -Depth 10 | Set-Content $SumJson -Encoding UTF8

# ── Write Markdown summary ────────────────────────────────────────────────────
$md = @"
# Custom Case: $CaseName

**Status:** $status  
**Generated:** $($summaryData.generated_at_utc)  

## Cycle Comparison

| Path  | Cycles | Verify       |
|-------|--------|--------------|
| ACCEL | $accelCycles | $accelPass/16 $accelVerify |
| SW    | $swCycles | $swPass/16 $swVerify |

**Speedup: ${speedupStr}x** (SW / ACCEL)

## Input A (Q5.10)

$(($expected.input.a_q5_10_4x4 | ForEach-Object { "| " + ($_ -join " | ") + " |" }) -join "`n")

## Input B (Q5.10)

$(($expected.input.b_q5_10_4x4 | ForEach-Object { "| " + ($_ -join " | ") + " |" }) -join "`n")

## Expected C = A × B (Q5.10 lower 16 bits)

$(($expected.expected_c.c_q5_10_4x4 | ForEach-Object { "| " + ($_ -join " | ") + " |" }) -join "`n")

### In real values

$(($expected.expected_c.c_real_4x4 | ForEach-Object { "| " + (($_ | ForEach-Object {"{0:F4}" -f $_}) -join " | ") + " |" }) -join "`n")
"@

Set-Content $SumMd -Value $md -Encoding UTF8

# ── Cleanup ───────────────────────────────────────────────────────────────────
Remove-Item $OutVvp -ErrorAction SilentlyContinue

# ── Final output ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================"
Write-Host "  Custom Case: $CaseName   $status"
Write-Host "======================================================"
Write-Host "  ACCEL : $accelCycles cycles   verify: $accelPass/16 $accelVerify"
Write-Host "  SW    : $swCycles cycles   verify: $swPass/16 $swVerify"
Write-Host "  Speedup: ${speedupStr}x"
Write-Host "======================================================"
Write-Host ""
Write-Host "Summary written to:"
Write-Host "  $SumJson"
Write-Host "  $SumMd"

if (-not $overallPass) { exit 1 }
