#!/usr/bin/env pwsh
# Phase 0 Execution Script - Main Benchmark Runner
# This script builds the GPU executable and runs the complete Phase 0 benchmark suite.

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

if (-not $SkipBuild) {
    Write-Host "Step 1: Building GPU executable..." -ForegroundColor Yellow
    Push-Location $projectRoot
    try {
        if (Test-Path "build_gpu.bat") {
            & ".\build_gpu.bat"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[FAIL] Build failed" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "[WARN] build_gpu.bat not found, skipping build" -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }

    Write-Host "[OK] Build completed" -ForegroundColor Green
    Write-Host ""
}

if (-not $SkipBenchmark) {
    Write-Host "Step 2: Running benchmark suite..." -ForegroundColor Yellow
    Push-Location $projectRoot
    try {
        & "$scriptDir\benchmark_phase0.ps1" -OutputDir $OutputDir
        if (-not $?) {
            Write-Host "[FAIL] Benchmark execution failed" -ForegroundColor Red
            exit 1
        }
    } finally {
        Pop-Location
    }

    Write-Host "[OK] Benchmarks completed" -ForegroundColor Green
    Write-Host ""
}

if (-not $SkipAnalysis) {
    Write-Host "Step 3: Analyzing results..." -ForegroundColor Yellow
    Push-Location $projectRoot
    try {
        & "$scriptDir\analyze_phase0_drift.ps1" -OutputDir "output"
        if (-not $?) {
            Write-Host "[WARN] Analysis script reported an error" -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }

    Write-Host "[OK] Analysis completed" -ForegroundColor Green
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Phase 0 Execution Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[OK] Results saved to:" -ForegroundColor Yellow
Write-Host "    - $OutputDir/phase0_baseline_report.md" -ForegroundColor Cyan
Write-Host "    - $OutputDir/phase0_baseline_metrics.json" -ForegroundColor Cyan
Write-Host ""
Write-Host "[NEXT]" -ForegroundColor Yellow
Write-Host "    1. Review baseline metrics in phase0_baseline_report.md" -ForegroundColor Cyan
Write-Host "    2. Commit Phase 0 results to version control" -ForegroundColor Cyan
Write-Host "    3. Begin Phase 1: Leapfrog integrator implementation" -ForegroundColor Cyan
Write-Host ""
