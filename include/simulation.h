#ifndef SIMULATION_H
#define SIMULATION_H

#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

void compute_accelerations(SystemOfBodies *system, int num_bodies);
void integrate(SystemOfBodies *system, int num_bodies, float dt);

#ifdef __cplusplus
}
#endif

#endif