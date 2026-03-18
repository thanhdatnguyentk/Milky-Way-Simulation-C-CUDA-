#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
#include <GL/gl.h>
#include <cuda_runtime.h>
#include <cuda_gl_interop.h>
#include <math.h>
#include <stdlib.h>

#include "cuda_nbody.h"
#include "png_writer.h"
#include "simulation_config.h"

static float *g_sim_mass = NULL;
static float *g_sim_x = NULL;
static float *g_sim_y = NULL;
static float *g_sim_z = NULL;
static float *g_sim_vx = NULL;
static float *g_sim_vy = NULL;
static float *g_sim_vz = NULL;
static float *g_sim_ax = NULL;
static float *g_sim_ay = NULL;
static float *g_sim_az = NULL;
static float *g_sim_radius = NULL;
static float *g_sim_lum = NULL;
static float *g_sim_ci = NULL;
static int g_sim_capacity = 0;
static int g_sim_num_bodies = 0;

static unsigned char *g_device_rgba = NULL;
static unsigned char *g_host_rgba = NULL;
static int *g_visible_indices = NULL;
static unsigned int *g_visible_count = NULL;
static float *g_accum_r = NULL;
static float *g_accum_g = NULL;
static float *g_accum_b = NULL;
static cudaStream_t g_render_stream = NULL;
static cudaGraphicsResource *g_gl_pbo_resource = NULL;
static int g_gl_pbo_width = 0;
static int g_gl_pbo_height = 0;
static int g_renderer_width = 0;
static int g_renderer_height = 0;
static int g_renderer_capacity = 0;
static CudaRenderMode g_render_mode = CUDA_RENDER_MODE_RAYTRACE;
static IntegratorMode g_cuda_integrator_mode = INTEGRATOR_LEAPFROG;
static SolverMode g_cuda_solver_mode = SOLVER_DIRECT;
static float g_cuda_solver_theta = 0.5f;

static RenderTelemetry g_last_telemetry = {0, 0.0f, 0.0f};

#define DEG_TO_RAD 0.01745329252f
#define RADIUS_SCALE_MASS 0.08f
#define RADIUS_SCALE_LUM 0.16f
#define RADIUS_BLEND_LUM 0.80f
#define RADIUS_MIN 0.03f
#define RADIUS_MAX 2.50f
#define RENDER_NEAR_PLANE 0.1f
#define RENDER_FAR_PLANE 5000.0f
#define RASTER_RADIUS_SCALE_PX 0.9f
#define RASTER_MIN_RADIUS_PX 1.0f
#define RASTER_MAX_RADIUS_PX 12.0f
#define RASTER_DEPTH_ATTEN 0.00035f
#define NBODY_BLOCK_SIZE 256

typedef struct {
    float3 cam_pos;
    float3 right;
    float3 up;
    float3 forward;
    float tan_half_fov_x;
    float tan_half_fov_y;
    float focal_y;
} CameraKernelParams;

