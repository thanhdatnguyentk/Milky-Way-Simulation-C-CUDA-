# Phase 1.5 - Integrator Drift Comparison (Euler vs Leapfrog)
# Runs identical scenarios and compares relative energy drift + center-of-mass drift.

param(
    [string]$SimExePath = "simulation_gpu.exe",
    [int]$NumBodies = 512,
    [int]$NumSteps = 1000,
    [double]$Dt = 0.01,
    [int]$OutputInterval = 100,
    [string]$Backend = "gpu",
    [int]$RenderWidth = 320,
    [int]$RenderHeight = 180,
    [string]$OutputDir = "data"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$resolvedExePath = if ([System.IO.Path]::IsPathRooted($SimExePath)) { $SimExePath } else { Join-Path $projectRoot $SimExePath }

if (!(Test-Path $resolvedExePath)) {
    throw "Cannot find simulation executable: $resolvedExePath"
}

if (!(Test-Path (Join-Path $projectRoot $OutputDir))) {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot $OutputDir) -Force | Out-Null
}

function Get-StepFiles {
    param([string]$OutputFolder)

    return Get-ChildItem -Path (Join-Path $OutputFolder "step_*.csv") -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.BaseName -replace "step_", "") }
}

function Read-Snapshot {
    param([string]$Path)
    return @(Import-Csv -Path $Path)
}

function Get-SampledBodies {
    param([object[]]$Bodies, [int]$MaxSamples = 2000)

    if ($Bodies.Count -le $MaxSamples) {
        return ,$Bodies
    }

    $step = [Math]::Ceiling($Bodies.Count / [double]$MaxSamples)
    $sample = @()
    for ($i = 0; $i -lt $Bodies.Count; $i += $step) {
        $sample += $Bodies[$i]
    }
    return ,$sample
}

function Compute-KineticEnergy {
    param([object[]]$Bodies)

    $ke = 0.0
    foreach ($b in $Bodies) {
        $m = [double]$b.mass
        $vx = [double]$b.vx
        $vy = [double]$b.vy
        $vz = [double]$b.vz
        $ke += 0.5 * $m * ($vx * $vx + $vy * $vy + $vz * $vz)
    }
    return $ke
}

function Compute-PotentialEnergy {
    param([object[]]$Bodies, [double]$G = 1.0, [double]$SofteningSq = 0.01)

    $sample = Get-SampledBodies -Bodies $Bodies -MaxSamples 2000
    $pe = 0.0

    for ($i = 0; $i -lt $sample.Count; $i++) {
        for ($j = $i + 1; $j -lt $sample.Count; $j++) {
            $dx = [double]$sample[$i].x - [double]$sample[$j].x
            $dy = [double]$sample[$i].y - [double]$sample[$j].y
            $dz = [double]$sample[$i].z - [double]$sample[$j].z
            $r = [Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz + $SofteningSq)
            $pe -= $G * [double]$sample[$i].mass * [double]$sample[$j].mass / $r
        }
    }

    return @{ Value = $pe; SampleCount = $sample.Count; TotalCount = $Bodies.Count }
}

function Compute-CenterOfMass {
    param([object[]]$Bodies)

    $mass = 0.0
    $cx = 0.0
    $cy = 0.0
    $cz = 0.0

    foreach ($b in $Bodies) {
        $m = [double]$b.mass
        $mass += $m
        $cx += $m * [double]$b.x
        $cy += $m * [double]$b.y
        $cz += $m * [double]$b.z
    }

    return @{
        X = $cx / [Math]::Max($mass, 1e-12)
        Y = $cy / [Math]::Max($mass, 1e-12)
        Z = $cz / [Math]::Max($mass, 1e-12)
    }
}

