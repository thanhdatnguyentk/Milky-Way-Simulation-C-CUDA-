#ifndef CUDA_NBODY_H
#define CUDA_NBODY_H

#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

int compute_accelerations_cuda(SystemOfBodies *system, int num_bodies);

#ifdef __cplusplus
}
#endif

#endif