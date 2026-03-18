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
#include <time.h>

#include "cuda_nbody.h"
#include "simulation.h"
#include "system.h"
#include "test_framework.h"

#define TEST_DEG_TO_RAD 0.01745329252f
#define TEST_RADIUS_SCALE_MASS 0.08f
#define TEST_RADIUS_SCALE_LUM 0.16f
#define TEST_RADIUS_BLEND_LUM 0.80f
#define TEST_RADIUS_MIN 0.03f
#define TEST_RADIUS_MAX 2.50f
#define TEST_RENDER_NEAR 0.1f
#define TEST_RENDER_FAR 5000.0f

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

static double now_ms(void)
{
    return 1000.0 * (double)clock() / (double)CLOCKS_PER_SEC;
}

static float star_radius_host(float mass, float lum, float ci)
{
    float m = fmaxf(mass, 0.0f);
    float L = fmaxf(lum, 0.0f);
    float c = ci;
    float t_kelvin = 4600.0f * (1.0f / (0.92f * c + 1.7f) + 1.0f / (0.92f * c + 0.62f));
    float t_ratio;
    float r_mass;
    float r_lum;
    float r_star;

    if (!isfinite(t_kelvin) || t_kelvin < 1000.0f) {
        t_kelvin = 1000.0f;
    }

    t_ratio = t_kelvin / 5772.0f;
    r_mass = cbrtf(fmaxf(m, 1e-6f));
    r_lum = sqrtf(L) / (t_ratio * t_ratio);
    r_star = (1.0f - TEST_RADIUS_BLEND_LUM) * (TEST_RADIUS_SCALE_MASS * r_mass) +
             TEST_RADIUS_BLEND_LUM * (TEST_RADIUS_SCALE_LUM * r_lum);

    if (r_star < TEST_RADIUS_MIN) {
        r_star = TEST_RADIUS_MIN;
    }
    if (r_star > TEST_RADIUS_MAX) {
        r_star = TEST_RADIUS_MAX;
    }

    return r_star;
}

static void camera_basis_host(const RenderCamera *camera, float *rx, float *ry, float *rz,
                              float *ux, float *uy, float *uz,
                              float *fx, float *fy, float *fz)
{
    float yaw = camera->yaw * TEST_DEG_TO_RAD;
    float pitch = camera->pitch * TEST_DEG_TO_RAD;
    float cy = cosf(yaw);
    float sy = sinf(yaw);
    float cp = cosf(pitch);
    float sp = sinf(pitch);

    *rx = cy;        *ry = 0.0f; *rz = sy;
    *ux = sy * sp;   *uy = cp;   *uz = -cy * sp;
    *fx = -sy * cp;  *fy = sp;   *fz = -cy * cp;
}

