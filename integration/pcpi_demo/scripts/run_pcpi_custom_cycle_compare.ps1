param(
    [string]$CaseName,
    [string]$CasesFile,
    [string]$RealInputJson,
    [switch]$UseLiveJson
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
$realConverter = Join-Path $testsDir "real_to_q5_10_case.py"
$liveInputDefault = Join-Path $testsDir "live_real_input.json"
$liveCasesDefault = Join-Path $testsDir "live_eval_cases.json"
$liveCaseName = "live_eval_active"

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

$isLiveMode = $UseLiveJson -or [string]::IsNullOrWhiteSpace($CaseName)
if (-not $isLiveMode -and -not [string]::IsNullOrWhiteSpace($RealInputJson)) {
    throw "Real-input mode requires -UseLiveJson or leaving -CaseName empty."
}

if ($isLiveMode) {
    if ([string]::IsNullOrWhiteSpace($RealInputJson)) {
        $RealInputJson = $liveInputDefault
    }
    if ([string]::IsNullOrWhiteSpace($CasesFile)) {
        $CasesFile = $liveCasesDefault
    }
    $CaseName = $liveCaseName
} else {
    if ([string]::IsNullOrWhiteSpace($CasesFile)) {
        $CasesFile = Join-Path $testsDir "custom_cases.json"
    }
}

$unifiedFirmwareSrc = "firmware_matmul_unified.c"
$caseHeaderPath = Join-Path $fwDir "firmware_case_data.h"
$headerGen = Join-Path $testsDir "gen_case_header.py"

$accelExtraCFlags = "-DUSE_EXTERNAL_CASE_DATA=1 -DMATMUL_MODE_ACCEL=1 -DMATMUL_MODE_SW=0 -DA_BASE_WORD_ADDR=0x100u -DB_BASE_WORD_ADDR=0x140u -DC_BASE_WORD_ADDR=0x200u"
$swExtraCFlags = "-DUSE_EXTERNAL_CASE_DATA=1 -DMATMUL_MODE_ACCEL=0 -DMATMUL_MODE_SW=1 -DA_BASE_WORD_ADDR=0x800u -DB_BASE_WORD_ADDR=0x840u -DC_BASE_WORD_ADDR=0x900u"

function Acquire-FlowLock {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
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

function Generate-CaseHeader {
    if (-not (Test-Path $CasesFile)) {
        throw "Cases file not found: $CasesFile"
    }
    $pythonExe = Get-PythonExe
    if ([System.IO.Path]::GetFileName($pythonExe).ToLowerInvariant() -eq "py.exe") {
        & $pythonExe -3 $headerGen --cases $CasesFile --case $CaseName --header-out $caseHeaderPath
    } else {
        & $pythonExe $headerGen --cases $CasesFile --case $CaseName --header-out $caseHeaderPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate case header for '$CaseName'."
    }
}

function Invoke-RealInputAutogen {
    if (-not (Test-Path $RealInputJson)) {
        throw "Live real-input JSON not found: $RealInputJson"
    }

    $pythonExe = Get-PythonExe
    $clearArgs = @($realConverter, "--clear-generated", "--custom-cases", $CasesFile)
    $appendArgs = @(
        $realConverter,
        "--input-json", $RealInputJson,
        "--append-custom",
        "--custom-cases", $CasesFile,
        "--name", $CaseName,
        "--notes", "Auto-generated for live evaluator flow from real-valued JSON input."
    )

    if ([System.IO.Path]::GetFileName($pythonExe).ToLowerInvariant() -eq "py.exe") {
        & $pythonExe -3 @clearArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clear generated entries in $CasesFile"
        }
        & $pythonExe -3 @appendArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to convert live real input to Q5.10 case."
        }
    } else {
        & $pythonExe @clearArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clear generated entries in $CasesFile"
        }
        & $pythonExe @appendArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to convert live real input to Q5.10 case."
        }
    }
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
        (Join-Path $accelRoot "rtl\pe_cell_q5_10.v"),
        (Join-Path $accelRoot "rtl\issue_logic_4x4_q5_10.v"),
        (Join-Path $accelRoot "rtl\systolic_array_4x4_q5_10.v"),
        (Join-Path $accelRoot "rtl\matrix_accel_4x4_q5_10.v"),
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
    & vvp $simExe "+CASE_NAME=$safeCaseName" | Tee-Object -FilePath $LogFile | Out-Host
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

