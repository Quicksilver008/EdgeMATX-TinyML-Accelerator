Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir = Join-Path $demoDir "firmware"
$tbDir = Join-Path $demoDir "tb"
$testsDir = Join-Path $demoDir "tests"
$resultsDir = Join-Path $demoDir "results"

New-Item -ItemType Directory -Force $resultsDir | Out-Null

$accelLog = Join-Path $resultsDir "pcpi_cycle_accel.log"
$swLog = Join-Path $resultsDir "pcpi_cycle_sw.log"
$summaryMd = Join-Path $resultsDir "pcpi_cycle_compare_summary.md"
$summaryJson = Join-Path $resultsDir "pcpi_cycle_compare_summary.json"

$casesFile = Join-Path $testsDir "cases.json"
$generator = Join-Path $testsDir "gen_case_firmware.py"
$firmwareS = Join-Path $fwDir "firmware.S"
$metaOut = Join-Path $resultsDir "pcpi_cycle_compare_identity.expected.json"

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
    & wsl bash -lc "command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Get-PythonExe {
    $candidates = @("python", "py")
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "Python interpreter not found."
}

function Prepare-IdentityAccelCase {
    $pythonExe = Get-PythonExe
    if ([System.IO.Path]::GetFileName($pythonExe).ToLowerInvariant() -eq "py.exe") {
        & $pythonExe -3 $generator --cases $casesFile --case identity_x_sequence --firmware-out $firmwareS --meta-out $metaOut
    } else {
        & $pythonExe $generator --cases $casesFile --case identity_x_sequence --firmware-out $firmwareS --meta-out $metaOut
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate identity firmware case for accelerator run."
    }
}

function Build-Firmware {
    param(
        [string]$SourceFileName,
        [int]$Words
    )

    $nativeToolchain = Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue
    if ($nativeToolchain) {
        Write-Host "Using native Windows RISC-V toolchain for $SourceFileName."
        & make -C $fwDir clean all "FIRMWARE_SRC=$SourceFileName" "WORDS=$Words"
        if ($LASTEXITCODE -ne 0) {
            throw "Native firmware build failed for $SourceFileName with exit code $LASTEXITCODE"
        }
        return
    }

    $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wslCmd -and (Test-WslToolchain)) {
        Write-Host "Using WSL RISC-V toolchain fallback for $SourceFileName."
        $fwDirWsl = Convert-ToWslPath $fwDir
        & wsl bash -lc "cd '$fwDirWsl' && make clean all PYTHON=python3 FIRMWARE_SRC=$SourceFileName WORDS=$Words"
        if ($LASTEXITCODE -ne 0) {
            throw "WSL firmware build failed for $SourceFileName with exit code $LASTEXITCODE"
        }
        return
    }

    throw "No firmware build toolchain available (native or WSL)."
}

function Run-Sim {
    param(
        [string]$Name,
        [string]$FirmwareSrc,
        [string]$TbFile,
        [string]$LogFile,
        [int]$FirmwareWords
    )

    $simExe = Join-Path $resultsDir ("{0}.out" -f $Name)
    $sources = @(
        (Join-Path $repoRoot "picorv32\picorv32.v"),
        (Join-Path $repoRoot "midsem_sim\rtl\pe_cell_q5_10.v"),
        (Join-Path $repoRoot "midsem_sim\rtl\issue_logic_4x4_q5_10.v"),
        (Join-Path $repoRoot "midsem_sim\rtl\systolic_array_4x4_q5_10.v"),
        (Join-Path $repoRoot "midsem_sim\rtl\matrix_accel_4x4_q5_10.v"),
        (Join-Path $demoDir "rtl\pcpi_tinyml_accel.v"),
        (Join-Path $tbDir $TbFile)
    )

    Build-Firmware -SourceFileName $FirmwareSrc -Words $FirmwareWords

    Write-Host "Compiling $Name testbench..."
    & iverilog -g2012 -o $simExe @sources
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog failed for $Name."
    }

    Write-Host "Running $Name simulation..."
    & vvp $simExe | Tee-Object -FilePath $LogFile | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "vvp failed for $Name."
    }
}

function Get-CycleCountFromLog {
    param([string]$LogFile)
    $logText = Get-Content -Raw -Path $LogFile
    if ($logText -match "TB_CYCLES matmul_to_sentinel_cycles=(\d+)") {
        return [int]$Matches[1]
    }
    throw "Cycle marker not found in $LogFile"
}

Prepare-IdentityAccelCase
Run-Sim -Name "pcpi_cycle_accel" -FirmwareSrc "firmware.S" -TbFile "tb_picorv32_pcpi_tinyml.v" -LogFile $accelLog -FirmwareWords 256
Run-Sim -Name "pcpi_cycle_sw" -FirmwareSrc "firmware_sw_matmul.c" -TbFile "tb_picorv32_sw_matmul.v" -LogFile $swLog -FirmwareWords 1024

$accelCycles = Get-CycleCountFromLog -LogFile $accelLog
$swCycles = Get-CycleCountFromLog -LogFile $swLog

if ($accelCycles -le 0) {
    throw "Invalid accelerator cycle count: $accelCycles"
}

$speedup = [double]$swCycles / [double]$accelCycles

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    accel_cycles = $accelCycles
    sw_cycles = $swCycles
    speedup_sw_over_accel = [Math]::Round($speedup, 4)
    accel_log = "integration/pcpi_demo/results/pcpi_cycle_accel.log"
    sw_log = "integration/pcpi_demo/results/pcpi_cycle_sw.log"
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryJson -Encoding UTF8

$md = @()
$md += "# PCPI Cycle Comparison Summary"
$md += ""
$md += "- Generated (UTC): $($summary.generated_at_utc)"
$md += "- Accelerator cycles: $($summary.accel_cycles)"
$md += "- Software cycles: $($summary.sw_cycles)"
$md += "- Speedup (software / accelerator): $($summary.speedup_sw_over_accel)x"
$md += ""
$md += "Logs:"
$md += "- $($summary.accel_log)"
$md += "- $($summary.sw_log)"
$md -join "`n" | Set-Content -Path $summaryMd -Encoding UTF8

Write-Host ("CYCLE_COMPARE accel_cycles={0} sw_cycles={1} speedup={2}x" -f $accelCycles, $swCycles, [Math]::Round($speedup, 4))
Write-Host "Summary (md): $summaryMd"
Write-Host "Summary (json): $summaryJson"
