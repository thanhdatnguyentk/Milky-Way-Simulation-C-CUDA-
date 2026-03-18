# Phase 0: Baseline Benchmark Suite - Implementation Guide

**Status**: In Progress  
**Week**: Week 1 (Blocking phase for all subsequent optimization)  
**Objective**: Establish reliable baseline metrics for direct CUDA O(N²) gravity solver before implementing any algorithmic improvements.

## Overview

Phase 0 is the critical foundation for the entire multi-phase optimization roadmap. Without established baseline metrics, we cannot:
- ✓ Validate correctness of new algorithms (Barnes-Hut, FMM)
- ✓ Measure true speedup from optimizations
- ✓ Assess long-term stability improvements (Leapfrog vs Euler)
- ✓ Profile memory efficiency (Explicit vs Unified Memory)

All subsequent phases (1-5) depend on Phase 0 completion.

## Benchmark Strategy

### Particle Count Buckets

We test across 4 representative N values covering the full scaling range:

| N | Profile | Use Case | Data Source |
|---|---------|----------|-------------|
| 512 | Small | Algorithm correctness, quick iteration | Synthetic disk |
| 5,000 | Medium | Scaling validation | Synthetic disk |
| 50,000 | Large | GPU throughput test | Synthetic disk |
| 120,000 | XLarge | Real-world dataset | HYG v4.2 catalog (119,626 stars) |

### Render Configuration

- **Mode**: `raster` (production path, ~2ms/frame)
- **Resolution**: 1280×720 (fixed for consistent measurement)
- **Duration**: Variable steps per bucket to reach stable averages (40-100 steps)
- **Integrator**: Forward Euler (current baseline)
- **Memory**: Explicit cudaMalloc (current baseline)

### Metrics Collected

#### 1. **Rendering Performance**
- `fps_avg`: Average frames per second (render throughput)
- `draw_ms_avg`: Average time per frame for GPU rasterization
- `cull_ms_avg`: Average time for frustum culling
- `visible_count_avg`: Average visible stars per frame

**Why**: Establishes baseline graphics performance. Raster render should remain ~2ms/frame regardless of algorithm changes (separate from compute).

#### 2. **Compute Performance**
- `steps_per_second`: Simulation integration rate (bodies updated per second)

**Computed as**: `(N * total_steps) / total_elapsed_time`

**Why**: Primary KPI for algorithmic optimization. Higher = better. Phase 2 algorithms (BH, FMM) should increase this significantly at N=50k, 120k.

#### 3. **Stability Metrics** (baseline only)
- `energy_drift_absolute`: ΔE between initial and final snapshot
- `energy_drift_relative`: ΔE / |E_initial| × 100%
- `momentum_drift`: Distance of center-of-mass from initial position

**Why**: Quantifies physical accuracy. Forward Euler shows drift. Phase 1 (Leapfrog) should reduce drift by 10-100×.

## Execution Plan

### Script Structure

```
scripts/
├── run_phase0.ps1              # Master orchestrator
├── benchmark_phase0.ps1        # Core benchmark runner
├── analyze_phase0_drift.ps1    # Energy/momentum analysis
└── PHASE0_IMPLEMENTATION.md    # This file
```

### Running Phase 0

```powershell
# Full execution: build → benchmark → analyze
cd d:\My\University\Cuda\university-simulation
.\scripts\run_phase0.ps1

# Or selective execution
.\scripts\run_phase0.ps1 -SkipBuild    # Only benchmark + analyze
.\scripts\run_phase0.ps1 -SkipAnalysis # Only build + benchmark
```

### Outputs

**Benchmark Results:**
- `data/phase0_baseline_report.md` — Human-readable summary table
- `data/phase0_baseline_metrics.json` — Machine-readable metrics for scripting/analysis
- `data/bench_*.log` — Raw telemetry logs per bucket

**Analysis Results:**
- Console output: Energy/momentum drift for reference snapshot pair

## Expected Baseline Values

Based on profiling data from prior runs (HYG v4.2, raster mode, 1280×720, GPU RTX 3050 Laptop):

| N | Bucket | FPS (est.) | Draw Time (est.) | Visible Avg (est.) | Steps/Sec (est.) |
|---|--------|-----------|-----------------|-------------------|------------------|
| 512 | small | 2.4 | 2.1 ms | 512 | 51.2k |
| 5k | medium | 2.4 | 2.1 ms | 5k | 5.12k |
| 50k | large | 2.2 | 2.3 ms | 50k | 550 |
| 120k | xlarge | 1.8 | 2.8 ms | 110k | 54 |

