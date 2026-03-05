Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir = Join-Path $demoDir "firmware"
$resultsDir = Join-Path $demoDir "results"

function Resolve-AccelRoot {
    $candidates = @("accel_standalone", "midsem_sim")
    foreach ($candidate in $candidates) {
        $root = Join-Path $repoRoot $candidate
        if (Test-Path (Join-Path $root "rtl\matrix_accel_4x4_q5_10.v")) {
            return $root
        }
    }
    throw "Accelerator RTL root not found. Expected 'accel_standalone' or 'midsem_sim' with rtl sources."
}

$accelRoot = Resolve-AccelRoot

New-Item -ItemType Directory -Force $resultsDir | Out-Null

$simExe = Join-Path $resultsDir "pcpi_handoff_tb.out"
$logFile = Join-Path $resultsDir "pcpi_handoff.log"
$summaryFile = Join-Path $resultsDir "pcpi_handoff_summary.md"

$fwSrc = Join-Path $fwDir "firmware_handoff.S"
$fwElf = Join-Path $fwDir "firmware_handoff.elf"
$fwBin = Join-Path $fwDir "firmware_handoff.bin"
$fwHex = Join-Path $fwDir "firmware_handoff.hex"
$linker = Join-Path $fwDir "sections.lds"
$makehex = Join-Path $repoRoot "picorv32\firmware\makehex.py"

function Get-PythonExe {
    $candidates = @("python", "py")
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "Python interpreter not found."
}

function Convert-ToWslPath {
    param([string]$WindowsPath)
    if ($WindowsPath -match '^[A-Za-z]:\\') {
        $drive = $WindowsPath.Substring(0, 1).ToLowerInvariant()
        $rest = $WindowsPath.Substring(2).Replace('\', '/')
        return "/mnt/$drive$rest"
    }
    throw "Failed to convert path to WSL: $WindowsPath"
}

function Test-WslToolchain {
    & wsl bash -lc "command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && command -v riscv64-unknown-elf-objcopy >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Build-HandoffFirmware {
    $nativeGcc = Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue
    $nativeObjcopy = Get-Command riscv64-unknown-elf-objcopy -ErrorAction SilentlyContinue

    if ($nativeGcc -and $nativeObjcopy) {
        Write-Host "Using native Windows RISC-V toolchain."
        $fwMap = Join-Path $fwDir "firmware_handoff.map"
        $ldFlags = "-Wl,--build-id=none,-Bstatic,-T,$linker,-Map,$fwMap,--strip-debug"
        & $nativeGcc.Source -mabi=ilp32 -march=rv32i -ffreestanding -nostdlib -o $fwElf `
            $ldFlags `
            $fwSrc
        if ($LASTEXITCODE -ne 0) { throw "Native gcc build failed." }

        & $nativeObjcopy.Source -O binary $fwElf $fwBin
        if ($LASTEXITCODE -ne 0) { throw "Native objcopy failed." }

        $py = Get-PythonExe
        if ([System.IO.Path]::GetFileName($py).ToLowerInvariant() -eq "py.exe") {
            & $py -3 $makehex $fwBin 256 > $fwHex
        } else {
            & $py $makehex $fwBin 256 > $fwHex
        }
        if ($LASTEXITCODE -ne 0) { throw "Native makehex failed." }
        return
    }

    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wsl -and (Test-WslToolchain)) {
        Write-Host "Using WSL RISC-V toolchain fallback."
        $fwDirWsl = Convert-ToWslPath $fwDir
        & wsl bash -lc "cd '$fwDirWsl' && riscv64-unknown-elf-gcc -mabi=ilp32 -march=rv32i -ffreestanding -nostdlib -o firmware_handoff.elf -Wl,--build-id=none,-Bstatic,-T,sections.lds,-Map,firmware_handoff.map,--strip-debug firmware_handoff.S && riscv64-unknown-elf-objcopy -O binary firmware_handoff.elf firmware_handoff.bin && python3 ../../../picorv32/firmware/makehex.py firmware_handoff.bin 256 > firmware_handoff.hex"
        if ($LASTEXITCODE -ne 0) { throw "WSL firmware build failed." }
        return
    }

    if (Test-Path $fwHex) {
        $hexTime = (Get-Item $fwHex).LastWriteTimeUtc
        $srcFiles = @($fwSrc, $linker, $makehex)
        $newer = $srcFiles | Where-Object { (Get-Item $_).LastWriteTimeUtc -gt $hexTime } | Select-Object -First 1
        if ($newer) {
            throw "No toolchain available and firmware_handoff.hex is stale. Install native or WSL toolchain."
        }
        Write-Host "No toolchain found; using existing firmware_handoff.hex."
        return
    }

    throw "No toolchain path available and no firmware_handoff.hex fallback present."
}

$sources = @(
    (Join-Path $repoRoot "picorv32\picorv32.v"),
    (Join-Path $accelRoot "rtl\pe_cell_q5_10.v"),
    (Join-Path $accelRoot "rtl\issue_logic_4x4_q5_10.v"),
    (Join-Path $accelRoot "rtl\systolic_array_4x4_q5_10.v"),
    (Join-Path $accelRoot "rtl\matrix_accel_4x4_q5_10.v"),
    (Join-Path $demoDir "rtl\pcpi_tinyml_accel.v"),
    (Join-Path $demoDir "tb\tb_picorv32_pcpi_handoff.v")
)

Build-HandoffFirmware

Write-Host "Compiling handoff testbench..."
& iverilog -g2012 -o $simExe @sources
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed."
}

Write-Host "Running handoff simulation..."
& vvp $simExe | Tee-Object -FilePath $logFile | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "vvp simulation failed."
}

$logText = Get-Content -Raw -Path $logFile
if ($logText -notmatch "TB_PASS handoff test complete\.") {
    throw "Handoff pass marker missing."
}

$metrics = "unparsed"
if ($logText -match "TB_PASS custom_issue_count=(\d+)\s+ready_count=(\d+)\s+wr_count=(\d+)\s+handshake_ok_count=(\d+)\s+c_store_count=(\d+)") {
    $metrics = "custom_issue_count=$($Matches[1]), ready_count=$($Matches[2]), wr_count=$($Matches[3]), handshake_ok_count=$($Matches[4]), c_store_count=$($Matches[5])"
}

$summary = @()
$summary += "# PCPI Handoff Test Summary"
$summary += ""
$summary += "- Generated (UTC): $((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))"
$summary += "- Status: PASS"
$summary += "- Metrics: $metrics"
$summary += "- Log: integration/pcpi_demo/results/pcpi_handoff.log"
$summary += "- Waveform: integration/pcpi_demo/results/pcpi_handoff_wave.vcd"
($summary -join "`n") | Set-Content -Path $summaryFile -Encoding UTF8

Write-Host "Done."
Write-Host "Log: $logFile"
Write-Host "Waveform: integration/pcpi_demo/results/pcpi_handoff_wave.vcd"
Write-Host "Summary: $summaryFile"
