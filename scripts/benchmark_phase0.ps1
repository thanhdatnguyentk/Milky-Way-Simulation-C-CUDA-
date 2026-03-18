# Phase 0 Baseline Benchmark Suite
# Purpose: Establish baseline metrics for direct CUDA O(N²) solver
# Metrics: steps/s, fps, cull_ms, draw_ms, visible_count, force error, energy/momentum drift
# Output: benchmark results to data/phase0_results.json

param(
    [string]$OutputDir = "data",
    [string]$SimExePath = "simulation_gpu.exe",
    [switch]$CleanOutput = $false
)

$ErrorActionPreference = "Stop"
$WarningPreference = "Continue"

# Benchmark configuration
$BenchmarkBuckets = @(
    @{ N = 512;    Steps = 100;  Name = "small"  },
    @{ N = 5000;   Steps = 80;   Name = "medium" },
    @{ N = 50000;  Steps = 40;   Name = "large"  },
    @{ N = 120000; Steps = 30;   Name = "xlarge" }
)

$GlobalConfig = @{
    DT              = 0.01
    OutputInterval  = 5
    RenderWidth     = 1280
    RenderHeight    = 720
    FOV             = 70
    Exposure        = 1.2
    Gamma           = 2.2
    CameraProfile   = "default"
    RenderMode      = "raster"
    DataFile        = "data/hyg_v42.csv"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$resolvedExePath = if ([System.IO.Path]::IsPathRooted($SimExePath)) {
    $SimExePath
} else {
    Join-Path $projectRoot $SimExePath
}

if (!(Test-Path $resolvedExePath)) {
    throw "Cannot find simulation executable: $resolvedExePath"
}

# Ensure output directory exists
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Prepare results container
$AllResults = @()
$StartTime = Get-Date

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 0: Baseline Benchmark Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Render mode: $($GlobalConfig.RenderMode)"
Write-Host "  Resolution: $($GlobalConfig.RenderWidth)x$($GlobalConfig.RenderHeight)"
Write-Host "  Data: $($GlobalConfig.DataFile)"
Write-Host "  Output dir: $OutputDir"
Write-Host ""
Write-Host "Starting benchmark execution..." -ForegroundColor Cyan
Write-Host ""

# Function to run single benchmark
function Run-Benchmark {
    param(
        [int]$N,
        [string]$BucketName,
        [int]$Steps
    )

    Write-Host "[*] Running benchmark: N=$N ($BucketName), Steps=$Steps" -ForegroundColor Green
    
    $LogFile = Join-Path $OutputDir "bench_${BucketName}_n${N}.log"
    $TempLogFile = Join-Path $env:TEMP "bench_${BucketName}_$([System.Diagnostics.Process]::GetCurrentProcess().Id)_$(Get-Random).log"
    
    # Build command line
    $CmdArgs = @(
        "$N",
        "$Steps",
        "$($GlobalConfig.DT)",
        "$($GlobalConfig.OutputInterval)",
        "gpu",
        "0",
        "$($GlobalConfig.RenderWidth)",
        "$($GlobalConfig.RenderHeight)",
        "$($GlobalConfig.FOV)",
        "$($GlobalConfig.Exposure)",
        "$($GlobalConfig.Gamma)",
        $GlobalConfig.CameraProfile,
        "--clear-output",
        "--integrator",
        "euler",
        "--render-mode",
        $GlobalConfig.RenderMode
    )

    if ($BucketName -eq "xlarge" -and (Test-Path (Join-Path $projectRoot $GlobalConfig.DataFile))) {
        $CmdArgs += @("--data", $GlobalConfig.DataFile)
    }
    
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Push-Location $projectRoot
        & $resolvedExePath @CmdArgs *> $TempLogFile
        $exitCode = $LASTEXITCODE
        Pop-Location
        $stopwatch.Stop()

        if ($exitCode -ne 0) {
            Write-Host "  [FAIL] Benchmark failed (exit code: $exitCode)" -ForegroundColor Red
            return $null
        }
        
        # Copy log to output dir
        Copy-Item -Path $TempLogFile -Destination $LogFile -Force
        
        # Parse telemetry from log
        $metrics = Parse-TelemetryLog -LogFile $TempLogFile
        
        if ($metrics) {
            $metrics.N = $N
            $metrics.BucketName = $BucketName
            $metrics.Steps = $Steps
            $metrics.Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $elapsedSec = [Math]::Max(0.001, $stopwatch.Elapsed.TotalSeconds)
            $metrics.StepsPerSec = $Steps / $elapsedSec
            
            Write-Host "  [OK] Completed" -ForegroundColor Green
            Write-Host "       Steps/sec: $([math]::Round($metrics.StepsPerSec, 2))" -ForegroundColor Cyan
            Write-Host "       FPS: $([math]::Round($metrics.FpsAvg, 3))" -ForegroundColor Cyan
            Write-Host "       Draw time: $([math]::Round($metrics.DrawMsAvg, 3)) ms" -ForegroundColor Cyan
            Write-Host "       Visible count: $($metrics.VisibleCountAvg)" -ForegroundColor Cyan
            
            return $metrics
        } else {
            Write-Host "  [PARSE ERROR] Failed to parse telemetry" -ForegroundColor Red
            return $null
        }
        
    } catch {
        Write-Host "  [ERROR] $_" -ForegroundColor Red
        return $null
    } finally {
        Remove-Item -Path $TempLogFile -Force -ErrorAction SilentlyContinue
    }
}