**Note**: These are **raster-only** estimates. Draw time should scale minimally because rasterization is O(visible_count × pixels), not O(N²). The 2-2.8ms overhead is consistent geometry processing.

## Acceptance Criteria

✓ Phase 0 is **complete** when:

1. All 4 buckets (512, 5k, 50k, 120k) generate successful benchmark runs
2. At least 20+ frames captured per bucket after warmup
3. Metrics JSON exported without errors
4. Human-readable report generated with averages and summary
5. Energy/momentum drift analysis executes without crashes
6. All results committed to git with Phase 0 folder snapshot

❌ Phase 0 is **blocked** if:

- Any bucket fails to run (e.g., OOM, CUDA error)
- Telemetry parsing fails for >50% of frames
- Metrics show internally inconsistent values (e.g., FPS > 144 at 1280×720 on RTX 3050)

## Technical Notes

### Warmup Frames

The first 5 frames are discarded from averaging to allow:
- GPU kernel compilation (JIT finalization)
- Memory hierarchy stabilization
- Cache warm-up

### Visible Count Variation

Visible particle count depends on camera position and frustum. The "default" camera profile views the disk from (0, 0, 120), which typically shows 80-95% of the dataset after culling.

### Energy Drift Interpretation

Forward Euler energy drift over 100 steps for a 120k-particle system:
- **Expected**: 1-5% relative drift (good)
- **Concerning**: >10% drift (possible integration error)
- **Unacceptable**: >50% drift (major issue)

Leapfrog in Phase 1 should reduce this to <0.5% relative drift.

## Troubleshooting

### Issue: "No CSV data found" error
- **Check**: `data/hyg_v42.csv` exists and is readable
- **Fix**: Download HYG v4.2 dataset or update `GlobalConfig.DataFile` in `benchmark_phase0.ps1`

### Issue: Simulation crashes at N=120k
- **Check**: GPU memory (RTX 3050 has 2GB/4GB depending on variant)
- **Fix**: Reduce N to 50k or split into smaller batches; note memory constraint

### Issue: Inconsistent FPS readings
- **Possible cause**: Background processes stealing GPU/CPU
- **Fix**: Close other GPU applications, run in isolation
- **Retry**: Re-run single bucket with `benchmark_phase0.ps1`

### Issue: Parse errors in telemetry
- **Check**: Build used `--clear-output`; output files exist
- **Fix**: Manually verify `output/` contains `[Render]` log lines; check format

## Next Steps After Phase 0

Once Phase 0 baseline is established and committed:

1. **Commit baseline snapshot**:
   ```bash
   git add data/phase0_*.* 
   git commit -m "Phase 0: Baseline direct O(N²) CUDA solver metrics"
   ```

2. **Begin Phase 1 (parallel with **Phase 2A/2B prep**)**: 
   - Implement Leapfrog integrator on CPU/GPU
   - Measure energy drift reduction
   - Target: 10-100× improvement in conservation

3. **Prepare Phase 2A/2B groundwork**:
   - Study CPU Barnes-Hut implementation (reference)
   - Design GPU octree data structure
   - Write FMM correctness tests

## References

- **Phase 0 Plan**: Phase 0 section of main scaling plan
- **Simulation CLI**: See `README.md` for complete parameter list
- **HYG Dataset**: `data/hyg_v42.csv` (119,626 real stars)
- **Telemetry Format**: `[Render] step=X mode=Y visible=Z cull=Ams draw=Bms fps=C`

## Success Metrics

| Metric | Target | Status |
|--------|--------|--------|
| Benchmark runs complete for all 4 buckets | ✓ Pass | Pending |
| Metrics exported to JSON | ✓ Pass | Pending |
| Report generated with summary table | ✓ Pass | Pending |
| Energy/momentum drift computed | ✓ Pass | Pending |
| Phase 0 results committed to git | ✓ Pass | Pending |
| Ready for Phase 1 implementation | ✓ Yes | Pending |

---

**Baseline Timestamp**: To be filled after Phase 0 execution  
**Prepared by**: GitHub Copilot optimization roadmap  
**Last Updated**: 2026-03-18