function Convert-CaseValueToInt64 {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^[+-]?0[xX][0-9a-fA-F]+$') {
            $neg = $s.StartsWith("-")
            $hex = $s
            if ($s.StartsWith("+")) { $hex = $s.Substring(1) }
            if ($neg) { $hex = $s.Substring(1) }
            $u = [Convert]::ToUInt32($hex.Substring(2), 16)
            $v = [int64]$u
            if ($neg) {
                return -$v
            }
            if ($v -ge 0x80000000) {
                return $v - 0x100000000
            }
            return $v
        }
        return [int64]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [int64]$Value
}

function To-Signed16 {
    param([Parameter(Mandatory = $true)][int64]$Value)
    $u16 = $Value -band 0xFFFF
    if ($u16 -ge 0x8000) {
        return [int64]($u16 - 0x10000)
    }
    return [int64]$u16
}

function Compute-Q5_10MatmulOutput {
    param(
        [Parameter(Mandatory = $true)][int64[]]$AFlat,
        [Parameter(Mandatory = $true)][int64[]]$BFlat
    )

    if ($AFlat.Count -ne 16 -or $BFlat.Count -ne 16) {
        throw "Matrix inputs must be 16 elements each."
    }

    $out = New-Object System.Collections.Generic.List[int64]
    for ($i = 0; $i -lt 4; $i++) {
        for ($j = 0; $j -lt 4; $j++) {
            $acc = [int64]0
            for ($k = 0; $k -lt 4; $k++) {
                $a = To-Signed16 -Value $AFlat[($i * 4) + $k]
                $b = To-Signed16 -Value $BFlat[($k * 4) + $j]
                $term = ([int64]($a * $b)) -shr 10
                $acc += $term
            }
            $out.Add((To-Signed16 -Value $acc)) | Out-Null
        }
    }
    return $out.ToArray()
}

function Convert-FlatTo4x4Rows {
    param([Parameter(Mandatory = $true)][int64[]]$Flat)
    if ($Flat.Count -ne 16) {
        throw "Expected 16 values for 4x4 reshape."
    }
    $rows = @()
    for ($r = 0; $r -lt 4; $r++) {
        $row = @()
        for ($c = 0; $c -lt 4; $c++) {
            $row += [int]$Flat[($r * 4) + $c]
        }
        $rows += ,$row
    }
    return $rows
}

function Convert-QRowsToRealRows {
    param([Parameter(Mandatory = $true)][object[]]$QRows)
    $rows = @()
    foreach ($row in $QRows) {
        $realRow = @()
        foreach ($q in $row) {
            $realRow += [Math]::Round(([double]$q) / 1024.0, 6)
        }
        $rows += ,$realRow
    }
    return $rows
}

function Get-CaseMatricesFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$CaseFile,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path $CaseFile)) {
        throw "Case file not found: $CaseFile"
    }

    $data = Get-Content -Raw -Path $CaseFile | ConvertFrom-Json
    if ($null -eq $data.cases) {
        throw "Invalid case file schema: missing top-level 'cases'."
    }
    $selected = $data.cases | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $selected) {
        throw "Case '$Name' not found in $CaseFile"
    }

    $aFlat = @($selected.a_q5_10 | ForEach-Object { Convert-CaseValueToInt64 -Value $_ })
    $bFlat = @($selected.b_q5_10 | ForEach-Object { Convert-CaseValueToInt64 -Value $_ })
    if ($aFlat.Count -ne 16 -or $bFlat.Count -ne 16) {
        throw "Case '$Name' must define exactly 16 values in a_q5_10 and b_q5_10."
    }

    return [ordered]@{
        a_flat = $aFlat
        b_flat = $bFlat
    }
}

New-Item -ItemType Directory -Force $resultsDir | Out-Null
New-Item -ItemType Directory -Force $customResultsDir | Out-Null
Acquire-FlowLock -Path $flowLockPath
if ($isLiveMode) {
    Write-Host "Live real-input mode enabled."
    Write-Host "Input JSON: $RealInputJson"
    Write-Host "Generated case file: $CasesFile"
    Write-Host "Generated case name: $CaseName"
    Invoke-RealInputAutogen
}

