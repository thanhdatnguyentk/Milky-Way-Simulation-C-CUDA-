/*
 * test_gpu.cu — GPU stability and correctness tests.
 *
 * Tests:
 *   test_cuda_device_available      : at least one CUDA device present
 *   test_gpu_accelerations_match_cpu: GPU results agree with CPU (max diff < 1e-4)
 *   test_gpu_no_nan_after_steps     : N=64 bodies, 20 steps → no NaN/Inf
 *   test_gpu_center_of_mass_stable  : symmetric 4-body, CoM stays at origin
 */

#include <cuda_runtime.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "cuda_nbody.h"
#include "simulation.h"
#include "system.h"
#include "test_framework.h"

/* -------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */

static void fill_deterministic(SystemOfBodies *sys, int n)
{
    for (int i = 0; i < n; ++i) {
        sys->mass[i]   = 0.5f + (float)(i % 5) * 0.5f;
        sys->x[i]      = (float)(i % 20) - 10.0f;
        sys->y[i]      = (float)(i / 20) - 1.5f;
        sys->z[i]      = (float)(i % 7)  *  0.5f - 1.5f;
        sys->vx[i]     =  0.01f * (float)(i % 3 - 1);
        sys->vy[i]     =  0.01f * (float)(i % 5 - 2);
        sys->vz[i]     =  0.0f;
        sys->ax[i]     =  0.0f; sys->ay[i] = 0.0f; sys->az[i] = 0.0f;
        sys->lum[i]    =  1.0f;
        sys->absmag[i] =  5.0f;
        sys->ci[i]     =  0.5f;
    }
}

static int has_nan_or_inf(const SystemOfBodies *sys, int n)
{
    for (int i = 0; i < n; ++i) {
        if (!isfinite(sys->x[i])  || !isfinite(sys->y[i])  || !isfinite(sys->z[i]))  return 1;
        if (!isfinite(sys->vx[i]) || !isfinite(sys->vy[i]) || !isfinite(sys->vz[i])) return 1;
        if (!isfinite(sys->ax[i]) || !isfinite(sys->ay[i]) || !isfinite(sys->az[i])) return 1;
    }
    return 0;
}

static int file_exists(const char *path)
{
    FILE *file = fopen(path, "rb");

    if (file == NULL) {
        return 0;
    }

    fclose(file);
    return 1;
}

/* -------------------------------------------------------------------------
 * Tests
 * ------------------------------------------------------------------------- */

static void test_cuda_device_available(void)
{
    int count = 0;
    cudaError_t err = cudaGetDeviceCount(&count);

    ASSERT_TRUE(err == cudaSuccess);
    ASSERT_TRUE(count > 0);

    if (err == cudaSuccess && count > 0) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, 0);
        printf("    Device 0: %s  (Compute %d.%d, %.0f MB)\n",
               prop.name, prop.major, prop.minor,
               (double)prop.totalGlobalMem / (1024.0 * 1024.0));
    }
}

/* Verify GPU accelerations match CPU for N=64 bodies with identical inputs. */
static void test_gpu_accelerations_match_cpu(void)
{
    const int N = 64;
    SystemOfBodies cpu = {0}, gpu = {0};

    allocate_system(&cpu, N);
    allocate_system(&gpu, N);
    fill_deterministic(&cpu, N);

    /* Copy identical state to GPU system */
    memcpy(gpu.mass, cpu.mass, (size_t)N * sizeof(float));
    memcpy(gpu.x,    cpu.x,    (size_t)N * sizeof(float));
    memcpy(gpu.y,    cpu.y,    (size_t)N * sizeof(float));
    memcpy(gpu.z,    cpu.z,    (size_t)N * sizeof(float));
    for (int i = 0; i < N; ++i) {
        gpu.vx[i] = gpu.vy[i] = gpu.vz[i] = 0.0f;
        gpu.ax[i] = gpu.ay[i] = gpu.az[i] = 0.0f;
        gpu.lum[i] = gpu.absmag[i] = gpu.ci[i] = 0.0f;
    }

    compute_accelerations(&cpu, N);
    int ok = compute_accelerations_cuda(&gpu, N);
    ASSERT_TRUE(ok == 1);

    float max_err = 0.0f;
    for (int i = 0; i < N; ++i) {
        float ex = fabsf(cpu.ax[i] - gpu.ax[i]);
        float ey = fabsf(cpu.ay[i] - gpu.ay[i]);
        float ez = fabsf(cpu.az[i] - gpu.az[i]);
        if (ex > max_err) max_err = ex;
        if (ey > max_err) max_err = ey;
        if (ez > max_err) max_err = ez;
    }
    printf("    Max CPU↔GPU acceleration error: %.3e\n", max_err);
    ASSERT_TRUE(max_err < 1e-4f);

    free_system(&cpu);
    free_system(&gpu);
}

/* Run 20 time steps on GPU (N=64); no NaN or Inf should appear. */
static void test_gpu_no_nan_after_steps(void)
{
    const int N     = 64;
    const int STEPS = 20;
    const float DT  = 0.001f;
    SystemOfBodies sys = {0};
    int ok = 1;

    allocate_system(&sys, N);
    fill_deterministic(&sys, N);

    for (int step = 0; step < STEPS && ok; ++step) {
        if (!compute_accelerations_cuda(&sys, N)) { ok = 0; break; }
        integrate(&sys, N, DT);
    }

    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(!has_nan_or_inf(&sys, N));

    free_system(&sys);
}

