Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$midsemDir = Split-Path -Parent $scriptDir
$rtlDir = Join-Path $midsemDir "rtl"
$tbDir = Join-Path $midsemDir "tb"
$resultsDir = Join-Path $midsemDir "results"

New-Item -ItemType Directory -Force $resultsDir | Out-Null

$simExe = Join-Path $resultsDir "midsem_tb.out"
$logFile = Join-Path $resultsDir "sim_output.log"
$mdFile = Join-Path $resultsDir "MIDSEM_RESULTS.md"

$rtlFiles = @(
    (Join-Path $rtlDir "pe_cell_q5_10.v"),
    (Join-Path $rtlDir "issue_logic_4x4_q5_10.v"),
    (Join-Path $rtlDir "systolic_array_4x4_q5_10.v"),
    (Join-Path $rtlDir "matrix_accel_4x4_q5_10.v")
)

$tbFile = Join-Path $tbDir "tb_matrix_accel_4x4.v"

Write-Host "Compiling midsem simulation..."
& iverilog -g2012 -o $simExe @rtlFiles $tbFile
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Running simulation..."
& vvp $simExe | Tee-Object -FilePath $logFile
if ($LASTEXITCODE -ne 0) {
    throw "vvp simulation failed with exit code $LASTEXITCODE"
}

Write-Host "Generating markdown summary..."
& python (Join-Path $scriptDir "summarize_midsem_results.py") --log $logFile --out $mdFile
if ($LASTEXITCODE -ne 0) {
    throw "Result summarization failed with exit code $LASTEXITCODE"
}

Write-Host "Done."
Write-Host "Log: $logFile"
Write-Host "Summary: $mdFile"