__host__ __device__ static float saturate_float(float value)
{
    if (value < 0.0f) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

__host__ __device__ static float lerp_float(float a, float b, float t)
{
    return a + (b - a) * t;
}

__device__ static void color_from_ci(float ci, float *r, float *g, float *b)
{
    float t = saturate_float((ci + 0.4f) / 2.4f);

    if (t < 0.33f) {
        float local_t = t / 0.33f;
        *r = lerp_float(0.55f, 1.0f, local_t);
        *g = lerp_float(0.70f, 1.0f, local_t);
        *b = 1.0f;
    } else if (t < 0.66f) {
        float local_t = (t - 0.33f) / 0.33f;
        *r = 1.0f;
        *g = lerp_float(1.0f, 0.92f, local_t);
        *b = lerp_float(1.0f, 0.70f, local_t);
    } else {
        float local_t = (t - 0.66f) / 0.34f;
        *r = 1.0f;
        *g = lerp_float(0.92f, 0.52f, local_t);
        *b = lerp_float(0.70f, 0.25f, local_t);
    }
}

__host__ __device__ static float3 add3(float3 a, float3 b)
{
    return make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}

__host__ __device__ static float3 sub3(float3 a, float3 b)
{
    return make_float3(a.x - b.x, a.y - b.y, a.z - b.z);
}

__host__ __device__ static float3 mul3(float3 a, float s)
{
    return make_float3(a.x * s, a.y * s, a.z * s);
}

__host__ __device__ static float dot3(float3 a, float3 b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

__host__ __device__ static float3 normalize3(float3 v)
{
    float len2 = dot3(v, v);
    if (len2 <= 1e-20f) {
        return make_float3(0.0f, 0.0f, 1.0f);
    }
    return mul3(v, 1.0f / sqrtf(len2));
}

__host__ __device__ static void compute_camera_basis(RenderCamera camera, float3 *right, float3 *up, float3 *forward)
{
    float yaw = camera.yaw * DEG_TO_RAD;
    float pitch = camera.pitch * DEG_TO_RAD;
    float cy = cosf(yaw);
    float sy = sinf(yaw);
    float cp = cosf(pitch);
    float sp = sinf(pitch);

    *right = make_float3(cy, 0.0f, sy);
    *up = make_float3(sy * sp, cp, -cy * sp);
    *forward = make_float3(-sy * cp, sp, -cy * cp);
}

__global__ static void compute_accelerations_kernel(
    const float *__restrict__ mass,
    const float *__restrict__ x,
    const float *__restrict__ y,
    const float *__restrict__ z,
    float *__restrict__ ax,
    float *__restrict__ ay,
    float *__restrict__ az,
    int num_bodies)
{
    int tid = threadIdx.x;
    int body_index = blockIdx.x * blockDim.x + tid;
    float local_ax = 0.0f;
    float local_ay = 0.0f;
    float local_az = 0.0f;
    float x_i;
    float y_i;
    float z_i;

    __shared__ float sh_x[NBODY_BLOCK_SIZE];
    __shared__ float sh_y[NBODY_BLOCK_SIZE];
    __shared__ float sh_z[NBODY_BLOCK_SIZE];
    __shared__ float sh_mass[NBODY_BLOCK_SIZE];

    if (body_index >= num_bodies) {
        return;
    }

    x_i = x[body_index];
    y_i = y[body_index];
    z_i = z[body_index];

    for (int tile_base = 0; tile_base < num_bodies; tile_base += NBODY_BLOCK_SIZE) {
        int other_index = tile_base + tid;
        int tile_count = num_bodies - tile_base;

        if (tile_count > NBODY_BLOCK_SIZE) {
            tile_count = NBODY_BLOCK_SIZE;
        }

        if (other_index < num_bodies) {
            sh_x[tid] = x[other_index];
            sh_y[tid] = y[other_index];
            sh_z[tid] = z[other_index];
            sh_mass[tid] = mass[other_index];
        }

        __syncthreads();

        for (int j = 0; j < tile_count; ++j) {
            int global_other = tile_base + j;
            float dx;
            float dy;
            float dz;
            float distance_squared;
            float inverse_distance;
            float inverse_distance_cubed;
            float scale;

            if (global_other == body_index) {
                continue;
            }

            dx = sh_x[j] - x_i;
            dy = sh_y[j] - y_i;
            dz = sh_z[j] - z_i;

            distance_squared = dx * dx + dy * dy + dz * dz + SOFTENING_EPS2;
            inverse_distance = rsqrtf(distance_squared);
            inverse_distance_cubed = inverse_distance * inverse_distance * inverse_distance;
            scale = G_CONSTANT * sh_mass[j] * inverse_distance_cubed;

            local_ax = fmaf(dx, scale, local_ax);
            local_ay = fmaf(dy, scale, local_ay);
            local_az = fmaf(dz, scale, local_az);
        }

        __syncthreads();
    }

    ax[body_index] = local_ax;
    ay[body_index] = local_ay;
    az[body_index] = local_az;
}

__global__ static void integrate_kernel(
    float *x,
    float *y,
    float *z,
    float *vx,
    float *vy,
    float *vz,
    const float *ax,
    const float *ay,
    const float *az,
    int num_bodies,
    float dt)
{
    int body_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (body_index >= num_bodies) {
        return;
    }

    vx[body_index] += ax[body_index] * dt;
    vy[body_index] += ay[body_index] * dt;
    vz[body_index] += az[body_index] * dt;

    x[body_index] += vx[body_index] * dt;
    y[body_index] += vy[body_index] * dt;
    z[body_index] += vz[body_index] * dt;
}

__global__ static void integrate_kick_drift_kernel(
    float *x,
    float *y,
    float *z,
    float *vx,
    float *vy,
    float *vz,
    const float *ax,
    const float *ay,
    const float *az,
    int num_bodies,
    float dt)
{
    int body_index = blockIdx.x * blockDim.x + threadIdx.x;
    float half_dt;

    if (body_index >= num_bodies) {
        return;
    }

    half_dt = 0.5f * dt;

    vx[body_index] += ax[body_index] * half_dt;
    vy[body_index] += ay[body_index] * half_dt;
    vz[body_index] += az[body_index] * half_dt;

    x[body_index] += vx[body_index] * dt;
    y[body_index] += vy[body_index] * dt;
    z[body_index] += vz[body_index] * dt;
}

__global__ static void integrate_kick_finish_kernel(
    float *vx,
    float *vy,
    float *vz,
    const float *ax,
    const float *ay,
    const float *az,
    int num_bodies,
    float dt)
{
    int body_index = blockIdx.x * blockDim.x + threadIdx.x;
    float half_dt;

    if (body_index >= num_bodies) {
        return;
    }

    half_dt = 0.5f * dt;
    vx[body_index] += ax[body_index] * half_dt;
    vy[body_index] += ay[body_index] * half_dt;
    vz[body_index] += az[body_index] * half_dt;
}

__global__ static void compute_star_radius_kernel(
    const float *mass,
    const float *lum,
    const float *ci,
    float *radius,
    int num_bodies,
    float k_mass,
    float k_lum,
    float lum_weight,
    float radius_min,
    float radius_max)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= num_bodies) {
        return;
    }

    {
        float m = fmaxf(mass[i], 0.0f);
        float L = fmaxf(lum[i], 0.0f);
        float c = ci[i];
        float t_kelvin = 4600.0f * (1.0f / (0.92f * c + 1.7f) + 1.0f / (0.92f * c + 0.62f));
        float t_ratio;
        float r_mass;
        float r_lum;
        float r_star;

        if (!isfinite(t_kelvin) || t_kelvin < 1000.0f) {
            t_kelvin = 1000.0f;
        }

        t_ratio = t_kelvin / 5772.0f;
        r_mass = cbrtf(fmaxf(m, 1e-6f));
        r_lum = sqrtf(L) / (t_ratio * t_ratio);
        r_star = lerp_float(k_mass * r_mass, k_lum * r_lum, saturate_float(lum_weight));
        radius[i] = fminf(radius_max, fmaxf(radius_min, r_star));
    }
}

