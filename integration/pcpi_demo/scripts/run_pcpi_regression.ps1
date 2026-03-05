Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoDir = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $demoDir)
$fwDir = Join-Path $demoDir "firmware"
$tbDir = Join-Path $demoDir "tb"
$testsDir = Join-Path $demoDir "tests"
$resultsDir = Join-Path $demoDir "results"
$caseResultsDir = Join-Path $resultsDir "cases"

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

$casesFile = Join-Path $testsDir "cases.json"
$generator = Join-Path $testsDir "gen_case_firmware.py"
$firmwareS = Join-Path $fwDir "firmware.S"
$simExe = Join-Path $resultsDir "pcpi_demo_tb.out"
$summaryMd = Join-Path $resultsDir "pcpi_regression_summary.md"
$summaryJson = Join-Path $resultsDir "pcpi_regression_summary.json"

New-Item -ItemType Directory -Force $resultsDir | Out-Null
New-Item -ItemType Directory -Force $caseResultsDir | Out-Null

function Get-PythonExe {
    $candidates = @("python", "py")
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "Python interpreter not found. Install Python to run regression generator."
}

function Invoke-Generator {
    param(
        [string]$CaseName,
        [string]$MetaOutPath
    )

    $pythonExe = Get-PythonExe
    if ([System.IO.Path]::GetFileName($pythonExe).ToLowerInvariant() -eq "py.exe") {
        & $pythonExe -3 $generator --cases $casesFile --case $CaseName --firmware-out $firmwareS --meta-out $MetaOutPath
    } else {
        & $pythonExe $generator --cases $casesFile --case $CaseName --firmware-out $firmwareS --meta-out $MetaOutPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Firmware generator failed for case '$CaseName' with exit code $LASTEXITCODE"
    }
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

$sources = @(
    (Join-Path $repoRoot "picorv32\picorv32.v"),
    (Join-Path $accelRoot "rtl\pe_cell_q5_10.v"),
    (Join-Path $accelRoot "rtl\issue_logic_4x4_q5_10.v"),
    (Join-Path $accelRoot "rtl\systolic_array_4x4_q5_10.v"),
    (Join-Path $accelRoot "rtl\matrix_accel_4x4_q5_10.v"),
    (Join-Path $demoDir "rtl\pcpi_tinyml_accel.v"),
    (Join-Path $tbDir "tb_picorv32_pcpi_tinyml.v")
)

Write-Host "Compiling simulation binary..."
& iverilog -g2012 -o $simExe @sources
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed with exit code $LASTEXITCODE"
}

$caseData = Get-Content -Raw -Path $casesFile | ConvertFrom-Json
$cases = @($caseData.cases)
if ($cases.Count -eq 0) {
    throw "No cases found in $casesFile"
}

$results = @()
foreach ($case in $cases) {
    $caseName = [string]$case.name
    if ([string]::IsNullOrWhiteSpace($caseName)) {
        throw "Encountered case with empty name in $casesFile"
    }

    Write-Host "=== Running case: $caseName ==="
    $caseLog = Join-Path $caseResultsDir "$caseName.log"
    $caseMeta = Join-Path $caseResultsDir "$caseName.expected.json"

    Invoke-Generator -CaseName $caseName -MetaOutPath $caseMeta
    Build-Firmware

    & vvp $simExe "+CASE_NAME=$caseName" | Tee-Object -FilePath $caseLog | Out-Host
    $simExit = $LASTEXITCODE
    $logText = Get-Content -Raw -Path $caseLog

    $hasCustomPass = $logText -match "TB_PASS custom instruction result write:"
    $hasBufferPass = $logText -match "TB_PASS C-buffer verification for all 16 elements\."
    $hasFinalPass = $logText -match "TB_PASS integration pcpi demo complete\."
    $status = if (($simExit -eq 0) -and $hasCustomPass -and $hasBufferPass -and $hasFinalPass) { "PASS" } else { "FAIL" }

    $c00 = ""
    if ($logText -match "TB_PASS custom instruction result write:\s*(0x[0-9a-fA-F]+)") {
        $c00 = $Matches[1].ToLowerInvariant()
    }

    $failureDetail = ""
    if ($status -eq "FAIL") {
        if ($logText -match "TB_FAIL C-buffer mismatch idx=(\d+)\s+got=(0x[0-9a-fA-F]+)\s+expected=(0x[0-9a-fA-F]+)") {
            $failureDetail = "idx=$($Matches[1]) got=$($Matches[2].ToLowerInvariant()) expected=$($Matches[3].ToLowerInvariant())"
        } elseif ($logText -match "TB_FAIL wrong result write:\s+got=(0x[0-9a-fA-F]+)\s+expected=(0x[0-9a-fA-F]+)") {
            $failureDetail = "result_write got=$($Matches[1].ToLowerInvariant()) expected=$($Matches[2].ToLowerInvariant())"
        } else {
            $failureDetail = "simulation_error_or_timeout"
        }
    }

    $expectedC00 = ""
    if (Test-Path $caseMeta) {
        $metaData = Get-Content -Raw -Path $caseMeta | ConvertFrom-Json
        $expectedC00 = [string]$metaData.expected_c00_u32_hex
    }

    $results += [ordered]@{
        name = $caseName
        status = $status
        expected_c00 = $expectedC00
        observed_c00 = $c00
        log = "integration/pcpi_demo/results/cases/$caseName.log"
        failure_detail = $failureDetail
    }
}

$passCount = ($results | Where-Object { $_.status -eq "PASS" }).Count
$failCount = $results.Count - $passCount
$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    total = $results.Count
    pass = $passCount
    fail = $failCount
    cases = $results
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryJson -Encoding UTF8

$mdLines = @()
$mdLines += "# PCPI Regression Summary"
$mdLines += ""
$mdLines += "- Generated (UTC): $($summary.generated_at_utc)"
$mdLines += "- Total: $($summary.total)"
$mdLines += "- Pass: $($summary.pass)"
$mdLines += "- Fail: $($summary.fail)"
$mdLines += ""
$mdLines += "| Case | Status | Expected c00 | Observed c00 | Notes |"
$mdLines += "| --- | --- | --- | --- | --- |"
foreach ($item in $results) {
    $notes = if ($item.status -eq "PASS") { "ok" } else { $item.failure_detail }
    $mdLines += "| $($item.name) | $($item.status) | $($item.expected_c00) | $($item.observed_c00) | $notes |"
}
$mdLines += ""
$mdLines += "Logs: integration/pcpi_demo/results/cases/*.log"
$mdLines -join "`n" | Set-Content -Path $summaryMd -Encoding UTF8

Write-Host "Regression summary (md): $summaryMd"
Write-Host "Regression summary (json): $summaryJson"

if ($failCount -gt 0) {
    throw "$failCount regression case(s) failed."
}

Write-Host "All regression cases passed."
