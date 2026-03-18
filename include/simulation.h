#ifndef SIMULATION_H
#define SIMULATION_H

#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	INTEGRATOR_EULER = 0,
	INTEGRATOR_LEAPFROG = 1
} IntegratorMode;

void compute_accelerations(SystemOfBodies *system, int num_bodies);
void compute_accelerations_bh(SystemOfBodies *system, int num_bodies, float theta);
void integrate(SystemOfBodies *system, int num_bodies, float dt);
void set_integrator_mode(IntegratorMode mode);
IntegratorMode get_integrator_mode(void);

#ifdef __cplusplus
}
#endif

#endif