__global__ static void frustum_cull_spheres_kernel(
    const float *x,
    const float *y,
    const float *z,
    const float *radius,
    int num_bodies,
    CameraKernelParams cam,
    float near_plane,
    float far_plane,
    int *visible_indices,
    unsigned int *visible_count)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= num_bodies) {
        return;
    }

    {
        float3 body_pos = make_float3(x[i], y[i], z[i]);
        float3 rel = sub3(body_pos, cam.cam_pos);
        float cx = dot3(rel, cam.right);
        float cy = dot3(rel, cam.up);
        float cz = dot3(rel, cam.forward);
        float r = radius[i];

        float plane_left = cx + cz * cam.tan_half_fov_x;
        float plane_right = -cx + cz * cam.tan_half_fov_x;
        float plane_bottom = cy + cz * cam.tan_half_fov_y;
        float plane_top = -cy + cz * cam.tan_half_fov_y;
        float plane_near = cz - near_plane;
        float plane_far = far_plane - cz;

        if (plane_left < -r || plane_right < -r || plane_bottom < -r ||
            plane_top < -r || plane_near < -r || plane_far < -r) {
            return;
        }

        {
            unsigned int slot = atomicAdd(visible_count, 1U);
            visible_indices[slot] = i;
        }
    }
}

__global__ static void raytrace_spheres_kernel(
    const float *x,
    const float *y,
    const float *z,
    const float *radius,
    const float *lum,
    const float *ci,
    const int *visible_indices,
    int visible_count,
    int width,
    int height,
    CameraKernelParams cam,
    float exposure,
    float gamma,
    unsigned char *rgba)
{
    int px = blockIdx.x * blockDim.x + threadIdx.x;
    int py = blockIdx.y * blockDim.y + threadIdx.y;

    if (px >= width || py >= height) {
        return;
    }

    {
        float x_ndc = 2.0f * ((float)px + 0.5f) / (float)width - 1.0f;
        float y_ndc = 1.0f - 2.0f * ((float)py + 0.5f) / (float)height;
        float3 ray_origin = cam.cam_pos;
        float3 ray_dir_cam = normalize3(make_float3(x_ndc * cam.tan_half_fov_x, y_ndc * cam.tan_half_fov_y, 1.0f));
        float3 ray_dir;
        float t_best = 1e30f;
        int hit_index = -1;

        ray_dir = normalize3(add3(add3(mul3(cam.right, ray_dir_cam.x), mul3(cam.up, ray_dir_cam.y)), mul3(cam.forward, ray_dir_cam.z)));

        for (int k = 0; k < visible_count; ++k) {
            int star_idx = visible_indices[k];
            float3 center = make_float3(x[star_idx], y[star_idx], z[star_idx]);
            float3 oc = sub3(ray_origin, center);
            float b = dot3(oc, ray_dir);
            float c = dot3(oc, oc) - radius[star_idx] * radius[star_idx];
            float discriminant = b * b - c;

            if (discriminant >= 0.0f) {
                float root = sqrtf(discriminant);
                float t_hit = -b - root;

                if (t_hit < 1e-3f) {
                    t_hit = -b + root;
                }

                if (t_hit >= 1e-3f && t_hit < t_best) {
                    t_best = t_hit;
                    hit_index = star_idx;
                }
            }
        }

        {
            int out_index = (py * width + px) * 4;
            float out_r = 0.0f;
            float out_g = 0.0f;
            float out_b = 0.0f;

            if (hit_index >= 0) {
                float3 center = make_float3(x[hit_index], y[hit_index], z[hit_index]);
                float3 hit_point = add3(ray_origin, mul3(ray_dir, t_best));
                float3 normal = normalize3(sub3(hit_point, center));
                float lambert = fmaxf(0.0f, dot3(normal, mul3(ray_dir, -1.0f)));
                float star_r;
                float star_g;
                float star_b;
                float intensity = exposure * log1pf(fmaxf(lum[hit_index], 0.0f));
                float shading = 0.15f + 0.85f * lambert;
                float inv_gamma = 1.0f / gamma;

                color_from_ci(ci[hit_index], &star_r, &star_g, &star_b);

                out_r = powf(saturate_float(1.0f - expf(-(star_r * intensity * shading))), inv_gamma);
                out_g = powf(saturate_float(1.0f - expf(-(star_g * intensity * shading))), inv_gamma);
                out_b = powf(saturate_float(1.0f - expf(-(star_b * intensity * shading))), inv_gamma);
            }

            rgba[out_index + 0] = (unsigned char)(255.0f * out_r);
            rgba[out_index + 1] = (unsigned char)(255.0f * out_g);
            rgba[out_index + 2] = (unsigned char)(255.0f * out_b);
            rgba[out_index + 3] = 255;
        }
    }
}

__global__ static void clear_accumulation_kernel(float *accum_r, float *accum_g, float *accum_b, int pixel_count)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx >= pixel_count) {
        return;
    }

    accum_r[idx] = 0.0f;
    accum_g[idx] = 0.0f;
    accum_b[idx] = 0.0f;
}

