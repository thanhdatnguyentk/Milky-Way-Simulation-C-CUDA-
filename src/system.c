#include <stdlib.h>
#include <time.h>

#include "system.h"

static float random_range(float min_value, float max_value)
{
    float normalized = (float)rand() / (float)RAND_MAX;
    return min_value + normalized * (max_value - min_value);
}

void free_system(SystemOfBodies *system)
{
    free(system->mass);
    free(system->x);
    free(system->y);
    free(system->z);
    free(system->vx);
    free(system->vy);
    free(system->vz);
    free(system->ax);
    free(system->ay);
    free(system->az);
    free(system->radius);
    free(system->lum);
    free(system->absmag);
    free(system->ci);

    system->mass = NULL;
    system->x = NULL;
    system->y = NULL;
    system->z = NULL;
    system->vx = NULL;
    system->vy = NULL;
    system->vz = NULL;
    system->ax     = NULL;
    system->ay     = NULL;
    system->az     = NULL;
    system->radius = NULL;
    system->lum    = NULL;
    system->absmag = NULL;
    system->ci     = NULL;
}

int allocate_system(SystemOfBodies *system, int num_bodies)
{
    system->mass = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->x = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->y = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->z = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->vx = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->vy = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->vz = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->ax     = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->ay     = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->az     = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->radius = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->lum    = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->absmag = (float *)malloc((size_t)num_bodies * sizeof(float));
    system->ci     = (float *)malloc((size_t)num_bodies * sizeof(float));

    if (!system->mass || !system->x || !system->y || !system->z || !system->vx ||
        !system->vy || !system->vz || !system->ax || !system->ay || !system->az ||
        !system->radius || !system->lum || !system->absmag || !system->ci) {
        free_system(system);
        return 0;
    }

    return 1;
}

void initialize_system(SystemOfBodies *system, int num_bodies)
{
    int index;

    srand((unsigned int)time(NULL));

    for (index = 0; index < num_bodies; ++index) {
        system->mass[index] = random_range(0.5f, 10.0f);

        system->x[index] = random_range(-50.0f, 50.0f);
        system->y[index] = random_range(-50.0f, 50.0f);
        system->z[index] = random_range(-5.0f, 5.0f);

        system->vx[index] = random_range(-0.2f, 0.2f);
        system->vy[index] = random_range(-0.2f, 0.2f);
        system->vz[index] = random_range(-0.05f, 0.05f);

        system->ax[index]     = 0.0f;
        system->ay[index]     = 0.0f;
        system->az[index]     = 0.0f;
        system->radius[index] = 0.1f;
        system->lum[index]    = 1.0f;
        system->absmag[index] = 0.0f;
        system->ci[index]     = 0.0f;
    }
}