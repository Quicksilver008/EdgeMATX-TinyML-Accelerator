# run_picorv_mlperf.ps1
#
# MLCommons Tiny AD proxy benchmark for the PicoRV32 + EdgeMATX PCPI integration.
# Builds all three firmware variants, compiles the combined testbench, runs it,
# and prints the comparison table.
#
# Usage (from repo root or any directory):
#   .\integration\pcpi_demo\scripts\run_picorv_mlperf.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir    = Split-Path -Parent $scriptDir
$repoRoot   = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir      = Join-Path $demoDir "firmware"
$tbDir      = Join-Path $demoDir "tb"
$resultsDir = Join-Path $demoDir "results"

# ---- Locate accelerator RTL -------------------------------------------------
function Resolve-AccelRoot {
    foreach ($candidate in @("accel_standalone", "midsem_sim")) {
        $r = Join-Path $repoRoot $candidate
        if (Test-Path (Join-Path $r "rtl\matrix_accel_4x4_q5_10.v")) { return $r }
    }
    throw "Accelerator RTL root not found. Expected 'accel_standalone' or 'midsem_sim'."
}

$accelRoot = Resolve-AccelRoot
New-Item -ItemType Directory -Force $resultsDir | Out-Null

# ---- Path helpers -----------------------------------------------------------
function Convert-ToWslPath([string]$p) {
    if ($p -match '^[A-Za-z]:\\') {
        return "/mnt/$($p[0].ToString().ToLower())$($p.Substring(2).Replace('\','/'))"
    }
    throw "Cannot convert to WSL path: $p"
}

function Test-WslToolchain {
    & wsl bash -lc "command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

# ---- Build firmware via WSL -------------------------------------------------
Write-Host "`n=== Building firmware (WSL) ==="
$wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $wslCmd -or -not (Test-WslToolchain)) {
    throw "WSL RISC-V toolchain (riscv64-unknown-elf-gcc + make) not found."
}

$fwDirWsl = Convert-ToWslPath $fwDir
& wsl bash -lc "cd '$fwDirWsl' && make mlperf PYTHON=python3 2>&1"
if ($LASTEXITCODE -ne 0) { throw "Firmware build failed (exit $LASTEXITCODE)" }
Write-Host "Firmware built OK"

# Verify outputs
foreach ($hex in @(
    "firmware_mlperf_proxy_picorv.hex",
    "firmware_sw_picorv_mlperf.hex",
    "firmware_sw_picorv_mlperf_mul.hex"
)) {
    if (-not (Test-Path (Join-Path $fwDir $hex))) {
        throw "Expected firmware hex not found: $hex"
    }
}

# ---- Compile simulation -----------------------------------------------------
$simExe  = Join-Path $resultsDir "picorv_mlperf.out"
$sources = @(
    (Join-Path $repoRoot  "picorv32\picorv32.v"),
    (Join-Path $accelRoot "rtl\pe_cell_q5_10.v"),
    (Join-Path $accelRoot "rtl\issue_logic_4x4_q5_10.v"),
    (Join-Path $accelRoot "rtl\systolic_array_4x4_q5_10.v"),
    (Join-Path $accelRoot "rtl\matrix_accel_4x4_q5_10.v"),
    (Join-Path $demoDir   "rtl\pcpi_tinyml_accel.v"),
    (Join-Path $tbDir     "tb_picorv_mlperf_proxy.v")
)

Write-Host "`n=== Compiling simulation ==="
& iverilog -g2012 -o $simExe @sources
if ($LASTEXITCODE -ne 0) { throw "iverilog compilation failed (exit $LASTEXITCODE)" }
Write-Host "Compilation OK"

# ---- Run simulation (from repo root so $readmemh paths resolve) -------------
Write-Host "`n=== Running PicoRV32 MLPerf Tiny Proxy Benchmark ==="
Push-Location $repoRoot
try {
    & vvp $simExe
    if ($LASTEXITCODE -ne 0) { throw "vvp simulation failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# Clean up compiled output
Remove-Item -Force $simExe -ErrorAction SilentlyContinue

Write-Host "`nDone."