__global__ static void rasterize_stars_kernel(
    const float *x,
    const float *y,
    const float *z,
    const float *radius,
    const float *lum,
    const float *ci,
    const int *visible_indices,
    int visible_count,
    int width,
    int height,
    CameraKernelParams cam,
    float exposure,
    float *accum_r,
    float *accum_g,
    float *accum_b)
{
    int star_list_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (star_list_index >= visible_count) {
        return;
    }

    {
        int star_idx = visible_indices[star_list_index];
        float3 body_pos = make_float3(x[star_idx], y[star_idx], z[star_idx]);
        float3 rel = sub3(body_pos, cam.cam_pos);
        float cx = dot3(rel, cam.right);
        float cy = dot3(rel, cam.up);
        float cz = dot3(rel, cam.forward);
        float depth;
        float screen_x;
        float screen_y;
        float radius_px;
        float sigma;
        float sigma2;
        float local_r;
        float local_g;
        float local_b;
        float intensity;
        int reach;
        int min_x;
        int max_x;
        int min_y;
        int max_y;

        if (cz <= RENDER_NEAR_PLANE) {
            return;
        }

        depth = cz;
        screen_x = (float)width * 0.5f + (cx / depth) * cam.focal_y;
        screen_y = (float)height * 0.5f - (cy / depth) * cam.focal_y;

        radius_px = RASTER_RADIUS_SCALE_PX * (radius[star_idx] * cam.focal_y / fmaxf(depth, 1e-6f));
        radius_px = fminf(RASTER_MAX_RADIUS_PX, fmaxf(RASTER_MIN_RADIUS_PX, radius_px));
        sigma = fmaxf(0.75f, 0.5f * radius_px);
        sigma2 = sigma * sigma;
        reach = (int)ceilf(3.0f * sigma);

        min_x = (int)floorf(screen_x) - reach;
        max_x = (int)floorf(screen_x) + reach;
        min_y = (int)floorf(screen_y) - reach;
        max_y = (int)floorf(screen_y) + reach;

        if (max_x < 0 || min_x >= width || max_y < 0 || min_y >= height) {
            return;
        }

        if (min_x < 0) min_x = 0;
        if (min_y < 0) min_y = 0;
        if (max_x >= width) max_x = width - 1;
        if (max_y >= height) max_y = height - 1;

        color_from_ci(ci[star_idx], &local_r, &local_g, &local_b);
        intensity = exposure * log1pf(fmaxf(lum[star_idx], 0.0f));
        intensity = intensity / (1.0f + RASTER_DEPTH_ATTEN * depth * depth);

        for (int py = min_y; py <= max_y; ++py) {
            for (int px = min_x; px <= max_x; ++px) {
                float dx = ((float)px + 0.5f) - screen_x;
                float dy = ((float)py + 0.5f) - screen_y;
                float r2 = dx * dx + dy * dy;
                float weight;
                float contrib;
                int pixel_index;

                if (r2 > (9.0f * sigma2)) {
                    continue;
                }

                weight = expf(-r2 / (2.0f * sigma2));
                contrib = intensity * weight;
                pixel_index = py * width + px;

                atomicAdd(&accum_r[pixel_index], local_r * contrib);
                atomicAdd(&accum_g[pixel_index], local_g * contrib);
                atomicAdd(&accum_b[pixel_index], local_b * contrib);
            }
        }
    }
}

__global__ static void tone_map_accumulation_kernel(
    const float *accum_r,
    const float *accum_g,
    const float *accum_b,
    unsigned char *rgba,
    int pixel_count,
    float gamma)
{
    int pixel_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (pixel_index >= pixel_count) {
        return;
    }

    {
        float mapped_r = 1.0f - expf(-accum_r[pixel_index]);
        float mapped_g = 1.0f - expf(-accum_g[pixel_index]);
        float mapped_b = 1.0f - expf(-accum_b[pixel_index]);
        float inv_gamma = gamma > 0.0f ? (1.0f / gamma) : 1.0f;
        int output_index = pixel_index * 4;

        mapped_r = powf(saturate_float(mapped_r), inv_gamma);
        mapped_g = powf(saturate_float(mapped_g), inv_gamma);
        mapped_b = powf(saturate_float(mapped_b), inv_gamma);

        rgba[output_index + 0] = (unsigned char)(mapped_r * 255.0f);
        rgba[output_index + 1] = (unsigned char)(mapped_g * 255.0f);
        rgba[output_index + 2] = (unsigned char)(mapped_b * 255.0f);
        rgba[output_index + 3] = 255;
    }
}

__global__ static void copy_rgba_kernel(const unsigned char *src_rgba, unsigned char *dst_rgba, int byte_count)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx >= byte_count) {
        return;
    }

    dst_rgba[idx] = src_rgba[idx];
}

static int allocate_device_buffer(float **buffer, int num_bodies)
{
    return cudaMalloc((void **)buffer, (size_t)num_bodies * sizeof(float)) == cudaSuccess;
}

static void free_transient_buffers(
    float *mass,
    float *x,
    float *y,
    float *z,
    float *ax,
    float *ay,
    float *az)
{
    cudaFree(mass);
    cudaFree(x);
    cudaFree(y);
    cudaFree(z);
    cudaFree(ax);
    cudaFree(ay);
    cudaFree(az);
}

static void free_simulation_buffers(void)
{
    cudaFree(g_sim_mass);
    cudaFree(g_sim_x);
    cudaFree(g_sim_y);
    cudaFree(g_sim_z);
    cudaFree(g_sim_vx);
    cudaFree(g_sim_vy);
    cudaFree(g_sim_vz);
    cudaFree(g_sim_ax);
    cudaFree(g_sim_ay);
    cudaFree(g_sim_az);
    cudaFree(g_sim_radius);
    cudaFree(g_sim_lum);
    cudaFree(g_sim_ci);

    g_sim_mass = NULL;
    g_sim_x = NULL;
    g_sim_y = NULL;
    g_sim_z = NULL;
    g_sim_vx = NULL;
    g_sim_vy = NULL;
    g_sim_vz = NULL;
    g_sim_ax = NULL;
    g_sim_ay = NULL;
    g_sim_az = NULL;
    g_sim_radius = NULL;
    g_sim_lum = NULL;
    g_sim_ci = NULL;
    g_sim_capacity = 0;
    g_sim_num_bodies = 0;
}