static int sphere_visible_cpu(const RenderCamera *camera, float aspect,
                              float x, float y, float z, float radius)
{
    float rx, ry, rz;
    float ux, uy, uz;
    float fx, fy, fz;
    float tan_half_fov_y;
    float tan_half_fov_x;
    float dx;
    float dy;
    float dz;
    float cx;
    float cy;
    float cz;

    camera_basis_host(camera, &rx, &ry, &rz, &ux, &uy, &uz, &fx, &fy, &fz);

    tan_half_fov_y = tanf(0.5f * camera->fov * TEST_DEG_TO_RAD) / fmaxf(camera->zoom, 0.1f);
    tan_half_fov_x = tan_half_fov_y * aspect;

    dx = x - camera->x;
    dy = y - camera->y;
    dz = z - camera->z;

    cx = dx * rx + dy * ry + dz * rz;
    cy = dx * ux + dy * uy + dz * uz;
    cz = dx * fx + dy * fy + dz * fz;

    if (cx + cz * tan_half_fov_x < -radius) return 0;
    if (-cx + cz * tan_half_fov_x < -radius) return 0;
    if (cy + cz * tan_half_fov_y < -radius) return 0;
    if (-cy + cz * tan_half_fov_y < -radius) return 0;
    if (cz - TEST_RENDER_NEAR < -radius) return 0;
    if (TEST_RENDER_FAR - cz < -radius) return 0;

    return 1;
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

static void test_gpu_integrator_mode_switch(void)
{
    int ok;

    ok = set_cuda_integrator_mode(INTEGRATOR_EULER);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(get_cuda_integrator_mode() == INTEGRATOR_EULER);

    ok = set_cuda_integrator_mode(INTEGRATOR_LEAPFROG);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(get_cuda_integrator_mode() == INTEGRATOR_LEAPFROG);
}

static void test_gpu_solver_mode_switch(void)
{
    int ok;

    ok = set_cuda_solver_mode(SOLVER_DIRECT);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(get_cuda_solver_mode() == SOLVER_DIRECT);

    ok = set_cuda_solver_mode(SOLVER_BH);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(get_cuda_solver_mode() == SOLVER_BH);

    ok = set_cuda_solver_mode(SOLVER_FMM);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(get_cuda_solver_mode() == SOLVER_FMM);

    ok = set_cuda_solver_theta(0.65f);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(fabsf(get_cuda_solver_theta() - 0.65f) < 1e-6f);

    ok = set_cuda_solver_mode(SOLVER_DIRECT);
    ASSERT_TRUE(ok == 1);
}

static void test_gpu_bh_solver_mode_step_runs(void)
{
    const int N = 128;
    const int STEPS = 5;
    SystemOfBodies sys = {0};
    int ok;

    allocate_system(&sys, N);
    fill_deterministic(&sys, N);

    ok = initialize_cuda_simulation(&sys, N);
    ASSERT_TRUE(ok == 1);

    ok = set_cuda_solver_mode(SOLVER_BH);
    ASSERT_TRUE(ok == 1);
    ok = set_cuda_solver_theta(0.6f);
    ASSERT_TRUE(ok == 1);
    ok = set_cuda_integrator_mode(INTEGRATOR_LEAPFROG);
    ASSERT_TRUE(ok == 1);

    for (int step = 0; step < STEPS; ++step) {
        ok = step_cuda_simulation(&sys, N, 0.001f, 0);
        ASSERT_TRUE(ok == 1);
    }

    ok = sync_cuda_system_to_host(&sys, N);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(!has_nan_or_inf(&sys, N));

    ok = set_cuda_solver_mode(SOLVER_DIRECT);
    ASSERT_TRUE(ok == 1);

    shutdown_cuda_simulation();
    free_system(&sys);
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

/*
 * Phase 3 benchmark: compare CPU vs GPU acceleration compute time
 * on at least two problem sizes.
 */
static void test_gpu_benchmark_two_sizes(void)
{
    const int sizes[2] = {256, 1024};

    for (int s = 0; s < 2; ++s) {
        const int N = sizes[s];
        SystemOfBodies cpu = {0};
        SystemOfBodies gpu = {0};
        double cpu_start;
        double cpu_end;
        double gpu_start;
        double gpu_end;
        double cpu_ms;
        double gpu_ms;
        float max_err = 0.0f;
        int ok;

        allocate_system(&cpu, N);
        allocate_system(&gpu, N);
        fill_deterministic(&cpu, N);

        memcpy(gpu.mass, cpu.mass, (size_t)N * sizeof(float));
        memcpy(gpu.x, cpu.x, (size_t)N * sizeof(float));
        memcpy(gpu.y, cpu.y, (size_t)N * sizeof(float));
        memcpy(gpu.z, cpu.z, (size_t)N * sizeof(float));
        memcpy(gpu.vx, cpu.vx, (size_t)N * sizeof(float));
        memcpy(gpu.vy, cpu.vy, (size_t)N * sizeof(float));
        memcpy(gpu.vz, cpu.vz, (size_t)N * sizeof(float));
        memcpy(gpu.lum, cpu.lum, (size_t)N * sizeof(float));
        memcpy(gpu.absmag, cpu.absmag, (size_t)N * sizeof(float));
        memcpy(gpu.ci, cpu.ci, (size_t)N * sizeof(float));

        cpu_start = now_ms();
        compute_accelerations(&cpu, N);
        cpu_end = now_ms();

        gpu_start = now_ms();
        ok = compute_accelerations_cuda(&gpu, N);
        gpu_end = now_ms();
        ASSERT_TRUE(ok == 1);

        cpu_ms = cpu_end - cpu_start;
        gpu_ms = gpu_end - gpu_start;

        for (int i = 0; i < N; ++i) {
            float ex = fabsf(cpu.ax[i] - gpu.ax[i]);
            float ey = fabsf(cpu.ay[i] - gpu.ay[i]);
            float ez = fabsf(cpu.az[i] - gpu.az[i]);
            if (ex > max_err) max_err = ex;
            if (ey > max_err) max_err = ey;
            if (ez > max_err) max_err = ez;
        }

        printf("    Benchmark N=%d: CPU=%.3f ms, GPU=%.3f ms, speedup=%.2fx, max_err=%.3e\n",
               N,
               cpu_ms,
               gpu_ms,
               (gpu_ms > 1e-9) ? (cpu_ms / gpu_ms) : 0.0,
               max_err);

        ASSERT_TRUE(max_err < 2e-4f);

        free_system(&cpu);
        free_system(&gpu);
    }
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

static void test_gpu_raster_mode_render_path(void)
{
    const int N = 64;
    SystemOfBodies sys = {0};
    RenderCamera camera = {0.0f, 0.0f, 80.0f, 0.0f, 0.0f, 1.0f, 60.0f};
    RenderTelemetry telemetry = {0, 0.0f, 0.0f};
    int ok;

    allocate_system(&sys, N);
    fill_deterministic(&sys, N);

    ok = initialize_cuda_simulation(&sys, N);
    ASSERT_TRUE(ok == 1);
    ok = initialize_cuda_renderer(N, 320, 180);
    ASSERT_TRUE(ok == 1);

    ok = set_cuda_render_mode(CUDA_RENDER_MODE_RASTER);
    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(get_cuda_render_mode() == CUDA_RENDER_MODE_RASTER);

    ok = render_current_frame_cuda(&camera, 1.25f, 2.2f);
    ASSERT_TRUE(ok == 1);
    get_last_render_telemetry(&telemetry);
    ASSERT_TRUE(telemetry.visible_count > 0U);

    ok = set_cuda_render_mode(CUDA_RENDER_MODE_RAYTRACE);
    ASSERT_TRUE(ok == 1);

    shutdown_cuda_renderer();
    shutdown_cuda_simulation();
    free_system(&sys);
}

static void test_gpu_frustum_visible_count_matches_cpu_reference(void)
{
    const int N = 8;
    const float aspect = 320.0f / 180.0f;
    SystemOfBodies sys = {0};
    RenderCamera camera = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 70.0f};
    RenderTelemetry telemetry = {0, 0.0f, 0.0f};
    int expected_visible = 0;
    int ok;

    allocate_system(&sys, N);

    for (int i = 0; i < N; ++i) {
        sys.mass[i] = 1.0f;
        sys.vx[i] = sys.vy[i] = sys.vz[i] = 0.0f;
        sys.ax[i] = sys.ay[i] = sys.az[i] = 0.0f;
        sys.lum[i] = 1.0f;
        sys.absmag[i] = 5.0f;
        sys.ci[i] = 0.5f;
    }

    sys.x[0] = 0.0f;   sys.y[0] = 0.0f;   sys.z[0] = -10.0f;
    sys.x[1] = 1.0f;   sys.y[1] = 0.5f;   sys.z[1] = -25.0f;
    sys.x[2] = -2.0f;  sys.y[2] = -1.0f;  sys.z[2] = -40.0f;
    sys.x[3] = 0.0f;   sys.y[3] = 0.0f;   sys.z[3] = 12.0f;
    sys.x[4] = 5000.0f;sys.y[4] = 0.0f;   sys.z[4] = -10.0f;
    sys.x[5] = 0.0f;   sys.y[5] = 5000.0f;sys.z[5] = -20.0f;
    sys.x[6] = 0.0f;   sys.y[6] = 0.0f;   sys.z[6] = -6000.0f;
    sys.x[7] = 5.0f;   sys.y[7] = 0.0f;   sys.z[7] = -20.0f;

    for (int i = 0; i < N; ++i) {
        float r = star_radius_host(sys.mass[i], sys.lum[i], sys.ci[i]);
        expected_visible += sphere_visible_cpu(&camera, aspect, sys.x[i], sys.y[i], sys.z[i], r);
    }

    ok = initialize_cuda_simulation(&sys, N);
    ASSERT_TRUE(ok == 1);
    ok = initialize_cuda_renderer(N, 320, 180);
    ASSERT_TRUE(ok == 1);

    ok = render_current_frame_cuda(&camera, 1.2f, 2.2f);
    ASSERT_TRUE(ok == 1);

    get_last_render_telemetry(&telemetry);
    ASSERT_TRUE((int)telemetry.visible_count == expected_visible);

    shutdown_cuda_renderer();
    shutdown_cuda_simulation();
    free_system(&sys);
}

static void test_gpu_zero_visible_produces_black_frame(void)
{
    const int N = 4;
    int width = 0;
    int height = 0;
    SystemOfBodies sys = {0};
    RenderCamera camera = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 70.0f};
    RenderTelemetry telemetry = {0, 0.0f, 0.0f};
    const unsigned char *rgba;
    int all_black_rgb = 1;
    int all_alpha_255 = 1;
    int ok;

    allocate_system(&sys, N);

    for (int i = 0; i < N; ++i) {
        sys.mass[i] = 1.0f;
        sys.x[i] = 0.0f;
        sys.y[i] = 0.0f;
        sys.z[i] = 50.0f + (float)i;
        sys.vx[i] = sys.vy[i] = sys.vz[i] = 0.0f;
        sys.ax[i] = sys.ay[i] = sys.az[i] = 0.0f;
        sys.lum[i] = 1.0f;
        sys.absmag[i] = 5.0f;
        sys.ci[i] = 0.5f;
    }

    ok = initialize_cuda_simulation(&sys, N);
    ASSERT_TRUE(ok == 1);
    ok = initialize_cuda_renderer(N, 64, 64);
    ASSERT_TRUE(ok == 1);

    ok = render_current_frame_cuda(&camera, 1.2f, 2.2f);
    ASSERT_TRUE(ok == 1);

    get_last_render_telemetry(&telemetry);
    ASSERT_TRUE(telemetry.visible_count == 0U);

    rgba = get_cuda_render_rgba(&width, &height);
    ASSERT_TRUE(rgba != NULL);
    ASSERT_TRUE(width == 64);
    ASSERT_TRUE(height == 64);

    for (int i = 0; i < width * height; ++i) {
        if (rgba[i * 4 + 0] != 0 || rgba[i * 4 + 1] != 0 || rgba[i * 4 + 2] != 0) {
            all_black_rgb = 0;
        }
        if (rgba[i * 4 + 3] != 255) {
            all_alpha_255 = 0;
        }
    }

    ASSERT_TRUE(all_black_rgb == 1);
    ASSERT_TRUE(all_alpha_255 == 1);

    shutdown_cuda_renderer();
    shutdown_cuda_simulation();
    free_system(&sys);
}

static void test_gpu_raytrace_picks_nearest_sphere(void)
{
    const int N = 2;
    int width = 0;
    int height = 0;
    int center_index;
    SystemOfBodies sys = {0};
    RenderCamera camera = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 70.0f};
    RenderTelemetry telemetry = {0, 0.0f, 0.0f};
    const unsigned char *rgba;
    int ok;

    allocate_system(&sys, N);

    sys.mass[0] = 1.0f;  sys.x[0] = 0.0f; sys.y[0] = 0.0f; sys.z[0] = -18.0f;
    sys.mass[1] = 1.0f;  sys.x[1] = 0.0f; sys.y[1] = 0.0f; sys.z[1] = -35.0f;

    for (int i = 0; i < N; ++i) {
        sys.vx[i] = sys.vy[i] = sys.vz[i] = 0.0f;
        sys.ax[i] = sys.ay[i] = sys.az[i] = 0.0f;
        sys.absmag[i] = 5.0f;
        sys.ci[i] = 0.5f;
    }

    sys.lum[0] = 0.2f;
    sys.lum[1] = 300.0f;

    ok = initialize_cuda_simulation(&sys, N);
    ASSERT_TRUE(ok == 1);
    ok = initialize_cuda_renderer(N, 101, 101);
    ASSERT_TRUE(ok == 1);

    ok = render_current_frame_cuda(&camera, 1.2f, 2.2f);
    ASSERT_TRUE(ok == 1);

    get_last_render_telemetry(&telemetry);
    ASSERT_TRUE(telemetry.visible_count == 2U);

    rgba = get_cuda_render_rgba(&width, &height);
    ASSERT_TRUE(rgba != NULL);

    center_index = ((height / 2) * width + (width / 2)) * 4;
    ASSERT_TRUE(rgba[center_index + 0] > 0);
    ASSERT_TRUE(rgba[center_index + 1] > 0);
    ASSERT_TRUE(rgba[center_index + 2] > 0);

    ASSERT_TRUE(rgba[center_index + 0] < 190);
    ASSERT_TRUE(rgba[center_index + 1] < 190);
    ASSERT_TRUE(rgba[center_index + 2] < 190);

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
    RUN_TEST(test_gpu_integrator_mode_switch);
    RUN_TEST(test_gpu_solver_mode_switch);
    RUN_TEST(test_gpu_bh_solver_mode_step_runs);
    RUN_TEST(test_gpu_accelerations_match_cpu);
    RUN_TEST(test_gpu_benchmark_two_sizes);
    RUN_TEST(test_gpu_no_nan_after_steps);
    RUN_TEST(test_gpu_center_of_mass_stable);
    RUN_TEST(test_gpu_large_scale_stability);
    RUN_TEST(test_gpu_renderer_outputs_png);
    RUN_TEST(test_gpu_persistent_simulation_and_render);
    RUN_TEST(test_gpu_raster_mode_render_path);
    RUN_TEST(test_gpu_frustum_visible_count_matches_cpu_reference);
    RUN_TEST(test_gpu_zero_visible_produces_black_frame);
    RUN_TEST(test_gpu_raytrace_picks_nearest_sphere);

    PRINT_RESULTS();
    return (g_fail > 0) ? 1 : 0;
}
