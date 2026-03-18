/*
 * test_cpu.c — Unit tests for CPU simulation logic and HYG CSV loading.
 *
 * Tests:
 *   System lifecycle   : allocate/free, zero-init fields
 *   load_hyg_csv       : row count, Sol position, Sol mass/lum, metadata
 *                        (absmag/ci), finite velocities, bad-path guard
 *   compute_accelerations : 2-body attraction (Newton's 3rd law), 1-body = 0
 *   integrate          : position and velocity update correctness
 *   write_snapshot_csv : file creation
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "io.h"
#include "simulation_config.h"
#include "simulation.h"
#include "system.h"
#include "test_framework.h"

#define HYG_CSV_PATH   "data/hyg_v42.csv"
/* Sol (row 0) ground-truth values from HYG v4.2 header row */
#define SOL_X_APPROX   0.000005f
#define SOL_ABSMAG     4.85f
#define SOL_CI         0.656f
#define SOL_LUM        1.0f

static void compute_system_energies(
    const SystemOfBodies *system,
    int num_bodies,
    float gravitational_constant,
    float softening,
    float *kinetic_energy,
    float *potential_energy)
{
    float kinetic = 0.0f;
    float potential = 0.0f;

    for (int i = 0; i < num_bodies; ++i) {
        float v2 = system->vx[i] * system->vx[i] +
                   system->vy[i] * system->vy[i] +
                   system->vz[i] * system->vz[i];
        kinetic += 0.5f * system->mass[i] * v2;
    }

    for (int i = 0; i < num_bodies; ++i) {
        for (int j = i + 1; j < num_bodies; ++j) {
            float dx = system->x[j] - system->x[i];
            float dy = system->y[j] - system->y[i];
            float dz = system->z[j] - system->z[i];
            float distance_squared = dx * dx + dy * dy + dz * dz + softening;
            potential -= gravitational_constant * system->mass[i] * system->mass[j] / sqrtf(distance_squared);
        }
    }

    *kinetic_energy = kinetic;
    *potential_energy = potential;
}

/* -------------------------------------------------------------------------
 * System lifecycle
 * ------------------------------------------------------------------------- */

static void test_allocate_free(void)
{
    SystemOfBodies sys = {0};
    int ok = allocate_system(&sys, 10);

    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(sys.mass   != NULL);
    ASSERT_TRUE(sys.x      != NULL);
    ASSERT_TRUE(sys.radius != NULL);
    ASSERT_TRUE(sys.lum    != NULL);
    ASSERT_TRUE(sys.absmag != NULL);
    ASSERT_TRUE(sys.ci     != NULL);

    free_system(&sys);
    ASSERT_TRUE(sys.mass   == NULL);
    ASSERT_TRUE(sys.radius == NULL);
    ASSERT_TRUE(sys.lum    == NULL);
    ASSERT_TRUE(sys.absmag == NULL);
    ASSERT_TRUE(sys.ci     == NULL);
}

static void test_allocate_zero_does_not_crash(void)
{
    SystemOfBodies sys = {0};
    (void)allocate_system(&sys, 0);
    free_system(&sys);
    ASSERT_TRUE(1); /* still alive */
}

