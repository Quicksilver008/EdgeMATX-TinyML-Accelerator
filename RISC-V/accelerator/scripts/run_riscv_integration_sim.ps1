Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$accelDir = Split-Path -Parent $scriptDir
$rtlDir = Join-Path $accelDir "rtl"
$tbDir = Join-Path $accelDir "tb"
$resultsDir = Join-Path $accelDir "results"

New-Item -ItemType Directory -Force $resultsDir | Out-Null

$simExe = Join-Path $resultsDir "riscv_integration_tb.out"
$logFile = Join-Path $resultsDir "riscv_integration_sim_output.log"
$mdFile = Join-Path $resultsDir "RISCV_INTEGRATION_RESULTS.md"

$rtlFiles = @(
    (Join-Path $rtlDir "pe_cell_q5_10.v"),
    (Join-Path $rtlDir "issue_logic_4x4_q5_10.v"),
    (Join-Path $rtlDir "systolic_array_4x4_q5_10.v"),
    (Join-Path $rtlDir "matrix_accel_4x4_q5_10.v"),
    (Join-Path $rtlDir "riscv_matmul_bridge.v"),
    (Join-Path $rtlDir "riscv_accel_integration_stub.v")
)

$tbFile = Join-Path $tbDir "tb_riscv_accel_integration.v"

Write-Host "Compiling RISC-V integration simulation..."
& iverilog -g2012 -o $simExe @rtlFiles $tbFile
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Running integration simulation..."
& vvp $simExe | Tee-Object -FilePath $logFile
if ($LASTEXITCODE -ne 0) {
    throw "vvp simulation failed with exit code $LASTEXITCODE"
}

Write-Host "Generating markdown summary..."
& python (Join-Path $scriptDir "summarize_riscv_integration_results.py") --log $logFile --out $mdFile
if ($LASTEXITCODE -ne 0) {
    throw "Result summarization failed with exit code $LASTEXITCODE"
}

Write-Host "Done."
Write-Host "Log: $logFile"
Write-Host "Summary: $mdFile"
