Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir = Join-Path $demoDir "firmware"
$tbDir = Join-Path $demoDir "tb"
$resultsDir = Join-Path $demoDir "results"
$flowLockPath = Join-Path $fwDir ".firmware_flow.lock"

New-Item -ItemType Directory -Force $resultsDir | Out-Null

$accelLog = Join-Path $resultsDir "pcpi_cycle_accel.log"
$swNoMulLog = Join-Path $resultsDir "pcpi_cycle_sw_nomul.log"
$swMulLog = Join-Path $resultsDir "pcpi_cycle_sw_mul.log"
$summaryMd = Join-Path $resultsDir "pcpi_cycle_compare_summary.md"
$summaryJson = Join-Path $resultsDir "pcpi_cycle_compare_summary.json"

$unifiedFirmwareSrc = "firmware_matmul_unified.c"
$accelExtraCFlags = "-DMATMUL_MODE_ACCEL=1 -DMATMUL_MODE_SW=0 -DA_BASE_WORD_ADDR=0x100u -DB_BASE_WORD_ADDR=0x140u -DC_BASE_WORD_ADDR=0x200u"
$swExtraCFlags = "-DMATMUL_MODE_ACCEL=0 -DMATMUL_MODE_SW=1 -DA_BASE_WORD_ADDR=0x800u -DB_BASE_WORD_ADDR=0x840u -DC_BASE_WORD_ADDR=0x900u"