static void free_render_buffers(void)
{
    if (g_gl_pbo_resource != NULL) {
        cudaGraphicsUnregisterResource(g_gl_pbo_resource);
        g_gl_pbo_resource = NULL;
    }
    g_gl_pbo_width = 0;
    g_gl_pbo_height = 0;

    cudaFree(g_accum_r);
    cudaFree(g_accum_g);
    cudaFree(g_accum_b);
    cudaFree(g_device_rgba);
    cudaFree(g_visible_indices);
    cudaFree(g_visible_count);
    if (g_host_rgba != NULL) {
        cudaFreeHost(g_host_rgba);
    }
    if (g_render_stream != NULL) {
        cudaStreamDestroy(g_render_stream);
    }

    g_accum_r = NULL;
    g_accum_g = NULL;
    g_accum_b = NULL;
    g_device_rgba = NULL;
    g_visible_indices = NULL;
    g_visible_count = NULL;
    g_host_rgba = NULL;
    g_render_stream = NULL;
    g_renderer_width = 0;
    g_renderer_height = 0;
    g_renderer_capacity = 0;
}

extern "C" int compute_accelerations_cuda(SystemOfBodies *system, int num_bodies)
{
    float *device_mass = NULL;
    float *device_x = NULL;
    float *device_y = NULL;
    float *device_z = NULL;
    float *device_ax = NULL;
    float *device_ay = NULL;
    float *device_az = NULL;
    int block_size = NBODY_BLOCK_SIZE;
    int grid_size = (num_bodies + block_size - 1) / block_size;

    if (!allocate_device_buffer(&device_mass, num_bodies) ||
        !allocate_device_buffer(&device_x, num_bodies) ||
        !allocate_device_buffer(&device_y, num_bodies) ||
        !allocate_device_buffer(&device_z, num_bodies) ||
        !allocate_device_buffer(&device_ax, num_bodies) ||
        !allocate_device_buffer(&device_ay, num_bodies) ||
        !allocate_device_buffer(&device_az, num_bodies)) {
        free_transient_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    if (cudaMemcpy(device_mass, system->mass, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(device_x, system->x, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(device_y, system->y, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(device_z, system->z, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess) {
        free_transient_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    compute_accelerations_kernel<<<grid_size, block_size>>>(
        device_mass,
        device_x,
        device_y,
        device_z,
        device_ax,
        device_ay,
        device_az,
        num_bodies);

    if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
        free_transient_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    if (cudaMemcpy(system->ax, device_ax, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->ay, device_ay, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->az, device_az, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess) {
        free_transient_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    free_transient_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
    return 1;
}

extern "C" int initialize_cuda_simulation(const SystemOfBodies *system, int num_bodies)
{
    if (system == NULL || num_bodies <= 0) {
        return 0;
    }

    if (g_sim_capacity < num_bodies) {
        free_simulation_buffers();
        if (!allocate_device_buffer(&g_sim_mass, num_bodies) ||
            !allocate_device_buffer(&g_sim_x, num_bodies) ||
            !allocate_device_buffer(&g_sim_y, num_bodies) ||
            !allocate_device_buffer(&g_sim_z, num_bodies) ||
            !allocate_device_buffer(&g_sim_vx, num_bodies) ||
            !allocate_device_buffer(&g_sim_vy, num_bodies) ||
            !allocate_device_buffer(&g_sim_vz, num_bodies) ||
            !allocate_device_buffer(&g_sim_ax, num_bodies) ||
            !allocate_device_buffer(&g_sim_ay, num_bodies) ||
            !allocate_device_buffer(&g_sim_az, num_bodies) ||
            !allocate_device_buffer(&g_sim_radius, num_bodies) ||
            !allocate_device_buffer(&g_sim_lum, num_bodies) ||
            !allocate_device_buffer(&g_sim_ci, num_bodies)) {
            free_simulation_buffers();
            return 0;
        }
        g_sim_capacity = num_bodies;
    }

    if (cudaMemcpy(g_sim_mass, system->mass, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_x, system->x, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_y, system->y, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_z, system->z, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_vx, system->vx, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_vy, system->vy, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_vz, system->vz, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_ax, system->ax, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_ay, system->ay, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_az, system->az, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_lum, system->lum, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(g_sim_ci, system->ci, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess) {
        return 0;
    }

    {
        int grid_size = (num_bodies + NBODY_BLOCK_SIZE - 1) / NBODY_BLOCK_SIZE;
        compute_star_radius_kernel<<<grid_size, 256>>>(
            g_sim_mass,
            g_sim_lum,
            g_sim_ci,
            g_sim_radius,
            num_bodies,
            RADIUS_SCALE_MASS,
            RADIUS_SCALE_LUM,
            RADIUS_BLEND_LUM,
            RADIUS_MIN,
            RADIUS_MAX);

        if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
            return 0;
        }
    }

    g_sim_num_bodies = num_bodies;
    return 1;
}

extern "C" void shutdown_cuda_simulation(void)
{
    free_simulation_buffers();
}

extern "C" int sync_cuda_system_to_host(SystemOfBodies *system, int num_bodies)
{
    if (system == NULL || num_bodies <= 0 || g_sim_capacity < num_bodies || g_sim_num_bodies != num_bodies) {
        return 0;
    }

    if (cudaMemcpy(system->x, g_sim_x, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->y, g_sim_y, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->z, g_sim_z, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->vx, g_sim_vx, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->vy, g_sim_vy, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->vz, g_sim_vz, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->ax, g_sim_ax, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->ay, g_sim_ay, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->az, g_sim_az, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->radius, g_sim_radius, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess) {
        return 0;
    }

    return 1;
}

static int compute_accelerations_selected_cuda(SystemOfBodies *system, int num_bodies, int grid_size)
{
    if (g_cuda_solver_mode == SOLVER_BH) {
        if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
            return 0;
        }

        if (!sync_cuda_system_to_host(system, num_bodies)) {
            return 0;
        }

        compute_accelerations_bh(system, num_bodies, g_cuda_solver_theta);

        if (cudaMemcpy(g_sim_ax, system->ax, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
            cudaMemcpy(g_sim_ay, system->ay, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
            cudaMemcpy(g_sim_az, system->az, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess) {
            return 0;
        }

        return 1;
    }

    if (g_cuda_solver_mode == SOLVER_FMM) {
        /* Phase 2A: FMM still falls back to direct CUDA path until Phase 2B kernels land. */
    }

    compute_accelerations_kernel<<<grid_size, NBODY_BLOCK_SIZE>>>(
        g_sim_mass,
        g_sim_x,
        g_sim_y,
        g_sim_z,
        g_sim_ax,
        g_sim_ay,
        g_sim_az,
        num_bodies);

    return 1;
}

extern "C" int step_cuda_simulation(SystemOfBodies *system, int num_bodies, float dt, int sync_to_host)
{
    int grid_size;

    if (system == NULL || num_bodies <= 0 || g_sim_capacity < num_bodies || g_sim_num_bodies != num_bodies) {
        return 0;
    }

    grid_size = (num_bodies + NBODY_BLOCK_SIZE - 1) / NBODY_BLOCK_SIZE;

    if (!compute_accelerations_selected_cuda(system, num_bodies, grid_size)) {
        return 0;
    }

    if (g_cuda_integrator_mode == INTEGRATOR_LEAPFROG) {
        integrate_kick_drift_kernel<<<grid_size, 256>>>(
            g_sim_x,
            g_sim_y,
            g_sim_z,
            g_sim_vx,
            g_sim_vy,
            g_sim_vz,
            g_sim_ax,
            g_sim_ay,
            g_sim_az,
            num_bodies,
            dt);

        if (!compute_accelerations_selected_cuda(system, num_bodies, grid_size)) {
            return 0;
        }

        integrate_kick_finish_kernel<<<grid_size, 256>>>(
            g_sim_vx,
            g_sim_vy,
            g_sim_vz,
            g_sim_ax,
            g_sim_ay,
            g_sim_az,
            num_bodies,
            dt);
    } else {
        integrate_kernel<<<grid_size, 256>>>(
            g_sim_x,
            g_sim_y,
            g_sim_z,
            g_sim_vx,
            g_sim_vy,
            g_sim_vz,
            g_sim_ax,
            g_sim_ay,
            g_sim_az,
            num_bodies,
            dt);
    }

    if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
        return 0;
    }

    if (sync_to_host) {
        return sync_cuda_system_to_host(system, num_bodies);
    }

    return 1;
}

extern "C" int set_cuda_integrator_mode(IntegratorMode mode)
{
    if (mode != INTEGRATOR_EULER && mode != INTEGRATOR_LEAPFROG) {
        return 0;
    }

    g_cuda_integrator_mode = mode;
    return 1;
}

extern "C" IntegratorMode get_cuda_integrator_mode(void)
{
    return g_cuda_integrator_mode;
}

extern "C" int set_cuda_solver_mode(SolverMode mode)
{
    if (mode != SOLVER_DIRECT && mode != SOLVER_BH && mode != SOLVER_FMM) {
        return 0;
    }

    g_cuda_solver_mode = mode;
    return 1;
}

extern "C" SolverMode get_cuda_solver_mode(void)
{
    return g_cuda_solver_mode;
}

extern "C" int set_cuda_solver_theta(float theta)
{
    if (theta <= 0.0f) {
        return 0;
    }

    g_cuda_solver_theta = theta;
    return 1;
}

extern "C" float get_cuda_solver_theta(void)
{
    return g_cuda_solver_theta;
}

extern "C" int initialize_cuda_renderer(int max_bodies, int width, int height)
{
    size_t pixel_count;

    if (max_bodies <= 0 || width <= 0 || height <= 0) {
        return 0;
    }

    if (g_renderer_capacity == max_bodies && g_renderer_width == width && g_renderer_height == height) {
        return 1;
    }

    free_render_buffers();
    pixel_count = (size_t)width * (size_t)height;

    if (cudaStreamCreate(&g_render_stream) != cudaSuccess ||
        cudaMalloc((void **)&g_accum_r, pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&g_accum_g, pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&g_accum_b, pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&g_device_rgba, pixel_count * 4 * sizeof(unsigned char)) != cudaSuccess ||
        cudaMalloc((void **)&g_visible_indices, (size_t)max_bodies * sizeof(int)) != cudaSuccess ||
        cudaMalloc((void **)&g_visible_count, sizeof(unsigned int)) != cudaSuccess) {
        free_render_buffers();
        return 0;
    }

    if (cudaHostAlloc((void **)&g_host_rgba, pixel_count * 4 * sizeof(unsigned char), cudaHostAllocDefault) != cudaSuccess) {
        g_host_rgba = NULL;
        free_render_buffers();
        return 0;
    }

    g_renderer_capacity = max_bodies;
    g_renderer_width = width;
    g_renderer_height = height;
    return 1;
}

extern "C" void shutdown_cuda_renderer(void)
{
    free_render_buffers();
}

extern "C" int set_cuda_render_mode(CudaRenderMode mode)
{
    if (mode != CUDA_RENDER_MODE_RAYTRACE && mode != CUDA_RENDER_MODE_RASTER) {
        return 0;
    }

    g_render_mode = mode;
    return 1;
}

extern "C" CudaRenderMode get_cuda_render_mode(void)
{
    return g_render_mode;
}

extern "C" int bind_cuda_render_pbo(unsigned int pbo, int width, int height)
{
    if (pbo == 0 || width <= 0 || height <= 0) {
        return 0;
    }

    if (g_gl_pbo_resource != NULL) {
        cudaGraphicsUnregisterResource(g_gl_pbo_resource);
        g_gl_pbo_resource = NULL;
    }

    if (cudaGraphicsGLRegisterBuffer(&g_gl_pbo_resource, pbo, cudaGraphicsMapFlagsWriteDiscard) != cudaSuccess) {
        g_gl_pbo_resource = NULL;
        g_gl_pbo_width = 0;
        g_gl_pbo_height = 0;
        return 0;
    }

    g_gl_pbo_width = width;
    g_gl_pbo_height = height;
    return 1;
}

extern "C" void unbind_cuda_render_pbo(void)
{
    if (g_gl_pbo_resource != NULL) {
        cudaGraphicsUnregisterResource(g_gl_pbo_resource);
        g_gl_pbo_resource = NULL;
    }
    g_gl_pbo_width = 0;
    g_gl_pbo_height = 0;
}

extern "C" int render_current_frame_cuda(const RenderCamera *camera, float exposure, float gamma)
{
    int body_grid_size;
    int pixel_count;
    int pixel_grid_size;
    dim3 block_2d;
    dim3 grid_2d;
    RenderCamera local_camera;
    CameraKernelParams cam_params;
    float aspect;
    unsigned int visible_count = 0;

    if (camera == NULL || g_sim_num_bodies <= 0 || g_renderer_width <= 0 || g_renderer_height <= 0 ||
        g_device_rgba == NULL || g_host_rgba == NULL || g_visible_indices == NULL || g_visible_count == NULL || g_sim_radius == NULL || g_render_stream == NULL) {
        return 0;
    }

    if (g_render_mode == CUDA_RENDER_MODE_RASTER && (g_accum_r == NULL || g_accum_g == NULL || g_accum_b == NULL)) {
        return 0;
    }

    local_camera = *camera;
    if (local_camera.fov < 20.0f) {
        local_camera.fov = 20.0f;
    }
    if (local_camera.fov > 120.0f) {
        local_camera.fov = 120.0f;
    }
    if (exposure < 0.05f) {
        exposure = 0.05f;
    }
    if (exposure > 20.0f) {
        exposure = 20.0f;
    }
    if (gamma < 0.5f) {
        gamma = 0.5f;
    }
    if (gamma > 4.0f) {
        gamma = 4.0f;
    }

    pixel_count = g_renderer_width * g_renderer_height;
    body_grid_size = (g_sim_num_bodies + NBODY_BLOCK_SIZE - 1) / NBODY_BLOCK_SIZE;
    pixel_grid_size = (pixel_count + 255) / 256;
    aspect = (float)g_renderer_width / (float)g_renderer_height;

    {
        float zoom = fmaxf(local_camera.zoom, 0.1f);
        compute_camera_basis(local_camera, &cam_params.right, &cam_params.up, &cam_params.forward);
        cam_params.cam_pos = make_float3(local_camera.x, local_camera.y, local_camera.z);
        cam_params.tan_half_fov_y = tanf(0.5f * local_camera.fov * DEG_TO_RAD) / zoom;
        cam_params.tan_half_fov_x = cam_params.tan_half_fov_y * aspect;
        cam_params.focal_y = (0.5f * (float)g_renderer_height) / fmaxf(cam_params.tan_half_fov_y, 1e-6f);
    }

    {
        cudaEvent_t ev_start;
        cudaEvent_t ev_cull_done;
        cudaEvent_t ev_trace_done;
        float cull_ms = 0.0f;
        float trace_ms = 0.0f;
        int timing_ok;

        timing_ok = (cudaEventCreate(&ev_start) == cudaSuccess &&
                     cudaEventCreate(&ev_cull_done) == cudaSuccess &&
                     cudaEventCreate(&ev_trace_done) == cudaSuccess);

        if (cudaMemsetAsync(g_visible_count, 0, sizeof(unsigned int), g_render_stream) != cudaSuccess) {
            if (timing_ok) {
                cudaEventDestroy(ev_start);
                cudaEventDestroy(ev_cull_done);
                cudaEventDestroy(ev_trace_done);
            }
            return 0;
        }

        if (timing_ok) { cudaEventRecord(ev_start, g_render_stream); }

        frustum_cull_spheres_kernel<<<body_grid_size, NBODY_BLOCK_SIZE, 0, g_render_stream>>>(
            g_sim_x,
            g_sim_y,
            g_sim_z,
            g_sim_radius,
            g_sim_num_bodies,
            cam_params,
            RENDER_NEAR_PLANE,
            RENDER_FAR_PLANE,
            g_visible_indices,
            g_visible_count);

        if (timing_ok) { cudaEventRecord(ev_cull_done, g_render_stream); }

        if (cudaGetLastError() != cudaSuccess) {
            if (timing_ok) {
                cudaEventDestroy(ev_start);
                cudaEventDestroy(ev_cull_done);
                cudaEventDestroy(ev_trace_done);
            }
            return 0;
        }

        if (cudaMemcpyAsync(&visible_count, g_visible_count, sizeof(unsigned int), cudaMemcpyDeviceToHost, g_render_stream) != cudaSuccess ||
            cudaStreamSynchronize(g_render_stream) != cudaSuccess) {
            if (timing_ok) {
                cudaEventDestroy(ev_start);
                cudaEventDestroy(ev_cull_done);
                cudaEventDestroy(ev_trace_done);
            }
            return 0;
        }

        if (g_render_mode == CUDA_RENDER_MODE_RASTER) {
            clear_accumulation_kernel<<<pixel_grid_size, 256, 0, g_render_stream>>>(
                g_accum_r,
                g_accum_g,
                g_accum_b,
                pixel_count);

            rasterize_stars_kernel<<<body_grid_size, NBODY_BLOCK_SIZE, 0, g_render_stream>>>(
                g_sim_x,
                g_sim_y,
                g_sim_z,
                g_sim_radius,
                g_sim_lum,
                g_sim_ci,
                g_visible_indices,
                (int)visible_count,
                g_renderer_width,
                g_renderer_height,
                cam_params,
                exposure,
                g_accum_r,
                g_accum_g,
                g_accum_b);

            tone_map_accumulation_kernel<<<pixel_grid_size, 256, 0, g_render_stream>>>(
                g_accum_r,
                g_accum_g,
                g_accum_b,
                g_device_rgba,
                pixel_count,
                gamma);
        } else {
            block_2d = dim3(16, 16);
            grid_2d = dim3((unsigned int)((g_renderer_width + 15) / 16), (unsigned int)((g_renderer_height + 15) / 16));

            raytrace_spheres_kernel<<<grid_2d, block_2d, 0, g_render_stream>>>(
                g_sim_x,
                g_sim_y,
                g_sim_z,
                g_sim_radius,
                g_sim_lum,
                g_sim_ci,
                g_visible_indices,
                (int)visible_count,
                g_renderer_width,
                g_renderer_height,
                cam_params,
                exposure,
                gamma,
                g_device_rgba);
        }

        if (timing_ok) { cudaEventRecord(ev_trace_done, g_render_stream); }

        if (cudaGetLastError() != cudaSuccess || cudaStreamSynchronize(g_render_stream) != cudaSuccess) {
            if (timing_ok) {
                cudaEventDestroy(ev_start);
                cudaEventDestroy(ev_cull_done);
                cudaEventDestroy(ev_trace_done);
            }
            return 0;
        }

        if (timing_ok) {
            cudaEventElapsedTime(&cull_ms, ev_start, ev_cull_done);
            cudaEventElapsedTime(&trace_ms, ev_cull_done, ev_trace_done);
            cudaEventDestroy(ev_start);
            cudaEventDestroy(ev_cull_done);
            cudaEventDestroy(ev_trace_done);
        }

        g_last_telemetry.visible_count = visible_count;
        g_last_telemetry.cull_ms = cull_ms;
        g_last_telemetry.trace_ms = trace_ms;
    }

    if (g_gl_pbo_resource != NULL && g_gl_pbo_width == g_renderer_width && g_gl_pbo_height == g_renderer_height) {
        unsigned char *pbo_device_ptr = NULL;
        size_t pbo_size = 0;
        int byte_count = pixel_count * 4;
        int copy_grid_size = (byte_count + 255) / 256;

        if (cudaGraphicsMapResources(1, &g_gl_pbo_resource, g_render_stream) != cudaSuccess ||
            cudaGraphicsResourceGetMappedPointer((void **)&pbo_device_ptr, &pbo_size, g_gl_pbo_resource) != cudaSuccess ||
            pbo_device_ptr == NULL || pbo_size < (size_t)byte_count) {
            cudaGraphicsUnmapResources(1, &g_gl_pbo_resource, g_render_stream);
            return 0;
        }

        copy_rgba_kernel<<<copy_grid_size, 256, 0, g_render_stream>>>(g_device_rgba, pbo_device_ptr, byte_count);

        if (cudaGetLastError() != cudaSuccess ||
            cudaGraphicsUnmapResources(1, &g_gl_pbo_resource, g_render_stream) != cudaSuccess ||
            cudaStreamSynchronize(g_render_stream) != cudaSuccess) {
            return 0;
        }
    } else {
        if (cudaMemcpyAsync(g_host_rgba, g_device_rgba, (size_t)pixel_count * 4 * sizeof(unsigned char), cudaMemcpyDeviceToHost, g_render_stream) != cudaSuccess ||
            cudaStreamSynchronize(g_render_stream) != cudaSuccess) {
            return 0;
        }
    }

    return 1;
}

extern "C" void get_last_render_telemetry(RenderTelemetry *out)
{
    if (out != NULL) {
        *out = g_last_telemetry;
    }
}

extern "C" int write_current_render_png(const char *output_path)
{
    if (output_path == NULL || g_host_rgba == NULL || g_renderer_width <= 0 || g_renderer_height <= 0) {
        return 0;
    }

    if (g_device_rgba != NULL && g_render_stream != NULL) {
        size_t byte_count = (size_t)g_renderer_width * (size_t)g_renderer_height * 4 * sizeof(unsigned char);
        if (cudaMemcpyAsync(g_host_rgba, g_device_rgba, byte_count, cudaMemcpyDeviceToHost, g_render_stream) != cudaSuccess ||
            cudaStreamSynchronize(g_render_stream) != cudaSuccess) {
            return 0;
        }
    }

    return write_png_rgba(output_path, g_host_rgba, g_renderer_width, g_renderer_height);
}

extern "C" const unsigned char *get_cuda_render_rgba(int *width, int *height)
{
    if (width != NULL) {
        *width = g_renderer_width;
    }
    if (height != NULL) {
        *height = g_renderer_height;
    }
    if (g_gl_pbo_resource != NULL) {
        return NULL;
    }

    return g_host_rgba;
}

extern "C" int render_frame_cuda(
    const SystemOfBodies *system,
    int num_bodies,
    const RenderCamera *camera,
    float exposure,
    float gamma,
    const char *output_path)
{
    if (!initialize_cuda_simulation(system, num_bodies)) {
        return 0;
    }
    if (!render_current_frame_cuda(camera, exposure, gamma)) {
        return 0;
    }
    return write_current_render_png(output_path);
}
