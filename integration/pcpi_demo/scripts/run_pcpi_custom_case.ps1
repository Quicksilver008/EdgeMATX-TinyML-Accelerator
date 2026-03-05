param(
    [Parameter(Mandatory = $true)]
    [string]$CaseName,
    [string]$CasesFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir = Join-Path $demoDir "firmware"
$tbDir = Join-Path $demoDir "tb"
$testsDir = Join-Path $demoDir "tests"
$resultsDir = Join-Path $demoDir "results"
$customResultsDir = Join-Path $resultsDir "custom_cases"
$flowLockPath = Join-Path $fwDir ".firmware_flow.lock"

if ([string]::IsNullOrWhiteSpace($CasesFile)) {
    $CasesFile = Join-Path $testsDir "custom_cases.json"
}

$generator = Join-Path $testsDir "gen_case_firmware.py"
$firmwareS = Join-Path $fwDir "firmware.S"
$simExe = Join-Path $resultsDir "pcpi_custom_case_tb.out"
$caseLog = Join-Path $customResultsDir "$CaseName.log"
$caseMeta = Join-Path $customResultsDir "$CaseName.expected.json"

function Acquire-FlowLock {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            # Keep an exclusive handle until script exit to avoid concurrent firmware rewrites.
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

function Get-PythonExe {
    $candidates = @("python", "py")
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
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
    & wsl bash -lc "command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Build-Firmware {
    $nativeToolchain = Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue
    if ($nativeToolchain) {
        Write-Host "Using native Windows RISC-V toolchain."
        & make -C $fwDir clean all
        if ($LASTEXITCODE -ne 0) {
            throw "Native firmware build failed with exit code $LASTEXITCODE"
        }
        return
    }

    $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
    if (-not $wslCmd) {
        throw "No native RISC-V toolchain and WSL is not installed."
    }
    if (-not (Test-WslToolchain)) {
        throw "WSL is present but riscv64-unknown-elf-gcc/make not found in WSL."
    }

    Write-Host "Using WSL RISC-V toolchain fallback."
    $fwDirWsl = Convert-ToWslPath $fwDir
    & wsl bash -lc "cd '$fwDirWsl' && make clean all PYTHON=python3"
    if ($LASTEXITCODE -ne 0) {
        throw "WSL firmware build failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Generator {
    param(
        [string]$CaseName,
        [string]$MetaOutPath
    )

    if (-not (Test-Path $CasesFile)) {
        throw "Cases file not found: $CasesFile"
    }

    $pythonExe = Get-PythonExe
    if ([System.IO.Path]::GetFileName($pythonExe).ToLowerInvariant() -eq "py.exe") {
        & $pythonExe -3 $generator --cases $CasesFile --case $CaseName --firmware-out $firmwareS --meta-out $MetaOutPath
    } else {
        & $pythonExe $generator --cases $CasesFile --case $CaseName --firmware-out $firmwareS --meta-out $MetaOutPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Firmware generator failed for case '$CaseName' with exit code $LASTEXITCODE"
    }
}

New-Item -ItemType Directory -Force $resultsDir | Out-Null
New-Item -ItemType Directory -Force $customResultsDir | Out-Null
Acquire-FlowLock -Path $flowLockPath

$sources = @(
    (Join-Path $repoRoot "picorv32\picorv32.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\pe_cell_q5_10.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\issue_logic_4x4_q5_10.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\systolic_array_4x4_q5_10.v"),
    (Join-Path $repoRoot "midsem_sim\rtl\matrix_accel_4x4_q5_10.v"),
    (Join-Path $demoDir "rtl\pcpi_tinyml_accel.v"),
    (Join-Path $tbDir "tb_picorv32_pcpi_tinyml.v")
)

Write-Host "Compiling simulation binary..."
& iverilog -g2012 -o $simExe @sources
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Generating firmware for case: $CaseName"
Invoke-Generator -CaseName $CaseName -MetaOutPath $caseMeta
Build-Firmware

Write-Host "Running custom case simulation..."
& vvp $simExe "+CASE_NAME=$CaseName" | Tee-Object -FilePath $caseLog | Out-Host
$simExit = $LASTEXITCODE
$logText = Get-Content -Raw -Path $caseLog

$hasCustomPass = $logText -match "TB_PASS custom instruction result write:"
$hasBufferPass = $logText -match "TB_PASS C-buffer verification for all 16 elements\."
$hasFinalPass = $logText -match "TB_PASS integration pcpi demo complete\."
if (($simExit -ne 0) -or -not $hasCustomPass -or -not $hasBufferPass -or -not $hasFinalPass) {
    throw "Custom case simulation failed. Check log: $caseLog"
}

Write-Host "Custom case PASS."
Write-Host "Case: $CaseName"
Write-Host "Cases file: $CasesFile"
Write-Host "Log: $caseLog"
Write-Host "Expected metadata: $caseMeta"
Write-Host "Waveform: integration/pcpi_demo/results/pcpi_demo_wave.vcd"
