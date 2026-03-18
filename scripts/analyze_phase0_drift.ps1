# Phase 0 Analysis Utilities
# Compute force error, energy drift, momentum drift from simulation snapshots

param(
    [string]$OutputDir = "output",
    [string]$DataDir = "data"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 0 Analysis Utilities" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Function to read CSV snapshot
function Read-Snapshot {
    param([string]$FilePath)
    
    if (!(Test-Path $FilePath)) {
        return $null
    }
    
    $lines = @(Get-Content $FilePath)
    $header = $lines[0] -split ','
    $bodies = @()
    
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $fields = $lines[$i] -split ','
        $body = @{}
        
        for ($j = 0; $j -lt $header.Count; $j++) {
            $key = $header[$j].Trim()
            $value = $fields[$j].Trim()
            
            if ($key -match '^(mass|x|y|z|vx|vy|vz|ax|ay|az|radius)$') {
                [void]($value -as [double])
                $body[$key] = [double]$value
            }
        }
        
        if ($body.Count -gt 0) {
            $bodies += $body
        }
    }
    
    return $bodies
}

# Function to compute kinetic energy
function Compute-KineticEnergy {
    param([object[]]$Bodies)
    
    $KE = 0.0
    foreach ($body in $Bodies) {
        if ($body.mass -gt 0) {
            $v_sq = $body.vx * $body.vx + $body.vy * $body.vy + $body.vz * $body.vz
            $KE += 0.5 * $body.mass * $v_sq
        }
    }
    return $KE
}

# Function to compute potential energy (softened)
function Compute-PotentialEnergy {
    param([object[]]$Bodies)
    
    $G = 1.0
    $softening_sq = 0.01
    $PE = 0.0
    
    for ($i = 0; $i -lt $Bodies.Count; $i++) {
        for ($j = $i + 1; $j -lt $Bodies.Count; $j++) {
            $dx = $Bodies[$i].x - $Bodies[$j].x
            $dy = $Bodies[$i].y - $Bodies[$j].y
            $dz = $Bodies[$i].z - $Bodies[$j].z
            
            $r_sq = $dx * $dx + $dy * $dy + $dz * $dz + $softening_sq
            $r = [math]::Sqrt($r_sq)
            
            $PE -= $G * $Bodies[$i].mass * $Bodies[$j].mass / $r
        }
    }
    return $PE
}

# Function to compute center of mass
function Compute-CenterOfMass {
    param([object[]]$Bodies)
    
    $total_mass = 0.0
    $com_x = $com_y = $com_z = 0.0
    
    foreach ($body in $Bodies) {
        $total_mass += $body.mass
        $com_x += $body.mass * $body.x
        $com_y += $body.mass * $body.y
        $com_z += $body.mass * $body.z
    }
    
    return @{
        X    = $com_x / $total_mass
        Y    = $com_y / $total_mass
        Z    = $com_z / $total_mass
        Mass = $total_mass
    }
}

# Analyze energy and momentum drift
Write-Host "Analyzing energy and momentum drift..." -ForegroundColor Yellow
Write-Host ""

$snapshots = @()
$stepFiles = Get-ChildItem -Path (Join-Path $OutputDir "step_*.csv") -ErrorAction SilentlyContinue | 
    Sort-Object { [int]($_.Name -replace 'step_(\d+)\.csv', '$1') }

if ($stepFiles.Count -lt 2) {
    Write-Host "⚠ Insufficient snapshots for drift analysis (need at least 2)" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($stepFiles.Count) snapshots" -ForegroundColor Cyan
Write-Host ""

# Compute metrics for first and last snapshot
$firstSnapshot = Read-Snapshot -FilePath $stepFiles[0].FullName
$lastSnapshot = Read-Snapshot -FilePath $stepFiles[-1].FullName

if ($firstSnapshot -and $lastSnapshot) {
    $KE_initial = Compute-KineticEnergy -Bodies $firstSnapshot
    $PE_initial = Compute-PotentialEnergy -Bodies $firstSnapshot
    $E_initial = $KE_initial + $PE_initial
    
    $KE_final = Compute-KineticEnergy -Bodies $lastSnapshot
    $PE_final = Compute-PotentialEnergy -Bodies $lastSnapshot
    $E_final = $KE_final + $PE_final
    
    $COM_initial = Compute-CenterOfMass -Bodies $firstSnapshot
    $COM_final = Compute-CenterOfMass -Bodies $lastSnapshot
    
    $dE = $E_final - $E_initial
    $dE_rel = if ($E_initial -ne 0) { $dE / [math]::Abs($E_initial) } else { 0 }
    
    $dCOM_x = $COM_final.X - $COM_initial.X
    $dCOM_y = $COM_final.Y - $COM_initial.Y
    $dCOM_z = $COM_final.Z - $COM_initial.Z
    $dCOM = [math]::Sqrt($dCOM_x*$dCOM_x + $dCOM_y*$dCOM_y + $dCOM_z*$dCOM_z)
    
    Write-Host "Energy Analysis:" -ForegroundColor Cyan
    Write-Host "  Initial KE: $([math]::Round($KE_initial, 3))" -ForegroundColor White
    Write-Host "  Initial PE: $([math]::Round($PE_initial, 3))" -ForegroundColor White
    Write-Host "  Initial E:  $([math]::Round($E_initial, 3))" -ForegroundColor White
    Write-Host ""
    Write-Host "  Final KE:   $([math]::Round($KE_final, 3))" -ForegroundColor White
    Write-Host "  Final PE:   $([math]::Round($PE_final, 3))" -ForegroundColor White
    Write-Host "  Final E:    $([math]::Round($E_final, 3))" -ForegroundColor White
    Write-Host ""
    Write-Host "  ΔE (absolute): $([math]::Round($dE, 3))" -ForegroundColor Yellow
    Write-Host "  ΔE (relative): $([math]::Round($dE_rel * 100, 3))%" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Center of Mass Drift:" -ForegroundColor Cyan
    Write-Host "  Initial COM: ($([math]::Round($COM_initial.X, 3)), $([math]::Round($COM_initial.Y, 3)), $([math]::Round($COM_initial.Z, 3)))" -ForegroundColor White
    Write-Host "  Final COM: ($([math]::Round($COM_final.X, 3)), $([math]::Round($COM_final.Y, 3)), $([math]::Round($COM_final.Z, 3)))" -ForegroundColor White
    Write-Host "  Distance drifted: $([math]::Round($dCOM, 3))" -ForegroundColor Yellow
    Write-Host ""
}

# Summary report
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Analysis Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "⚠ Phase 0 baseline uses Forward Euler integrator" -ForegroundColor Yellow
Write-Host "ℹ For long-term stability metrics, compare against Phase 1 (Leapfrog)" -ForegroundColor Cyan
Write-Host ""