function Analyze-Run {
    param([string]$OutputFolder)

    $stepFiles = Get-StepFiles -OutputFolder $OutputFolder
    if ($stepFiles.Count -lt 2) {
        throw "Need at least two step snapshots for analysis."
    }

    $first = Read-Snapshot -Path $stepFiles[0].FullName
    $last = Read-Snapshot -Path $stepFiles[-1].FullName

    $ke0 = Compute-KineticEnergy -Bodies $first
    $pe0 = Compute-PotentialEnergy -Bodies $first
    $e0 = $ke0 + $pe0.Value

    $ke1 = Compute-KineticEnergy -Bodies $last
    $pe1 = Compute-PotentialEnergy -Bodies $last
    $e1 = $ke1 + $pe1.Value

    $com0 = Compute-CenterOfMass -Bodies $first
    $com1 = Compute-CenterOfMass -Bodies $last

    $de = $e1 - $e0
    $deRelPct = if ([Math]::Abs($e0) -gt 1e-12) { 100.0 * $de / [Math]::Abs($e0) } else { 0.0 }

    $dcx = $com1.X - $com0.X
    $dcy = $com1.Y - $com0.Y
    $dcz = $com1.Z - $com0.Z
    $dcom = [Math]::Sqrt($dcx * $dcx + $dcy * $dcy + $dcz * $dcz)

    return @{
        InitialEnergy = $e0
        FinalEnergy = $e1
        DeltaEnergy = $de
        DeltaEnergyPercent = $deRelPct
        CenterOfMassDrift = $dcom
        SampleCount = $pe0.SampleCount
        TotalCount = $pe0.TotalCount
        FirstSnapshot = $stepFiles[0].Name
        LastSnapshot = $stepFiles[-1].Name
    }
}

function Run-Scenario {
    param([string]$Integrator)

    Write-Host "[RUN] Integrator: $Integrator" -ForegroundColor Yellow

    Push-Location $projectRoot
    try {
        & $resolvedExePath `
            $NumBodies `
            $NumSteps `
            $Dt `
            $OutputInterval `
            $Backend `
            0 `
            $RenderWidth `
            $RenderHeight `
            70 `
            1.2 `
            2.2 `
            default `
            --clear-output `
            --render-mode raster `
            --integrator $Integrator *> $null

        if ($LASTEXITCODE -ne 0) {
            throw "Simulation failed for integrator=$Integrator with exit code $LASTEXITCODE"
        }

        return Analyze-Run -OutputFolder (Join-Path $projectRoot "output")
    }
    finally {
        Pop-Location
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 1.5: Integrator Drift Comparison" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "NumBodies=$NumBodies NumSteps=$NumSteps dt=$Dt backend=$Backend" -ForegroundColor Cyan
Write-Host ""

$euler = Run-Scenario -Integrator "euler"
$leapfrog = Run-Scenario -Integrator "leapfrog"

$improvement = if ([Math]::Abs($leapfrog.DeltaEnergyPercent) -gt 1e-12) {
    [Math]::Abs($euler.DeltaEnergyPercent) / [Math]::Abs($leapfrog.DeltaEnergyPercent)
} else {
    [double]::PositiveInfinity
}

$reportPath = Join-Path $projectRoot $OutputDir
$reportFile = Join-Path $reportPath "phase1_integrator_comparison.md"
$jsonFile = Join-Path $reportPath "phase1_integrator_comparison.json"

$report = @"
# Phase 1.5 Integrator Comparison

- Timestamp: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
- Configuration: N=$NumBodies, steps=$NumSteps, dt=$Dt, backend=$Backend
- Potential-energy sampling: $($euler.SampleCount)/$($euler.TotalCount) bodies

| Metric | Euler | Leapfrog |
|---|---:|---:|
| Delta Energy (%) | $([Math]::Round($euler.DeltaEnergyPercent, 6)) | $([Math]::Round($leapfrog.DeltaEnergyPercent, 6)) |
| Center of Mass Drift | $([Math]::Round($euler.CenterOfMassDrift, 6)) | $([Math]::Round($leapfrog.CenterOfMassDrift, 6)) |
| Initial Energy | $([Math]::Round($euler.InitialEnergy, 3)) | $([Math]::Round($leapfrog.InitialEnergy, 3)) |
| Final Energy | $([Math]::Round($euler.FinalEnergy, 3)) | $([Math]::Round($leapfrog.FinalEnergy, 3)) |

## Relative Improvement

- Energy-drift reduction factor (Euler vs Leapfrog): $([Math]::Round($improvement, 3))x

## Notes

- Lower absolute Delta Energy (%) is better.
- Lower Center of Mass Drift is better.
- This comparison uses the same run configuration for both integrators.
"@

Set-Content -Path $reportFile -Value $report -Encoding UTF8

@{
    timestamp = (Get-Date -Format "s")
    configuration = @{
        numBodies = $NumBodies
        numSteps = $NumSteps
        dt = $Dt
        backend = $Backend
    }
    euler = $euler
    leapfrog = $leapfrog
    energyDriftImprovementFactor = $improvement
} | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonFile -Encoding UTF8

Write-Host ""
Write-Host "[OK] Report: $reportFile" -ForegroundColor Green
Write-Host "[OK] JSON  : $jsonFile" -ForegroundColor Green
Write-Host "[OK] Drift improvement factor: $([Math]::Round($improvement, 3))x" -ForegroundColor Green
