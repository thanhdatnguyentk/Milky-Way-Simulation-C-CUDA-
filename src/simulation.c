#include <math.h>

#include "simulation_config.h"
#include "simulation.h"

void compute_accelerations(SystemOfBodies *system, int num_bodies)
{
    int body_index;
    int other_index;

    for (body_index = 0; body_index < num_bodies; ++body_index) {
        float ax = 0.0f;
        float ay = 0.0f;
        float az = 0.0f;

        for (other_index = 0; other_index < num_bodies; ++other_index) {
            float dx;
            float dy;
            float dz;
            float distance_squared;
            float inverse_distance;
            float inverse_distance_cubed;
            float scale;

            if (body_index == other_index) {
                continue;
            }

            dx = system->x[other_index] - system->x[body_index];
            dy = system->y[other_index] - system->y[body_index];
            dz = system->z[other_index] - system->z[body_index];

            distance_squared = dx * dx + dy * dy + dz * dz + SOFTENING;
            inverse_distance = 1.0f / sqrtf(distance_squared);
            inverse_distance_cubed = inverse_distance * inverse_distance * inverse_distance;
            scale = G_CONSTANT * system->mass[other_index] * inverse_distance_cubed;

            ax += dx * scale;
            ay += dy * scale;
            az += dz * scale;
        }

        system->ax[body_index] = ax;
        system->ay[body_index] = ay;
        system->az[body_index] = az;
    }
}

void integrate(SystemOfBodies *system, int num_bodies, float dt)
{
    int index;

    for (index = 0; index < num_bodies; ++index) {
        system->vx[index] += system->ax[index] * dt;
        system->vy[index] += system->ay[index] * dt;
        system->vz[index] += system->az[index] * dt;

        system->x[index] += system->vx[index] * dt;
        system->y[index] += system->vy[index] * dt;
        system->z[index] += system->vz[index] * dt;
    }
}