
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef USE_CUDA
#include "cuda_nbody.h"
#endif
#include "io.h"
#include "simulation.h"
#include "system.h"

#define DEFAULT_NUM_BODIES 256
#define DEFAULT_NUM_STEPS 200
#define DEFAULT_DT 0.01f
#define DEFAULT_OUTPUT_INTERVAL 20
static int parse_int_arg(const char *value, int fallback)
{
    char *end_ptr = NULL;
    long parsed = strtol(value, &end_ptr, 10);

    if (end_ptr == value || *end_ptr != '\0' || parsed <= 0) {
        return fallback;
    }

    return (int)parsed;
}

static float parse_float_arg(const char *value, float fallback)
{
    char *end_ptr = NULL;
    float parsed = strtof(value, &end_ptr);

    if (end_ptr == value || *end_ptr != '\0' || parsed <= 0.0f) {
        return fallback;
    }

    return parsed;
}

static int is_gpu_backend(const char *value)
{
    return strcmp(value, "gpu") == 0 || strcmp(value, "cuda") == 0;
}

int main(int argc, char **argv)
{
    SystemOfBodies system = {0};
    int num_bodies = DEFAULT_NUM_BODIES;
    int num_steps = DEFAULT_NUM_STEPS;
    int output_interval = DEFAULT_OUTPUT_INTERVAL;
    int use_gpu = 0;
    float dt = DEFAULT_DT;
    int step;

    if (argc > 1) {
        num_bodies = parse_int_arg(argv[1], DEFAULT_NUM_BODIES);
    }

    if (argc > 2) {
        num_steps = parse_int_arg(argv[2], DEFAULT_NUM_STEPS);
    }

    if (argc > 3) {
        dt = parse_float_arg(argv[3], DEFAULT_DT);
    }

    if (argc > 4) {
        output_interval = parse_int_arg(argv[4], DEFAULT_OUTPUT_INTERVAL);
    }

    if (argc > 5 && is_gpu_backend(argv[5])) {
        use_gpu = 1;
    }

    if (!allocate_system(&system, num_bodies)) {
        fprintf(stderr, "Failed to allocate memory for %d bodies.\n", num_bodies);
        return EXIT_FAILURE;
    }

    initialize_system(&system, num_bodies);

    printf("Running %s N-body baseline with %d bodies, %d steps, dt=%.4f\n",
           use_gpu ? "GPU" : "CPU",
           num_bodies,
           num_steps,
           dt);

    for (step = 0; step < num_steps; ++step) {
#ifdef USE_CUDA
        if (use_gpu) {
            if (!compute_accelerations_cuda(&system, num_bodies)) {
                fprintf(stderr, "Failed to compute accelerations on CUDA at step %d.\n", step);
                free_system(&system);
                return EXIT_FAILURE;
            }
        } else {
            compute_accelerations(&system, num_bodies);
        }
#else
        if (use_gpu) {
            fprintf(stderr, "This binary was built without CUDA support. Rebuild with USE_CUDA and cuda/nbody.cu.\n");
            free_system(&system);
            return EXIT_FAILURE;
        }

        compute_accelerations(&system, num_bodies);
#endif
        integrate(&system, num_bodies, dt);

        if (step == 0 || step == num_steps - 1 || step % output_interval == 0) {
            print_snapshot(&system, num_bodies, step);

            if (!write_snapshot_csv(&system, num_bodies, step, "output")) {
                fprintf(stderr, "Failed to write CSV snapshot for step %d.\n", step);
                free_system(&system);
                return EXIT_FAILURE;
            }
        }
    }

    free_system(&system);
    return EXIT_SUCCESS;
}