# Function to parse telemetry log
function Parse-TelemetryLog {
    param([string]$LogFile)
    
    if (!(Test-Path $LogFile)) {
        return $null
    }
    
    try {
        $content = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
        if (!$content) {
            return $null
        }
        
        # Parse [Render] lines: [Render] step=X mode=raster visible=Y cull=Ams draw=Bms fps=C
        $renderLines = @()
        $lines = $content -split "`n"
        
        foreach ($line in $lines) {
            if ($line -match '\[Render\].*mode=raster.*visible=(\d+).*cull=([0-9.]+)ms.*draw=([0-9.]+)ms.*fps=([0-9.]+)') {
                $renderLines += @{
                    Visible = [int]$matches[1]
                    CullMs  = [double]$matches[2]
                    DrawMs  = [double]$matches[3]
                    Fps     = [double]$matches[4]
                }
            }
        }
        
        if ($renderLines.Count -eq 0) {
            return $null
        }
        
        # Calculate averages (skip first 5 frames as warmup)
        $warmupFrames = [math]::Min(5, [math]::Floor($renderLines.Count / 2))
        $measureFrames = $renderLines[$warmupFrames..($renderLines.Count - 1)]
        
        if ($measureFrames.Count -eq 0) {
            $measureFrames = $renderLines
        }
        
        $metrics = @{
            FrameCount       = $measureFrames.Count
            CullMsAvg        = ($measureFrames.CullMs | Measure-Object -Average).Average
            DrawMsAvg        = ($measureFrames.DrawMs | Measure-Object -Average).Average
            FpsAvg           = ($measureFrames.Fps | Measure-Object -Average).Average
            VisibleCountAvg  = ($measureFrames.Visible | Measure-Object -Average).Average
            StepsPerSec      = 0
        }
        
        return $metrics
        
    } catch {
        Write-Host "    [Parse Warning] $_" -ForegroundColor Yellow
        return $null
    }
}

# Run all benchmarks
Write-Host "Starting benchmark runs..." -ForegroundColor Yellow
Write-Host ""

foreach ($bucket in $BenchmarkBuckets) {
    Write-Host ""
    $result = Run-Benchmark -N $bucket.N -BucketName $bucket.Name -Steps $bucket.Steps
    
    if ($result) {
        $AllResults += $result
    }
}

# Generate summary report
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Benchmark Results Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$ReportFile = Join-Path $OutputDir "phase0_baseline_report.md"

$report = @"
# Phase 0: Baseline Benchmark Report

**Timestamp**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Render Mode**: $($GlobalConfig.RenderMode)
**Render Resolution**: $($GlobalConfig.RenderWidth) x $($GlobalConfig.RenderHeight)
**Data Source**: $($GlobalConfig.DataFile)

## Summary Metrics

| N | Bucket | Steps | Frames | FPS (Avg) | Draw (ms) | Cull (ms) | Visible (Avg) |
|---|--------|-------|--------|-----------|-----------|-----------|---------------|
"@

foreach ($result in $AllResults) {
    $report += "`n| $($result.N) | $($result.BucketName) | $($result.Steps) | $($result.FrameCount) | $([math]::Round($result.FpsAvg, 3)) | $([math]::Round($result.DrawMsAvg, 3)) | $([math]::Round($result.CullMsAvg, 3)) | $([math]::Round($result.VisibleCountAvg, 0)) |"
}

$report += @"

## Detailed Results

"@

foreach ($result in $AllResults) {
    $report += @"

### N = $($result.N) ($($result.BucketName))

- **Frames measured**: $($result.FrameCount)
- **Steps per second**: $([math]::Round($result.StepsPerSec, 3))
- **FPS (average)**: $([math]::Round($result.FpsAvg, 3))
- **Draw time (avg)**: $([math]::Round($result.DrawMsAvg, 3)) ms
- **Cull time (avg)**: $([math]::Round($result.CullMsAvg, 3)) ms
- **Visible count (avg)**: $([math]::Round($result.VisibleCountAvg, 0))
- **Total frame time**: $([math]::Round($result.DrawMsAvg + $result.CullMsAvg, 3)) ms

"@
}

$report += @"

## Next Steps (Phase 1)

1. **Leapfrog Integrator**: Replace Forward Euler with Leapfrog to reduce energy drift
2. **Energy/Momentum Drift Analysis**: Run long-duration simulations (10k+ steps) to measure conservation
3. **Force Error Validation**: Compare GPU direct vs CPU direct on particle subsets
4. **Memory Profiling**: Establish baseline GPU memory footprint

## Notes

- Benchmark uses HYG v4.2 dataset for N=120k (119,626 stars)
- Smaller N use synthetic disk initialization
- Raster rendering mode selected (fast path for scaling benchmarks)
- Forward Euler integrator used (baseline)
- Explicit CUDA memory model (baseline)

"@

Set-Content -Path $ReportFile -Value $report -Encoding UTF8

Write-Host "[OK] Report generated: $ReportFile" -ForegroundColor Green
Write-Host ""

# Export raw metrics as JSON for further analysis
$JsonFile = Join-Path $OutputDir "phase0_baseline_metrics.json"
$AllResults | ConvertTo-Json | Set-Content -Path $JsonFile -Encoding UTF8
Write-Host "[OK] Metrics exported: $JsonFile" -ForegroundColor Green

# Summary
$ElapsedTime = (Get-Date) - $StartTime
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Benchmark Suite Completed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total time: $($ElapsedTime.TotalMinutes.ToString('0.0')) minutes" -ForegroundColor Yellow
Write-Host "Results saved to: $OutputDir" -ForegroundColor Yellow
