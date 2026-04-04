#!/usr/bin/env pwsh
# run_mlperf_proxy.ps1
#
# MLCommons Tiny Anomaly Detection proxy benchmark runner.
#
# Builds firmware_mlperf_proxy.hex (via WSL/RISC-V toolchain), then compiles
# and runs tb_mlperf_proxy.v with Icarus Verilog to report extrapolated AD
# inference cycles and latency.
#
# Usage (from repo root or anywhere):
#   .\RISC-V\pipeline_top\scripts\run_mlperf_proxy.ps1

$Root  = (Resolve-Path "$PSScriptRoot\..\..\.." ).Path
$PTop  = "$Root\RISC-V\pipeline_top"
$FwDir = "$PTop\firmware"

Set-Location $Root

# ────────────────────────────────────────────────────────────────────────────
# 1. Build firmware_mlperf_proxy.hex inside WSL
# ────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Building firmware_mlperf_proxy.hex (WSL) ==="

$_drive = $Root.Substring(0,1).ToLower()
$fwPath = "/mnt/$_drive" + ($Root.Substring(2) -replace '\\','/') + "/RISC-V/pipeline_top/firmware"

wsl -- bash -c "cd $fwPath && make firmware_mlperf_proxy.hex 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Firmware build failed.  Ensure riscv64-unknown-elf-gcc is in WSL PATH."
    exit 1
}
Write-Host "Firmware built OK"

# ────────────────────────────────────────────────────────────────────────────
# 2. Compile simulation with Icarus Verilog
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
    "RISC-V/pipeline_top/tb/tb_mlperf_proxy.v"
)

$result = iverilog -g2012 -o mlperf_proxy.vvp @rtl_files 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Icarus Verilog compilation failed:`n$result"
    exit 1
}
Write-Host "Compilation OK"

# ────────────────────────────────────────────────────────────────────────────
# 3. Run simulation (cwd = pipeline_top so $readmemh hex path resolves)
# ────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Running MLPerf Tiny Proxy Benchmark ==="

Push-Location $PTop
$output = vvp "$Root\mlperf_proxy.vvp" 2>&1
Pop-Location

$output -split "`n" | Where-Object {
    $_ -notmatch '^\s*$' -and $_ -notmatch '\$finish called'
} | ForEach-Object { Write-Host $_.TrimEnd() }

# ────────────────────────────────────────────────────────────────────────────
# 4. Cleanup
# ────────────────────────────────────────────────────────────────────────────
Remove-Item "$Root\mlperf_proxy.vvp" -ErrorAction SilentlyContinue

exit ($output -match 'ERROR' ? 1 : 0)
