#ifndef SYSTEM_H
#define SYSTEM_H

typedef struct {
    float *mass;
    float *x, *y, *z;
    float *vx, *vy, *vz;
    float *ax, *ay, *az;
} SystemOfBodies;

int allocate_system(SystemOfBodies *system, int num_bodies);
void free_system(SystemOfBodies *system);
void initialize_system(SystemOfBodies *system, int num_bodies);

#endif