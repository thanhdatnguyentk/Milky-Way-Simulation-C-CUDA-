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

typedef enum {
	SOLVER_DIRECT = 0,
	SOLVER_BH = 1,
	SOLVER_FMM = 2
} SolverMode;

void compute_accelerations(SystemOfBodies *system, int num_bodies);
void compute_accelerations_bh(SystemOfBodies *system, int num_bodies, float theta);
void integrate(SystemOfBodies *system, int num_bodies, float dt);
void set_integrator_mode(IntegratorMode mode);
IntegratorMode get_integrator_mode(void);
void set_solver_mode(SolverMode mode);
SolverMode get_solver_mode(void);
void set_solver_theta(float theta);
float get_solver_theta(void);
void compute_accelerations_selected(SystemOfBodies *system, int num_bodies);
void advance_simulation(SystemOfBodies *system, int num_bodies, float dt);

#ifdef __cplusplus
}
#endif

#endif