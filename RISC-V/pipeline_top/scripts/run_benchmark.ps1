#!/usr/bin/env pwsh
# run_benchmark.ps1
# Builds firmware then runs the cycle benchmark simulation.
#
# Usage (from anywhere):  .\RISC-V\pipeline_top\scripts\run_benchmark.ps1

# Derive workspace root from the script's own location — works on any machine.
$Root  = (Resolve-Path "$PSScriptRoot\..\..\.." ).Path
$PTop  = "$Root\RISC-V\pipeline_top"
$FwDir = "$PTop\firmware"

Set-Location $Root

# ────────────────────────────────────────────────────────────────────────────
# 1. Build firmware_sw_bench.hex in WSL
# ────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Building firmware ==="
# Convert Windows path to WSL mount path (e.g. D:\foo\bar -> /mnt/d/foo/bar)
$_drive = $Root.Substring(0,1).ToLower()
$fwPath = "/mnt/$_drive" + ($Root.Substring(2) -replace '\\','/') + "/RISC-V/pipeline_top/firmware"
wsl -- bash -c "cd $fwPath && make firmware_sw_bench.hex 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Firmware build failed"; exit 1
}
Write-Host "Firmware built OK"

# ────────────────────────────────────────────────────────────────────────────
# 2. Compile the simulation
# ────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Compiling simulation ==="
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
    "RISC-V/pipeline_top/tb/tb_cycle_benchmark.v"
)

$result = iverilog -g2012 -o cycle_bench.vvp @rtl_files 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Compilation failed:`n$result"; exit 1
}
Write-Host "Compilation OK"

# ────────────────────────────────────────────────────────────────────────────
# 3. Run simulation (vvp run dir must be pipeline_top so hex path resolves)
# ────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Running benchmark ==="
Push-Location $PTop
$output = vvp "$Root\cycle_bench.vvp" 2>&1
Pop-Location

# Print only lines that matter — suppress internal $finish line and empty noise
$output -split "`n" | Where-Object {
    $_ -match '(PASS|FAIL|ERROR|WARN|======|------|MatMul|ACCEL|SW \s*\(|Speedup|Notes:|breakdown|SW uses|systolic|multiply)' -and
    $_ -notmatch '^\s*$' -and
    $_ -notmatch '\$finish called'
} | ForEach-Object { Write-Host $_.TrimEnd() }

# ────────────────────────────────────────────────────────────────────────────
# 4. Cleanup
# ────────────────────────────────────────────────────────────────────────────
Remove-Item "$Root\cycle_bench.vvp" -ErrorAction SilentlyContinue
