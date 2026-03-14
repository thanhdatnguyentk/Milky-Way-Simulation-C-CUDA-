#ifndef SYSTEM_H
#define SYSTEM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float *mass;
    float *x, *y, *z;
    float *vx, *vy, *vz;
    float *ax, *ay, *az;
    float *radius; /* render-space star radius */
    float *lum;    /* luminosity in solar units (used to derive mass) */
    float *absmag; /* absolute magnitude (brightness) */
    float *ci;     /* color index B-V (star color) */
} SystemOfBodies;

int allocate_system(SystemOfBodies *system, int num_bodies);
void free_system(SystemOfBodies *system);
void initialize_system(SystemOfBodies *system, int num_bodies);

#ifdef __cplusplus
}
#endif

#endif