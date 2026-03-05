param(
    [ValidateSet("asm", "c")]
    [string]$FirmwareVariant = "asm"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir = Join-Path $demoDir "firmware"
$resultsDir = Join-Path $demoDir "results"

New-Item -ItemType Directory -Force $resultsDir | Out-Null

$simExe = Join-Path $resultsDir "pcpi_demo_tb.out"
$logFile = Join-Path $resultsDir "pcpi_demo.log"
$fwHex = Join-Path $fwDir "firmware.hex"

$firmwareSource = if ($FirmwareVariant -eq "c") {
    Join-Path $fwDir "firmware_c.c"
} else {
    Join-Path $fwDir "firmware.S"
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
    & wsl bash -lc "command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Build-Firmware {
    $wslBuildError = $null
    $nativeToolchain = Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue
    if ($nativeToolchain) {
        Write-Host "Using native Windows RISC-V toolchain."
        & make -C $fwDir clean all "FIRMWARE_SRC=$([System.IO.Path]::GetFileName($firmwareSource))"
        if ($LASTEXITCODE -ne 0) {
            throw "Native firmware build failed with exit code $LASTEXITCODE"
        }
        return
    }

    $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wslCmd -and (Test-WslToolchain)) {
        Write-Host "Using WSL RISC-V toolchain fallback."
        $fwDirWsl = Convert-ToWslPath $fwDir
        $variantName = [System.IO.Path]::GetFileName($firmwareSource)
        & wsl bash -lc "cd '$fwDirWsl' && make clean all PYTHON=python3 FIRMWARE_SRC=$variantName"
        if ($LASTEXITCODE -eq 0) {
            return
        }
        $wslBuildError = "WSL firmware build failed with exit code $LASTEXITCODE"
        Write-Host $wslBuildError
    }

    if (-not (Test-Path $fwHex)) {
        throw "No toolchain available and no prebuilt firmware hex exists at $fwHex"
    }

    if ($FirmwareVariant -eq "c") {
        if ($wslBuildError) {
            throw "C firmware variant requires toolchain rebuild. Last WSL error: $wslBuildError"
        }
        throw "C firmware variant requires toolchain rebuild (native or WSL)."
    }

    $fwSourceFiles = @(
        $firmwareSource,
        (Join-Path $fwDir "sections.lds"),
        (Join-Path $fwDir "Makefile")
    )
    $hexTime = (Get-Item $fwHex).LastWriteTimeUtc
    $newerSource = $fwSourceFiles | Where-Object { (Get-Item $_).LastWriteTimeUtc -gt $hexTime } | Select-Object -First 1
    if ($newerSource) {
        throw "RISC-V toolchain missing and firmware sources are newer than firmware.hex. Install toolchain and rebuild firmware."
    }
    Write-Host "No toolchain found; using existing firmware hex for asm flow: $fwHex"
}

$sources = @(
    (Join-Path $repoRoot "picorv32\picorv32.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\pe_cell_q5_10.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\issue_logic_4x4_q5_10.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\systolic_array_4x4_q5_10.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\matrix_accel_4x4_q5_10.v"),
    (Join-Path $demoDir "rtl\pcpi_tinyml_accel.v"),
    (Join-Path $demoDir "tb\tb_picorv32_pcpi_tinyml.v")
)

Write-Host "Selected firmware variant: $FirmwareVariant ($([System.IO.Path]::GetFileName($firmwareSource)))"
Build-Firmware

Write-Host "Compiling PCPI integration demo..."
& iverilog -g2012 -o $simExe @sources
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Running PCPI integration demo..."
& vvp $simExe | Tee-Object -FilePath $logFile
if ($LASTEXITCODE -ne 0) {
    throw "vvp simulation failed with exit code $LASTEXITCODE"
}

Write-Host "Done."
Write-Host "Log: $logFile"
Write-Host "Waveform: integration/pcpi_demo/results/pcpi_demo_wave.vcd"
