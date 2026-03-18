#ifndef CUDA_NBODY_H
#define CUDA_NBODY_H

#include "system.h"
#include "renderer.h"
#include "simulation.h"

#ifdef __cplusplus
extern "C" {
#endif

int compute_accelerations_cuda(SystemOfBodies *system, int num_bodies);
int initialize_cuda_simulation(const SystemOfBodies *system, int num_bodies);
void shutdown_cuda_simulation(void);
int step_cuda_simulation(SystemOfBodies *system, int num_bodies, float dt, int sync_to_host);
int sync_cuda_system_to_host(SystemOfBodies *system, int num_bodies);
int initialize_cuda_renderer(int max_bodies, int width, int height);
void shutdown_cuda_renderer(void);
int render_current_frame_cuda(const RenderCamera *camera, float exposure, float gamma);
int bind_cuda_render_pbo(unsigned int pbo, int width, int height);
void unbind_cuda_render_pbo(void);

typedef enum {
	CUDA_RENDER_MODE_RAYTRACE = 0,
	CUDA_RENDER_MODE_RASTER = 1
} CudaRenderMode;

int set_cuda_render_mode(CudaRenderMode mode);
CudaRenderMode get_cuda_render_mode(void);
int set_cuda_integrator_mode(IntegratorMode mode);
IntegratorMode get_cuda_integrator_mode(void);
int set_cuda_solver_mode(SolverMode mode);
SolverMode get_cuda_solver_mode(void);
int set_cuda_solver_theta(float theta);
float get_cuda_solver_theta(void);

typedef struct {
    unsigned int visible_count;
    float cull_ms;
    float trace_ms;
} RenderTelemetry;

void get_last_render_telemetry(RenderTelemetry *out);
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