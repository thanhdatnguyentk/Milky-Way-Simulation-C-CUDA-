# Phase 0 Analysis Utilities
# Compute energy drift and center-of-mass drift from simulation snapshots.

param(
    [string]$OutputDir = "output"
)

$ErrorActionPreference = "Stop"

function Read-Snapshot {
    param([string]$FilePath)

    if (!(Test-Path $FilePath)) {
        return $null
    }

    $rows = Import-Csv -Path $FilePath
    return ,$rows
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

function Get-SampledBodies {
    param(
        [object[]]$Bodies,
        [int]$MaxSamples = 2000
    )

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

function Compute-PotentialEnergy {
    param(
        [object[]]$Bodies,
        [double]$G = 1.0,
        [double]$SofteningSq = 0.01,
        [int]$MaxSamples = 2000
    )

    $sample = Get-SampledBodies -Bodies $Bodies -MaxSamples $MaxSamples
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

    return @{
        Value = $pe
        SampleCount = $sample.Count
        TotalCount = $Bodies.Count
    }
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

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 0 Analysis Utilities" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$stepFiles = Get-ChildItem -Path (Join-Path $OutputDir "step_*.csv") -ErrorAction SilentlyContinue |
    Sort-Object { [int]($_.Name -replace 'step_(\d+)\.csv', '$1') }

if ($stepFiles.Count -lt 2) {
    Write-Host "[WARN] Need at least 2 step snapshots for drift analysis" -ForegroundColor Yellow
    exit 0
}

$first = Read-Snapshot -FilePath $stepFiles[0].FullName
$last = Read-Snapshot -FilePath $stepFiles[-1].FullName

if ($null -eq $first -or $null -eq $last) {
    Write-Host "[WARN] Could not read snapshots for drift analysis" -ForegroundColor Yellow
    exit 0
}

$ke0 = Compute-KineticEnergy -Bodies $first
$pe0r = Compute-PotentialEnergy -Bodies $first
$e0 = $ke0 + $pe0r.Value

$ke1 = Compute-KineticEnergy -Bodies $last
$pe1r = Compute-PotentialEnergy -Bodies $last
$e1 = $ke1 + $pe1r.Value

$com0 = Compute-CenterOfMass -Bodies $first
$com1 = Compute-CenterOfMass -Bodies $last

$de = $e1 - $e0
$deRelPct = if ([Math]::Abs($e0) -gt 1e-12) { 100.0 * $de / [Math]::Abs($e0) } else { 0.0 }
$dcx = $com1.X - $com0.X
$dcy = $com1.Y - $com0.Y
$dcz = $com1.Z - $com0.Z
$dcom = [Math]::Sqrt($dcx * $dcx + $dcy * $dcy + $dcz * $dcz)

Write-Host "Energy Analysis:" -ForegroundColor Cyan
if ($pe0r.SampleCount -lt $pe0r.TotalCount) {
    Write-Host "  Potential energy sampled: $($pe0r.SampleCount)/$($pe0r.TotalCount) bodies" -ForegroundColor Yellow
}
Write-Host "  Initial E: $([Math]::Round($e0, 3))" -ForegroundColor White
Write-Host "  Final E:   $([Math]::Round($e1, 3))" -ForegroundColor White
Write-Host "  Delta E:   $([Math]::Round($de, 3))" -ForegroundColor Yellow
Write-Host "  Delta E%:  $([Math]::Round($deRelPct, 6))%" -ForegroundColor Yellow
Write-Host ""
Write-Host "Center of Mass Drift:" -ForegroundColor Cyan
Write-Host "  Drift distance: $([Math]::Round($dcom, 6))" -ForegroundColor Yellow
Write-Host ""
Write-Host "[NOTE] Phase 0 baseline uses Forward Euler integrator" -ForegroundColor Yellow