/*
 * Symmetric 4-body (masses placed at ±(5,0,0) and (0,±5,0), equal mass,
 * zero initial velocity). Centre-of-mass must remain at origin because
 * all internal forces cancel — verifies Newton's 3rd law on GPU.
 */
static void test_gpu_center_of_mass_stable(void)
{
    const int N     = 4;
    const int STEPS = 100;
    const float DT  = 0.005f;
    SystemOfBodies sys = {0};

    allocate_system(&sys, N);

    float xs[4] = {  5.0f, -5.0f,  0.0f,  0.0f };
    float ys[4] = {  0.0f,  0.0f,  5.0f, -5.0f };
    for (int i = 0; i < N; ++i) {
        sys.mass[i]   = 1.0f;
        sys.x[i]      = xs[i]; sys.y[i] = ys[i]; sys.z[i] = 0.0f;
        sys.vx[i]     = 0.0f;  sys.vy[i] = 0.0f; sys.vz[i] = 0.0f;
        sys.ax[i]     = 0.0f;  sys.ay[i] = 0.0f; sys.az[i] = 0.0f;
        sys.lum[i]    = 1.0f;  sys.absmag[i] = 5.0f; sys.ci[i] = 0.5f;
    }

    for (int step = 0; step < STEPS; ++step) {
        compute_accelerations_cuda(&sys, N);
        integrate(&sys, N, DT);
    }

    float cx = (sys.x[0] + sys.x[1] + sys.x[2] + sys.x[3]) / 4.0f;
    float cy = (sys.y[0] + sys.y[1] + sys.y[2] + sys.y[3]) / 4.0f;
    float cz = (sys.z[0] + sys.z[1] + sys.z[2] + sys.z[3]) / 4.0f;
    printf("    CoM after %d steps: (%.5f, %.5f, %.5f)\n", STEPS, cx, cy, cz);

    ASSERT_NEAR(cx, 0.0f, 0.01f);
    ASSERT_NEAR(cy, 0.0f, 0.01f);
    ASSERT_NEAR(cz, 0.0f, 1e-6f);
    ASSERT_TRUE(!has_nan_or_inf(&sys, N));

    free_system(&sys);
}

/*
 * Stress test: N=1024 bodies, 50 steps on GPU.
 * Checks stability (no NaN/Inf) at a larger scale.
 */
static void test_gpu_large_scale_stability(void)
{
    const int N     = 1024;
    const int STEPS = 50;
    const float DT  = 0.0005f;
    SystemOfBodies sys = {0};
    int ok = 1;

    allocate_system(&sys, N);
    fill_deterministic(&sys, N);

    for (int step = 0; step < STEPS && ok; ++step) {
        if (!compute_accelerations_cuda(&sys, N)) { ok = 0; break; }
        integrate(&sys, N, DT);
    }

    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(!has_nan_or_inf(&sys, N));

    free_system(&sys);
}

static void test_gpu_renderer_outputs_png(void)
{
    const int N = 32;
    SystemOfBodies sys = {0};
    RenderCamera camera = {0.0f, 0.0f, 60.0f, 0.0f, 0.0f, 1.0f, 60.0f};
    const char *output_path = "output/test_render_gpu.png";
    int ok;

    allocate_system(&sys, N);
    fill_deterministic(&sys, N);

    ok = initialize_cuda_renderer(N, 320, 180);
    ASSERT_TRUE(ok == 1);

    ok = render_frame_cuda(&sys, N, &camera, 1.25f, 2.2f, output_path);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(file_exists(output_path));

    shutdown_cuda_renderer();
    free_system(&sys);
}

static void test_gpu_persistent_simulation_and_render(void)
{
    const int N = 64;
    const int STEPS = 10;
    SystemOfBodies sys = {0};
    RenderCamera camera = {0.0f, 0.0f, 80.0f, 0.0f, 0.0f, 1.0f, 60.0f};
    int ok;

    allocate_system(&sys, N);
    fill_deterministic(&sys, N);

    ok = initialize_cuda_simulation(&sys, N);
    ASSERT_TRUE(ok == 1);
    ok = initialize_cuda_renderer(N, 320, 180);
    ASSERT_TRUE(ok == 1);

    for (int step = 0; step < STEPS; ++step) {
        ok = step_cuda_simulation(&sys, N, 0.001f, 0);
        ASSERT_TRUE(ok == 1);
        ok = render_current_frame_cuda(&camera, 1.25f, 2.2f);
        ASSERT_TRUE(ok == 1);
    }

    ok = sync_cuda_system_to_host(&sys, N);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(!has_nan_or_inf(&sys, N));

    shutdown_cuda_renderer();
    shutdown_cuda_simulation();
    free_system(&sys);
}

/* -------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------- */

int main(void)
{
    int device_count = 0;

    printf("=== GPU Unit Tests ===\n");

    if (cudaGetDeviceCount(&device_count) != cudaSuccess || device_count == 0) {
        printf("\n[SKIP] No CUDA-capable device found. All GPU tests skipped.\n");
        return 0;
    }

    RUN_TEST(test_cuda_device_available);
    RUN_TEST(test_gpu_accelerations_match_cpu);
    RUN_TEST(test_gpu_no_nan_after_steps);
    RUN_TEST(test_gpu_center_of_mass_stable);
    RUN_TEST(test_gpu_large_scale_stability);
    RUN_TEST(test_gpu_renderer_outputs_png);
    RUN_TEST(test_gpu_persistent_simulation_and_render);

    PRINT_RESULTS();
    return (g_fail > 0) ? 1 : 0;
}
