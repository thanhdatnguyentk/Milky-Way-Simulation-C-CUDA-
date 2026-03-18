#!/usr/bin/env pwsh
# Phase 0 Execution Script - Main Benchmark Runner
# This script builds the GPU executable and runs the complete Phase 0 benchmark suite

param(
    [switch]$SkipBuild = $false,
    [switch]$SkipBenchmark = $false,
    [switch]$SkipAnalysis = $false,
    [string]$OutputDir = "data"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 0: Baseline Benchmark Execution" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 0: Build GPU executable
if (-not $SkipBuild) {
    Write-Host "Step 1: Building GPU executable..." -ForegroundColor Yellow
    
    Push-Location $projectRoot
    
    if (Test-Path "build_gpu.bat") {
        & ".\build_gpu.bat"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✗ Build failed!" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "⚠ build_gpu.bat not found, skipping build" -ForegroundColor Yellow
    }
    
    Pop-Location
    
    Write-Host "✓ Build completed" -ForegroundColor Green
    Write-Host ""
}

# Step 1: Run benchmark suite
if (-not $SkipBenchmark) {
    Write-Host "Step 2: Running benchmark suite..." -ForegroundColor Yellow
    
    Push-Location $projectRoot
    
    & "$scriptDir\benchmark_phase0.ps1" -OutputDir $OutputDir
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Benchmark execution failed!" -ForegroundColor Red
        exit 1
    }
    
    Pop-Location
    
    Write-Host "✓ Benchmarks completed" -ForegroundColor Green
    Write-Host ""
}

# Step 2: Analyze results
if (-not $SkipAnalysis) {
    Write-Host "Step 3: Analyzing results..." -ForegroundColor Yellow
    
    Push-Location $projectRoot
    
    & "$scriptDir\analyze_phase0_drift.ps1" -OutputDir "output" -DataDir "data"
    
    Pop-Location
    
    Write-Host "✓ Analysis completed" -ForegroundColor Green
    Write-Host ""
}

# Final summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 0 Execution Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📊 Results saved to:" -ForegroundColor Yellow
Write-Host "   - $OutputDir/phase0_baseline_report.md" -ForegroundColor Cyan
Write-Host "   - $OutputDir/phase0_baseline_metrics.json" -ForegroundColor Cyan
Write-Host ""
Write-Host "📝 Next steps:" -ForegroundColor Yellow
Write-Host "   1. Review baseline metrics in phase0_baseline_report.md" -ForegroundColor Cyan
Write-Host "   2. Commit Phase 0 results to version control" -ForegroundColor Cyan
Write-Host "   3. Begin Phase 1: Leapfrog integrator implementation" -ForegroundColor Cyan
Write-Host ""