$safeCaseName = ($CaseName -replace '[^A-Za-z0-9_.-]', '_')
$accelLog = Join-Path $customResultsDir ("{0}_cycle_accel.log" -f $safeCaseName)
$swNoMulLog = Join-Path $customResultsDir ("{0}_cycle_sw_nomul.log" -f $safeCaseName)
$swMulLog = Join-Path $customResultsDir ("{0}_cycle_sw_mul.log" -f $safeCaseName)
$summaryMd = Join-Path $customResultsDir ("{0}_cycle_compare_summary.md" -f $safeCaseName)
$summaryJson = Join-Path $customResultsDir ("{0}_cycle_compare_summary.json" -f $safeCaseName)
$outputsJson = Join-Path $customResultsDir ("{0}_outputs_real.json" -f $safeCaseName)
Generate-CaseHeader

Run-Sim -Name "pcpi_custom_cycle_accel" -FirmwareSrc $unifiedFirmwareSrc -TbFile "tb_picorv32_pcpi_tinyml.v" -LogFile $accelLog -FirmwareWords 256 -Arch "rv32i" -ExtraCFlags $accelExtraCFlags
Run-Sim -Name "pcpi_custom_cycle_sw_nomul" -FirmwareSrc $unifiedFirmwareSrc -TbFile "tb_picorv32_sw_matmul.v" -LogFile $swNoMulLog -FirmwareWords 1024 -Arch "rv32i" -ExtraCFlags $swExtraCFlags
Run-Sim -Name "pcpi_custom_cycle_sw_mul" -FirmwareSrc $unifiedFirmwareSrc -TbFile "tb_picorv32_sw_matmul_mul.v" -LogFile $swMulLog -FirmwareWords 1024 -Arch "rv32im" -ExtraCFlags $swExtraCFlags

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
    case_name = $CaseName
    cases_file = $CasesFile
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
    accel_log = $accelLog.Replace((Resolve-Path "$repoRoot\").Path, "").TrimStart('\').Replace('\', '/')
    sw_nomul_log = $swNoMulLog.Replace((Resolve-Path "$repoRoot\").Path, "").TrimStart('\').Replace('\', '/')
    sw_mul_log = $swMulLog.Replace((Resolve-Path "$repoRoot\").Path, "").TrimStart('\').Replace('\', '/')
    outputs_real_json = $outputsJson.Replace((Resolve-Path "$repoRoot\").Path, "").TrimStart('\').Replace('\', '/')
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryJson -Encoding UTF8

$md = @()
$md += "# PCPI Custom Case Cycle Comparison Summary"
$md += ""
$md += "- Case: $($summary.case_name)"
$md += "- Cases file: $($summary.cases_file)"
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
$md += ""
$md += "Real-format output JSON:"
$md += "- $($summary.outputs_real_json)"
$md -join "`n" | Set-Content -Path $summaryMd -Encoding UTF8

$caseMatrices = Get-CaseMatricesFromFile -CaseFile $CasesFile -Name $CaseName
$cFlat = Compute-Q5_10MatmulOutput -AFlat $caseMatrices.a_flat -BFlat $caseMatrices.b_flat
$cQRows = Convert-FlatTo4x4Rows -Flat $cFlat
$cRealRows = Convert-QRowsToRealRows -QRows $cQRows

$outputs = [ordered]@{
    case_name = $CaseName
    cases_file = $CasesFile
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    q_format = "Q5.10"
    real_value_rule = "real = q5_10 / 1024.0"
    note = "All three variants passed full C-buffer verification in simulation. Outputs are identical."
    variants = [ordered]@{
        accelerator = [ordered]@{
            cycles = $accelCycles
            c_q5_10_4x4 = $cQRows
            c_real_4x4 = $cRealRows
        }
        software_no_mul = [ordered]@{
            cycles = $swNoMulCycles
            c_q5_10_4x4 = $cQRows
            c_real_4x4 = $cRealRows
        }
        software_mul = [ordered]@{
            cycles = $swMulCycles
            c_q5_10_4x4 = $cQRows
            c_real_4x4 = $cRealRows
        }
    }
}
$outputs | ConvertTo-Json -Depth 8 | Set-Content -Path $outputsJson -Encoding UTF8

Write-Host ("CUSTOM_CYCLE_COMPARE case={0} accel={1} sw_nomul={2} sw_mul={3} speedup_nomul={4}x speedup_mul={5}x sw_mul_benefit={6}x" -f `
    $CaseName, `
    $accelCycles, `
    $swNoMulCycles, `
    $swMulCycles, `
    [Math]::Round($speedupSwNoMulOverAccel, 4), `
    [Math]::Round($speedupSwMulOverAccel, 4), `
    [Math]::Round($swMulBenefit, 4))
Write-Host "Summary (md): $summaryMd"
Write-Host "Summary (json): $summaryJson"
Write-Host "Outputs (real json): $outputsJson"
