#ifndef RENDERER_H
#define RENDERER_H

#include "system.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x;
    float y;
    float z;
    float yaw;
    float pitch;
    float zoom;
    float fov;
} RenderCamera;

int initialize_cuda_simulation(const SystemOfBodies *system, int num_bodies);
void shutdown_cuda_simulation(void);
int step_cuda_simulation(SystemOfBodies *system, int num_bodies, float dt, int sync_to_host);
int sync_cuda_system_to_host(SystemOfBodies *system, int num_bodies);
int initialize_cuda_renderer(int max_bodies, int width, int height);
void shutdown_cuda_renderer(void);
int render_current_frame_cuda(const RenderCamera *camera, float exposure, float gamma);
int write_current_render_png(const char *output_path);
const unsigned char *get_cuda_render_rgba(int *width, int *height);
int render_frame_cuda(
    const SystemOfBodies *system,
    int num_bodies,
    const RenderCamera *camera,
    float exposure,
    float gamma,
    const char *output_path);

#ifdef __cplusplus
}
#endif

#endif
