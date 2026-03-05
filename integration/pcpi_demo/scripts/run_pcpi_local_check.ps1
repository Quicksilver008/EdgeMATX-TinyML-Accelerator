Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$demoScript = Join-Path $scriptDir "run_pcpi_demo.ps1"
$regressionScript = Join-Path $scriptDir "run_pcpi_regression.ps1"
$handoffScript = Join-Path $scriptDir "run_pcpi_handoff.ps1"

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Body
    )
    Write-Host "=== $Name ==="
    & $Body
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
    Write-Host "PASS: $Name"
}

Invoke-Step -Name "smoke-asm" -Body {
    powershell -ExecutionPolicy Bypass -File $demoScript -FirmwareVariant asm
}

Invoke-Step -Name "smoke-c" -Body {
    powershell -ExecutionPolicy Bypass -File $demoScript -FirmwareVariant c
}

Invoke-Step -Name "regression-8case" -Body {
    powershell -ExecutionPolicy Bypass -File $regressionScript
}

Invoke-Step -Name "handoff" -Body {
    powershell -ExecutionPolicy Bypass -File $handoffScript
}

Write-Host "LOCAL_CHECK PASS: smoke-asm, smoke-c, regression-8case, handoff"