static void test_initialize_accelerations_zero(void)
{
    SystemOfBodies sys = {0};
    allocate_system(&sys, 5);
    initialize_system(&sys, 5);

    ASSERT_NEAR(sys.ax[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.ay[2], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.az[4], 0.0f, 1e-9f);

    free_system(&sys);
}

static void test_init_galaxy_disk_sets_central_body_and_tangential_orbits(void)
{
    enum { N = 32 };
    SystemOfBodies sys = {0};
    const float center_mass = 8000.0f;
    const float max_radius = 60.0f;

    allocate_system(&sys, N);
    init_galaxy_disk(&sys, N, center_mass, max_radius);

    ASSERT_NEAR(sys.x[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.y[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.z[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vx[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vy[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vz[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.mass[0], center_mass, 1e-6f);

    for (int i = 1; i < N; ++i) {
        float r_xy = sqrtf(sys.x[i] * sys.x[i] + sys.y[i] * sys.y[i]);
        float v_xy = sqrtf(sys.vx[i] * sys.vx[i] + sys.vy[i] * sys.vy[i]);
        float dot_rv = sys.x[i] * sys.vx[i] + sys.y[i] * sys.vy[i];
        float expected_speed = sqrtf(G_CONSTANT * center_mass / r_xy);

        ASSERT_TRUE(r_xy > 0.0f);
        ASSERT_TRUE(r_xy <= max_radius + 1e-3f);
        ASSERT_NEAR(dot_rv, 0.0f, 1e-3f * r_xy * fmaxf(v_xy, 1.0f));
        ASSERT_NEAR(v_xy, expected_speed, 1e-3f * expected_speed + 1e-4f);
        ASSERT_NEAR(sys.mass[i], 1.0f, 1e-6f);
        ASSERT_TRUE(fabsf(sys.z[i]) <= 0.02f * max_radius + 1e-5f);
    }

    free_system(&sys);
}

static void test_apply_virial_theorem_scales_to_equilibrium(void)
{
    enum { N = 16 };
    SystemOfBodies sys = {0};
    float kinetic_energy;
    float potential_energy;
    float virial_residual;

    allocate_system(&sys, N);
    init_galaxy_disk(&sys, N, 6000.0f, 40.0f);

    for (int i = 1; i < N; ++i) {
        sys.vx[i] *= 0.35f;
        sys.vy[i] *= 0.35f;
        sys.vz[i] *= 0.35f;
    }

    apply_virial_theorem(&sys, N, G_CONSTANT, SOFTENING_EPS2);
    compute_system_energies(&sys, N, G_CONSTANT, SOFTENING_EPS2, &kinetic_energy, &potential_energy);

    virial_residual = fabsf(2.0f * kinetic_energy + potential_energy) / fmaxf(fabsf(potential_energy), 1e-6f);

    ASSERT_TRUE(kinetic_energy > 0.0f);
    ASSERT_TRUE(potential_energy < 0.0f);
    ASSERT_TRUE(virial_residual < 1e-4f);
    ASSERT_NEAR(sys.vx[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vy[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vz[0], 0.0f, 1e-9f);

    free_system(&sys);
}

/* -------------------------------------------------------------------------
 * load_hyg_csv
 * ------------------------------------------------------------------------- */

static void test_load_hyg_row_count(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    int ok = load_hyg_csv(HYG_CSV_PATH, &sys, &count);

    ASSERT_TRUE(ok == 1);
    ASSERT_TRUE(count > 100000); /* HYG v4.2 has ~119,614 stars */

    free_system(&sys);
}

static void test_load_hyg_sol_position(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    load_hyg_csv(HYG_CSV_PATH, &sys, &count);

    /* Sol: x=0.000005 pc, y=0, z=0 */
    ASSERT_NEAR(sys.x[0], SOL_X_APPROX, 1e-4f);
    ASSERT_NEAR(sys.y[0], 0.0f,         1e-4f);
    ASSERT_NEAR(sys.z[0], 0.0f,         1e-4f);

    free_system(&sys);
}

static void test_load_hyg_sol_velocity_zero(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    load_hyg_csv(HYG_CSV_PATH, &sys, &count);

    ASSERT_NEAR(sys.vx[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vy[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.vz[0], 0.0f, 1e-9f);

    free_system(&sys);
}

static void test_load_hyg_sol_mass_from_lum(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    load_hyg_csv(HYG_CSV_PATH, &sys, &count);

    /* Sol lum=1.0 → mass = 1.0^(1/3.5) = 1.0 */
    ASSERT_NEAR(sys.lum[0],  SOL_LUM, 1e-4f);
    ASSERT_NEAR(sys.mass[0], 1.0f,    1e-4f);

    free_system(&sys);
}

static void test_load_hyg_sol_metadata(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    load_hyg_csv(HYG_CSV_PATH, &sys, &count);

    ASSERT_NEAR(sys.absmag[0], SOL_ABSMAG, 1e-2f);
    ASSERT_NEAR(sys.ci[0],     SOL_CI,     1e-3f);

    free_system(&sys);
}

static void test_load_hyg_all_velocities_finite(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    int i, all_ok = 1;
    load_hyg_csv(HYG_CSV_PATH, &sys, &count);

    for (i = 0; i < count; ++i) {
        if (!isfinite(sys.vx[i]) || !isfinite(sys.vy[i]) || !isfinite(sys.vz[i])) {
            all_ok = 0;
            break;
        }
    }
    ASSERT_TRUE(all_ok);

    free_system(&sys);
}

static void test_load_hyg_bad_path_returns_zero(void)
{
    SystemOfBodies sys = {0};
    int count = 0;
    int ok = load_hyg_csv("data/__does_not_exist__.csv", &sys, &count);

    ASSERT_TRUE(ok == 0);
}

/* -------------------------------------------------------------------------
 * compute_accelerations (CPU)
 * ------------------------------------------------------------------------- */

static void test_two_body_newton_third_law(void)
{
    SystemOfBodies sys = {0};
    allocate_system(&sys, 2);

    /* Body 0 at origin, Body 1 at (10,0,0), equal mass */
    sys.mass[0] = 1.0f; sys.x[0] =  0.0f; sys.y[0] = 0.0f; sys.z[0] = 0.0f;
    sys.mass[1] = 1.0f; sys.x[1] = 10.0f; sys.y[1] = 0.0f; sys.z[1] = 0.0f;
    sys.vx[0] = sys.vy[0] = sys.vz[0] = 0.0f;
    sys.vx[1] = sys.vy[1] = sys.vz[1] = 0.0f;
    sys.ax[0] = sys.ay[0] = sys.az[0] = 0.0f;
    sys.ax[1] = sys.ay[1] = sys.az[1] = 0.0f;

    compute_accelerations(&sys, 2);

    /* Body 0 is attracted toward +x, Body 1 toward -x */
    ASSERT_TRUE(sys.ax[0] > 0.0f);
    ASSERT_TRUE(sys.ax[1] < 0.0f);
    /* Transverse components zero */
    ASSERT_NEAR(sys.ay[0], 0.0f, 1e-6f);
    ASSERT_NEAR(sys.az[0], 0.0f, 1e-6f);
    /* Newton's 3rd: ax[0] == -ax[1] */
    ASSERT_NEAR(sys.ax[0] + sys.ax[1], 0.0f, 1e-6f);

    free_system(&sys);
}

static void test_single_body_zero_acceleration(void)
{
    SystemOfBodies sys = {0};
    allocate_system(&sys, 1);

    sys.mass[0] = 5.0f; sys.x[0] = 1.0f; sys.y[0] = 2.0f; sys.z[0] = 3.0f;
    sys.ax[0] = sys.ay[0] = sys.az[0] = 0.0f;

    compute_accelerations(&sys, 1);

    ASSERT_NEAR(sys.ax[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.ay[0], 0.0f, 1e-9f);
    ASSERT_NEAR(sys.az[0], 0.0f, 1e-9f);

    free_system(&sys);
}

static void test_barnes_hut_matches_direct_small_system(void)
{
    enum { N = 16 };
    SystemOfBodies sys = {0};
    float ax_direct[N], ay_direct[N], az_direct[N];
    int i;

    allocate_system(&sys, N);

    for (i = 0; i < N; ++i) {
        float t = (float)i;
        sys.mass[i] = 0.5f + 0.1f * t;
        sys.x[i] = cosf(0.37f * t) * (3.0f + 0.15f * t);
        sys.y[i] = sinf(0.29f * t) * (2.0f + 0.10f * t);
        sys.z[i] = -1.0f + 0.2f * t;
        sys.vx[i] = sys.vy[i] = sys.vz[i] = 0.0f;
        sys.ax[i] = sys.ay[i] = sys.az[i] = 0.0f;
    }

    compute_accelerations(&sys, N);
    for (i = 0; i < N; ++i) {
        ax_direct[i] = sys.ax[i];
        ay_direct[i] = sys.ay[i];
        az_direct[i] = sys.az[i];
    }

    compute_accelerations_bh(&sys, N, 0.5f);

    for (i = 0; i < N; ++i) {
        float dx = sys.ax[i] - ax_direct[i];
        float dy = sys.ay[i] - ay_direct[i];
        float dz = sys.az[i] - az_direct[i];
        float err_norm = sqrtf(dx * dx + dy * dy + dz * dz);
        float ref_norm = sqrtf(ax_direct[i] * ax_direct[i] + ay_direct[i] * ay_direct[i] + az_direct[i] * az_direct[i]);
        float relative_err = err_norm / (ref_norm + 1e-6f);

        ASSERT_TRUE(relative_err < 0.08f);
    }

    free_system(&sys);
}

/* -------------------------------------------------------------------------
 * integrate
 * ------------------------------------------------------------------------- */

static void test_integrate_updates_pos_and_vel(void)
{
    SystemOfBodies sys = {0};
    allocate_system(&sys, 1);

    set_integrator_mode(INTEGRATOR_EULER);

    sys.x[0]  = 0.0f; sys.y[0]  = 0.0f;  sys.z[0]  = 0.0f;
    sys.vx[0] = 2.0f; sys.vy[0] = -1.0f; sys.vz[0] = 0.5f;
    sys.ax[0] = 1.0f; sys.ay[0] =  0.0f; sys.az[0] = -0.5f;

    integrate(&sys, 1, 0.1f);

    /* vel' = vel + ax*dt */
    ASSERT_NEAR(sys.vx[0],  2.1f,  1e-5f);
    ASSERT_NEAR(sys.vy[0], -1.0f,  1e-5f);
    ASSERT_NEAR(sys.vz[0],  0.45f, 1e-5f);
    /* pos' = pos + vel'*dt */
    ASSERT_NEAR(sys.x[0],  0.21f,   1e-5f);
    ASSERT_NEAR(sys.y[0], -0.10f,   1e-5f);
    ASSERT_NEAR(sys.z[0],  0.045f,  1e-5f);

    free_system(&sys);
}

static void test_integrate_leapfrog_refreshes_acceleration(void)
{
    SystemOfBodies sys = {0};
    float ax_before;

    allocate_system(&sys, 2);
    set_integrator_mode(INTEGRATOR_LEAPFROG);

    sys.mass[0] = 1.0f;
    sys.mass[1] = 1.0f;

    sys.x[0] = 0.0f;
    sys.y[0] = 0.0f;
    sys.z[0] = 0.0f;

    sys.x[1] = 10.0f;
    sys.y[1] = 0.0f;
    sys.z[1] = 0.0f;

    sys.vx[0] = 0.0f;
    sys.vy[0] = 0.0f;
    sys.vz[0] = 0.0f;
    sys.vx[1] = 0.0f;
    sys.vy[1] = 0.0f;
    sys.vz[1] = 0.0f;

    compute_accelerations(&sys, 2);
    ax_before = sys.ax[0];
    integrate(&sys, 2, 0.1f);

    ASSERT_TRUE(sys.x[0] > 0.0f);
    ASSERT_TRUE(sys.vx[0] > 0.0f);
    ASSERT_TRUE(fabsf(sys.ax[0] - ax_before) > 1e-9f);

    set_integrator_mode(INTEGRATOR_EULER);
    free_system(&sys);
}

/* -------------------------------------------------------------------------
 * write_snapshot_csv
 * ------------------------------------------------------------------------- */

static void test_write_snapshot_creates_file(void)
{
    SystemOfBodies sys = {0};
    int ok;
    int i;

    allocate_system(&sys, 3);
    for (i = 0; i < 3; ++i) {
        sys.mass[i]   = (float)(i + 1);
        sys.x[i]      = (float)i;   sys.y[i] = 0.0f; sys.z[i] = 0.0f;
        sys.vx[i]     = 0.0f; sys.vy[i] = 0.0f; sys.vz[i] = 0.0f;
        sys.ax[i]     = 0.0f; sys.ay[i] = 0.0f; sys.az[i] = 0.0f;
        sys.lum[i]    = 1.0f;
        sys.absmag[i] = 5.0f;
        sys.ci[i]     = 0.5f;
    }

    ok = write_snapshot_csv(&sys, 3, 9999, "output");
    ASSERT_TRUE(ok == 1);

    free_system(&sys);
}

static void test_write_snapshot_series_files(void)
{
    SystemOfBodies sys = {0};
    int ok;
    int i;

    allocate_system(&sys, 4);
    for (i = 0; i < 4; ++i) {
        sys.mass[i]   = 1.0f + (float)i;
        sys.lum[i]    = 2.0f + (float)i;
        sys.absmag[i] = 4.0f + 0.1f * (float)i;
        sys.ci[i]     = 0.5f + 0.05f * (float)i;
        sys.x[i]      = (float)i;
        sys.y[i]      = (float)(-i);
        sys.z[i]      = 0.1f * (float)i;
        sys.vx[i]     = 0.0f;
        sys.vy[i]     = 0.0f;
        sys.vz[i]     = 0.0f;
        sys.ax[i]     = 0.0f;
        sys.ay[i]     = 0.0f;
        sys.az[i]     = 0.0f;
    }

    ok = initialize_snapshot_series("output", "cpu", 4, 10, 0.01f, 2, 0.0f);
    ASSERT_TRUE(ok == 1);

    ok = write_snapshot_frame_csv(&sys, 4, 123, 1.23f, "output");
    ASSERT_TRUE(ok == 1);

    free_system(&sys);
}

/* -------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------- */

int main(void)
{
    printf("=== CPU Unit Tests ===\n");

    RUN_TEST(test_allocate_free);
    RUN_TEST(test_allocate_zero_does_not_crash);
    RUN_TEST(test_initialize_accelerations_zero);
    RUN_TEST(test_init_galaxy_disk_sets_central_body_and_tangential_orbits);
    RUN_TEST(test_apply_virial_theorem_scales_to_equilibrium);

    RUN_TEST(test_load_hyg_row_count);
    RUN_TEST(test_load_hyg_sol_position);
    RUN_TEST(test_load_hyg_sol_velocity_zero);
    RUN_TEST(test_load_hyg_sol_mass_from_lum);
    RUN_TEST(test_load_hyg_sol_metadata);
    RUN_TEST(test_load_hyg_all_velocities_finite);
    RUN_TEST(test_load_hyg_bad_path_returns_zero);

    RUN_TEST(test_two_body_newton_third_law);
    RUN_TEST(test_single_body_zero_acceleration);
    RUN_TEST(test_barnes_hut_matches_direct_small_system);

    RUN_TEST(test_integrate_updates_pos_and_vel);
    RUN_TEST(test_integrate_leapfrog_refreshes_acceleration);

    RUN_TEST(test_write_snapshot_creates_file);
    RUN_TEST(test_write_snapshot_series_files);

    PRINT_RESULTS();
    return (g_fail > 0) ? 1 : 0;
}
