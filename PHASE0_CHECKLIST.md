# Phase 0 Quick Reference Checklist

## Pre-Execution Checklist

- [ ] GPU executable built and tested (`simulation_gpu.exe` runs without error)
- [ ] `data/hyg_v42.csv` exists and is readable (119,626 rows)
- [ ] `output/` directory exists and is writable
- [ ] `data/` directory exists (for benchmark results)
- [ ] PowerShell script execution policy set to allow local scripts
  ```powershell
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
  ```
- [ ] No GPU-competing processes (close games, mining software, unnecessary apps)

## Execution

### Option 1: Full Execution (Build + Benchmark + Analyze)
```powershell
cd d:\My\University\Cuda\university-simulation
.\scripts\run_phase0.ps1
```
**Estimated duration**: 15-30 minutes depending on GPU speed

### Option 2: Skip Build (Use Existing Binary)
```powershell
.\scripts\run_phase0.ps1 -SkipBuild
```
**Estimated duration**: 15-25 minutes

### Option 3: Benchmark Only
```powershell
.\scripts\benchmark_phase0.ps1 -OutputDir data
```
**Estimated duration**: 10-20 minutes

## Expected Output

### Immediate Console Output
```
========================================
Phase 0: Baseline Benchmark Suite
========================================

Configuration:
  Render mode: raster
  Resolution: 1280x720
  Data: data/hyg_v42.csv
  Output dir: data

▶ Running benchmark: N=512 (small), Steps=100
  ✓ Completed
    Steps/sec: 51.2k
    FPS: 2.453
    Draw time: 2.055 ms
    Visible count: 512
...
```

### Generated Files

After execution, check for:
```
data/
├── phase0_baseline_report.md       # Summary table + analysis
├── phase0_baseline_metrics.json    # Raw metrics (machine-readable)
├── bench_small_n512.log            # Telemetry for N=512
├── bench_medium_n5000.log          # Telemetry for N=5k
├── bench_large_n50000.log          # Telemetry for N=50k
└── bench_xlarge_n120000.log        # Telemetry for N=120k
```

## Interpreting Results

### Raster Render Performance (Expected)
- **FPS**: Should be 1.8-2.5 across all N (rendering independent of N)
- **Draw time**: Should be 2-3ms across all N
- **Visible count**: Should scale with N (512→120k)

### Compute Throughput (Key Metric)
- **Steps/sec** = N × steps / total_seconds
- Should be highest at small N (512), smallest at large N (120k)
- Order of magnitude check: ~50k at N=512, ~50 at N=120k

### Drift Baseline (Reference Only)
- **Energy drift**: Expect 1-5% over 100 steps (normal for Euler)
- **Momentum drift**: Should be <1 unit (good initialization)

## Troubleshooting

### Script Not Running
- **Fix**: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

### "simulation_gpu.exe not found"
- **Check**: Current directory is project root
- **Fix**: Build first: `.\build_gpu.bat`

### Memory/OOM Errors
- **Check**: GPU memory usage with `nvidia-smi`
- **Fix**: Reduce N=120k to N=50k, or run single benchmarks sequentially

### Telemetry Parse Errors
- **Check**: `output/` contains files with `[Render]` lines
- **Fix**: Verify `--render-mode raster` in benchmark config

### Very Low FPS (<1.0)
- **Check**: Is GPU being used? (gpu flag correct?)
- **Fix**: Verify backend=gpu in CLI args

## After Phase 0

1. **Review Results**
   - Open `data/phase0_baseline_report.md` in editor
   - Check all 4 buckets are present with reasonable metrics

2. **Commit to Git**
   ```bash
   git add docs/PHASE0_IMPLEMENTATION.md
   git add scripts/benchmark_phase0.ps1
   git add scripts/analyze_phase0_drift.ps1
   git add scripts/run_phase0.ps1
   git add data/phase0_baseline_*
   git add data/bench_*.log
   git commit -m "Phase 0: Establish baseline metrics for direct O(N²) CUDA solver"
   git push
   ```

3. **Begin Phase 1**
   - Implement Leapfrog integrator
   - Compare energy drift vs Forward Euler baseline
   - Target: 10-100× improvement in conservation

## Key Contacts

- **Telemetry Format Documentation**: See `main.c` render loop (line ~700)
- **Benchmark CLI Reference**: See `README.md` section "Cách chạy phiên bản hiện tại"
- **Phase 0 Full Plan**: See `docs/PHASE0_IMPLEMENTATION.md`

---

**Last Updated**: 2026-03-18  
**Phase 0 Duration**: ~1 week (Week 1)  
**Blocking**: All Phases 1-5 depend on Phase 0 baseline
