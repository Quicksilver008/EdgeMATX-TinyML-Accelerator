#!/usr/bin/env pwsh
# run_pipeline_tests.ps1
# Gate check for all rv32_pipeline tests.  Runs four suites in sequence;
# fails fast on the first compile or simulation error.
#
# Usage (from workspace root):
#   .\RISC-V\pipeline_top\scripts\run_pipeline_tests.ps1

$Root = "d:\Major_Project\EdgeMATX-TinyML-Accelerator"
$PTop = "$Root\RISC-V\pipeline_top"
Set-Location $Root

# Shared RTL list used by every test (core sub-modules, pipeline top, accelerator, PCPI wrapper)
$CoreRtl = @(
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
    "integration/pcpi_demo/rtl/pcpi_tinyml_accel.v",
    "RISC-V/pipeline_top/src/rv32_pipeline_pcpi_system.v"
)

function Run-Test {
    param(
        [string]   $Name,
        [string[]] $ExtraRtl,
        [string]   $TbFile,
        [string]   $PassPattern,
        [string]   $VvpDir = $Root
    )

    Write-Host ""
    Write-Host "=== $Name ==="

    $sources = $CoreRtl + $ExtraRtl + $TbFile
    $vvp     = "$Root\_test_$Name.vvp"

    $compile = iverilog -g2012 -o $vvp @sources 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "$Name  compile FAILED:`n$compile"; exit 1
    }

    Push-Location $VvpDir
    $out = vvp $vvp 2>&1
    Pop-Location
    Remove-Item $vvp -ErrorAction SilentlyContinue

    # Print relevant lines
    $out -split "`n" |
        Where-Object { $_ -match '(PASS|FAIL|ERROR|WARN|SUMMARY|===|---|case:|Run )' -and
                       $_ -notmatch '^\s*$' } |
        ForEach-Object { Write-Host $_.TrimEnd() }

    if (-not ($out | Select-String -SimpleMatch $PassPattern)) {
        Write-Error "$Name  FAILED — expected `"$PassPattern`" in output"; exit 1
    }
    Write-Host "$Name  OK"
}

# ── 1. Pipeline forwarding / hazard test ─────────────────────────────────────
Run-Test -Name "forwarding_hazards" `
         -ExtraRtl @() `
         -TbFile   "RISC-V/pipeline_top/tb/tb_pipeline_forwarding_hazards.v" `
         -PassPattern "TB_PASS ALL_CHECKS_PASSED"

# ── 2. Back-to-back PCPI (two consecutive CUSTOM_MATMUL) ─────────────────────
Run-Test -Name "back_to_back_pcpi" `
         -ExtraRtl @() `
         -TbFile   "RISC-V/pipeline_top/tb/tb_pipeline_back_to_back_pcpi.v" `
         -PassPattern "TB_PASS back-to-back PCPI test complete"

# ── 3. PCPI regression (4 matrix cases, full C-matrix verify) ────────────────
Run-Test -Name "pcpi_regression" `
         -ExtraRtl @() `
         -TbFile   "RISC-V/pipeline_top/tb/tb_pipeline_pcpi_regression.v" `
         -PassPattern "TB_PASS ALL_CASES_PASSED"

# ── 4. Cycle benchmark (ACCEL + SW, full C-matrix check) ─────────────────────
Write-Host ""
Write-Host "=== cycle_benchmark ==="
$fwPath = "/mnt/d/Major_Project/EdgeMATX-TinyML-Accelerator/RISC-V/pipeline_top/firmware"
wsl -- bash -c "cd $fwPath && make firmware_sw_bench.hex 2>&1" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Firmware build failed"; exit 1 }

$benchSources = $CoreRtl + "RISC-V/pipeline_top/tb/tb_cycle_benchmark.v"
iverilog -g2012 -o "$Root\cycle_bench.vvp" @benchSources 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "cycle_benchmark compile FAILED"; exit 1 }

Push-Location $PTop
$benchOut = vvp "$Root\cycle_bench.vvp" 2>&1
Pop-Location
Remove-Item "$Root\cycle_bench.vvp" -ErrorAction SilentlyContinue

$benchOut -split "`n" |
    Where-Object { $_ -match '(PASS|FAIL|ERROR|ACCEL|SW\s|Speedup|====|----)' -and
                   $_ -notmatch '^\s*$' } |
    ForEach-Object { Write-Host $_.TrimEnd() }

if (-not ($benchOut | Select-String -SimpleMatch "C matrix check PASS") -and
    -not ($benchOut | Select-String -SimpleMatch "ACCEL") ) {
    Write-Error "cycle_benchmark FAILED"; exit 1
}
Write-Host "cycle_benchmark  OK"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================"
Write-Host "  ALL PIPELINE TESTS PASSED"
Write-Host "======================================================"