function Acquire-FlowLock {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            # Keep an exclusive handle until script exit to prevent concurrent firmware rewrites.
            $script:flowLockHandle = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Timed out waiting for firmware flow lock: $Path"
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

Acquire-FlowLock -Path $flowLockPath

function Test-WslToolchain {
    & wsl bash -lc "command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Build-Firmware {
    param(
        [string]$SourceFileName,
        [int]$Words,
        [string]$Arch = "rv32i",
        [string]$ExtraCFlags = ""
    )

    $nativeToolchain = Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue
    if ($nativeToolchain) {
        Write-Host "Using native Windows RISC-V toolchain for $SourceFileName (ARCH=$Arch)."
        $makeArgs = @("-C", $fwDir, "clean", "all", "FIRMWARE_SRC=$SourceFileName", "WORDS=$Words", "ARCH=$Arch")
        if (-not [string]::IsNullOrWhiteSpace($ExtraCFlags)) {
            $makeArgs += "EXTRA_CFLAGS=$ExtraCFlags"
        }
        & make @makeArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Native firmware build failed for $SourceFileName with exit code $LASTEXITCODE"
        }
        return
    }

    $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wslCmd -and (Test-WslToolchain)) {
        Write-Host "Using WSL RISC-V toolchain fallback for $SourceFileName (ARCH=$Arch)."
        $fwDirWsl = Convert-ToWslPath $fwDir
        $makeCmd = "cd '$fwDirWsl' && make clean all PYTHON=python3 FIRMWARE_SRC=$SourceFileName WORDS=$Words ARCH=$Arch"
        if (-not [string]::IsNullOrWhiteSpace($ExtraCFlags)) {
            $makeCmd += " EXTRA_CFLAGS='$ExtraCFlags'"
        }
        & wsl bash -lc $makeCmd
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
        [int]$FirmwareWords,
        [string]$Arch = "rv32i",
        [string]$ExtraCFlags = ""
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

    Build-Firmware -SourceFileName $FirmwareSrc -Words $FirmwareWords -Arch $Arch -ExtraCFlags $ExtraCFlags

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

Run-Sim -Name "pcpi_cycle_accel" -FirmwareSrc $unifiedFirmwareSrc -TbFile "tb_picorv32_pcpi_tinyml.v" -LogFile $accelLog -FirmwareWords 256 -Arch "rv32i" -ExtraCFlags $accelExtraCFlags
Run-Sim -Name "pcpi_cycle_sw_nomul" -FirmwareSrc $unifiedFirmwareSrc -TbFile "tb_picorv32_sw_matmul.v" -LogFile $swNoMulLog -FirmwareWords 1024 -Arch "rv32i" -ExtraCFlags $swExtraCFlags
Run-Sim -Name "pcpi_cycle_sw_mul" -FirmwareSrc $unifiedFirmwareSrc -TbFile "tb_picorv32_sw_matmul_mul.v" -LogFile $swMulLog -FirmwareWords 1024 -Arch "rv32im" -ExtraCFlags $swExtraCFlags

$accelCycles = Get-CycleCountFromLog -LogFile $accelLog
$swNoMulCycles = Get-CycleCountFromLog -LogFile $swNoMulLog
$swMulCycles = Get-CycleCountFromLog -LogFile $swMulLog

if ($accelCycles -le 0) {
    throw "Invalid accelerator cycle count: $accelCycles"
}
$speedupSwNoMulOverAccel = [double]$swNoMulCycles / [double]$accelCycles
$speedupSwMulOverAccel = [double]$swMulCycles / [double]$accelCycles

if ($swMulCycles -le 0) {
    throw "Invalid software (MUL-enabled) cycle count: $swMulCycles"
}
$swMulBenefit = [double]$swNoMulCycles / [double]$swMulCycles

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    accel_cycles = $accelCycles
    sw_nomul_cycles = $swNoMulCycles
    sw_mul_cycles = $swMulCycles
    speedup_sw_nomul_over_accel = [Math]::Round($speedupSwNoMulOverAccel, 4)
    speedup_sw_mul_over_accel = [Math]::Round($speedupSwMulOverAccel, 4)
    speedup_sw_nomul_over_sw_mul = [Math]::Round($swMulBenefit, 4)
    assumptions = [ordered]@{
        accel_core = "PicoRV32 PCPI path (ENABLE_PCPI=1, ENABLE_MUL=0, ENABLE_FAST_MUL=0)"
        sw_nomul_core = "PicoRV32 baseline (ENABLE_PCPI=0, ENABLE_MUL=0, ENABLE_FAST_MUL=0)"
        sw_mul_core = "PicoRV32 baseline (ENABLE_PCPI=0, ENABLE_MUL=1, ENABLE_FAST_MUL=0)"
        sw_nomul_arch = "rv32i"
        sw_mul_arch = "rv32im"
        accel_arch = "rv32i"
        firmware_source = $unifiedFirmwareSrc
    }
    accel_log = "integration/pcpi_demo/results/pcpi_cycle_accel.log"
    sw_nomul_log = "integration/pcpi_demo/results/pcpi_cycle_sw_nomul.log"
    sw_mul_log = "integration/pcpi_demo/results/pcpi_cycle_sw_mul.log"
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryJson -Encoding UTF8

$md = @()
$md += "# PCPI Cycle Comparison Summary"
$md += ""
$md += "- Generated (UTC): $($summary.generated_at_utc)"
$md += "- Accelerator cycles: $($summary.accel_cycles)"
$md += "- Software cycles (no MUL, rv32i): $($summary.sw_nomul_cycles)"
$md += "- Software cycles (MUL enabled, rv32im): $($summary.sw_mul_cycles)"
$md += "- Speedup (SW no-MUL / accelerator): $($summary.speedup_sw_nomul_over_accel)x"
$md += "- Speedup (SW MUL / accelerator): $($summary.speedup_sw_mul_over_accel)x"
$md += "- SW MUL benefit (SW no-MUL / SW MUL): $($summary.speedup_sw_nomul_over_sw_mul)x"
$md += ""
$md += "| Path | Core Config | Firmware Arch | Cycles | Relative To Accelerator |"
$md += "| --- | --- | --- | ---: | ---: |"
$md += "| Accelerator custom instruction | ENABLE_PCPI=1, ENABLE_MUL=0 | rv32i | $($summary.accel_cycles) | 1.0000x |"
$md += "| Software baseline (no MUL) | ENABLE_PCPI=0, ENABLE_MUL=0 | rv32i | $($summary.sw_nomul_cycles) | $($summary.speedup_sw_nomul_over_accel)x |"
$md += "| Software baseline (MUL enabled) | ENABLE_PCPI=0, ENABLE_MUL=1 | rv32im | $($summary.sw_mul_cycles) | $($summary.speedup_sw_mul_over_accel)x |"
$md += ""
$md += "Logs:"
$md += "- $($summary.accel_log)"
$md += "- $($summary.sw_nomul_log)"
$md += "- $($summary.sw_mul_log)"
$md -join "`n" | Set-Content -Path $summaryMd -Encoding UTF8

Write-Host ("CYCLE_COMPARE accel={0} sw_nomul={1} sw_mul={2} speedup_nomul={3}x speedup_mul={4}x sw_mul_benefit={5}x" -f `
    $accelCycles, `
    $swNoMulCycles, `
    $swMulCycles, `
    [Math]::Round($speedupSwNoMulOverAccel, 4), `
    [Math]::Round($speedupSwMulOverAccel, 4), `
    [Math]::Round($swMulBenefit, 4))
Write-Host "Summary (md): $summaryMd"
Write-Host "Summary (json): $summaryJson"
