#include <cuda_runtime.h>
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
static float *g_sim_lum = NULL;
static float *g_sim_ci = NULL;
static int g_sim_capacity = 0;
static int g_sim_num_bodies = 0;

static float *g_accum_r = NULL;
static float *g_accum_g = NULL;
static float *g_accum_b = NULL;
static unsigned char *g_device_rgba = NULL;
static unsigned char *g_host_rgba = NULL;
static int g_renderer_width = 0;
static int g_renderer_height = 0;
static int g_renderer_capacity = 0;

__device__ static float saturate_float(float value)
{
    if (value < 0.0f) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

__device__ static float lerp_float(float a, float b, float t)
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

__global__ static void compute_accelerations_kernel(
    const float *mass,
    const float *x,
    const float *y,
    const float *z,
    float *ax,
    float *ay,
    float *az,
    int num_bodies)
{
    int body_index = blockIdx.x * blockDim.x + threadIdx.x;
    float local_ax = 0.0f;
    float local_ay = 0.0f;
    float local_az = 0.0f;
    int other_index;

    if (body_index >= num_bodies) {
        return;
    }

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

        dx = x[other_index] - x[body_index];
        dy = y[other_index] - y[body_index];
        dz = z[other_index] - z[body_index];

        distance_squared = dx * dx + dy * dy + dz * dz + SOFTENING;
        inverse_distance = rsqrtf(distance_squared);
        inverse_distance_cubed = inverse_distance * inverse_distance * inverse_distance;
        scale = G_CONSTANT * mass[other_index] * inverse_distance_cubed;

        local_ax += dx * scale;
        local_ay += dy * scale;
        local_az += dz * scale;
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

__global__ static void render_bodies_kernel(
    const float *x,
    const float *y,
    const float *z,
    const float *lum,
    const float *ci,
    float *accum_r,
    float *accum_g,
    float *accum_b,
    int num_bodies,
    int width,
    int height,
    RenderCamera camera,
    float exposure)
{
    int body_index = blockIdx.x * blockDim.x + threadIdx.x;
    float yaw_rad;
    float pitch_rad;
    float cos_yaw;
    float sin_yaw;
    float cos_pitch;
    float sin_pitch;

    if (body_index >= num_bodies) {
        return;
    }

    yaw_rad = camera.yaw * 0.01745329252f;
    pitch_rad = camera.pitch * 0.01745329252f;
    cos_yaw = cosf(yaw_rad);
    sin_yaw = sinf(yaw_rad);
    cos_pitch = cosf(pitch_rad);
    sin_pitch = sinf(pitch_rad);

    {
        float dx = x[body_index] - camera.x;
        float dy = y[body_index] - camera.y;
        float dz = z[body_index] - camera.z;
        float rotated_x = cos_yaw * dx - sin_yaw * dz;
        float rotated_z = sin_yaw * dx + cos_yaw * dz;
        float rotated_y = cos_pitch * dy + sin_pitch * rotated_z;
        float camera_z = -sin_pitch * dy + cos_pitch * rotated_z;
        float depth = -camera_z;
        float focal;

        if (depth <= 0.1f) {
            return;
        }

        focal = (0.5f * (float)width / tanf(camera.fov * 0.5f * 0.01745329252f)) * camera.zoom;

        {
            float screen_x = (float)width * 0.5f + (rotated_x / depth) * focal;
            float screen_y = (float)height * 0.5f - (rotated_y / depth) * focal;
            float local_r;
            float local_g;
            float local_b;
            float brightness = exposure * log1pf(fmaxf(lum[body_index], 0.0f));
            int radius;
            int center_x;
            int center_y;

            if (screen_x < -4.0f || screen_x > (float)width + 4.0f || screen_y < -4.0f || screen_y > (float)height + 4.0f) {
                return;
            }

            color_from_ci(ci[body_index], &local_r, &local_g, &local_b);
            radius = (int)(1.0f + fminf(3.0f, brightness * 1.5f));
            center_x = (int)(screen_x + 0.5f);
            center_y = (int)(screen_y + 0.5f);

            for (int offset_y = -radius; offset_y <= radius; ++offset_y) {
                for (int offset_x = -radius; offset_x <= radius; ++offset_x) {
                    int pixel_x = center_x + offset_x;
                    int pixel_y = center_y + offset_y;

                    if (pixel_x >= 0 && pixel_x < width && pixel_y >= 0 && pixel_y < height) {
                        float dist2 = (float)(offset_x * offset_x + offset_y * offset_y);
                        float weight = brightness / (1.0f + dist2 * 0.75f + depth * 0.002f);
                        int pixel_index = pixel_y * width + pixel_x;

                        atomicAdd(&accum_r[pixel_index], local_r * weight);
                        atomicAdd(&accum_g[pixel_index], local_g * weight);
                        atomicAdd(&accum_b[pixel_index], local_b * weight);
                    }
                }
            }
        }
    }
}

__global__ static void tone_map_kernel(
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
    g_sim_lum = NULL;
    g_sim_ci = NULL;
    g_sim_capacity = 0;
    g_sim_num_bodies = 0;
}

static void free_render_buffers(void)
{
    cudaFree(g_accum_r);
    cudaFree(g_accum_g);
    cudaFree(g_accum_b);
    cudaFree(g_device_rgba);
    free(g_host_rgba);

    g_accum_r = NULL;
    g_accum_g = NULL;
    g_accum_b = NULL;
    g_device_rgba = NULL;
    g_host_rgba = NULL;
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
    int block_size = 256;
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
        cudaMemcpy(system->az, g_sim_az, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess) {
        return 0;
    }

    return 1;
}

extern "C" int step_cuda_simulation(SystemOfBodies *system, int num_bodies, float dt, int sync_to_host)
{
    int grid_size;

    if (system == NULL || num_bodies <= 0 || g_sim_capacity < num_bodies || g_sim_num_bodies != num_bodies) {
        return 0;
    }

    grid_size = (num_bodies + 255) / 256;

    compute_accelerations_kernel<<<grid_size, 256>>>(
        g_sim_mass,
        g_sim_x,
        g_sim_y,
        g_sim_z,
        g_sim_ax,
        g_sim_ay,
        g_sim_az,
        num_bodies);

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

    if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
        return 0;
    }

    if (sync_to_host) {
        return sync_cuda_system_to_host(system, num_bodies);
    }

    return 1;
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

    if (cudaMalloc((void **)&g_accum_r, pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&g_accum_g, pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&g_accum_b, pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMalloc((void **)&g_device_rgba, pixel_count * 4 * sizeof(unsigned char)) != cudaSuccess) {
        free_render_buffers();
        return 0;
    }

    g_host_rgba = (unsigned char *)malloc(pixel_count * 4 * sizeof(unsigned char));
    if (g_host_rgba == NULL) {
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

extern "C" int render_current_frame_cuda(const RenderCamera *camera, float exposure, float gamma)
{
    int body_grid_size;
    int pixel_count;
    int pixel_grid_size;
    RenderCamera local_camera;

    if (camera == NULL || g_sim_num_bodies <= 0 || g_renderer_width <= 0 || g_renderer_height <= 0 ||
        g_accum_r == NULL || g_accum_g == NULL || g_accum_b == NULL || g_device_rgba == NULL || g_host_rgba == NULL) {
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
    body_grid_size = (g_sim_num_bodies + 255) / 256;
    pixel_grid_size = (pixel_count + 255) / 256;

    if (cudaMemset(g_accum_r, 0, (size_t)pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMemset(g_accum_g, 0, (size_t)pixel_count * sizeof(float)) != cudaSuccess ||
        cudaMemset(g_accum_b, 0, (size_t)pixel_count * sizeof(float)) != cudaSuccess) {
        return 0;
    }

    render_bodies_kernel<<<body_grid_size, 256>>>(
        g_sim_x,
        g_sim_y,
        g_sim_z,
        g_sim_lum,
        g_sim_ci,
        g_accum_r,
        g_accum_g,
        g_accum_b,
        g_sim_num_bodies,
        g_renderer_width,
        g_renderer_height,
        local_camera,
        exposure);

    tone_map_kernel<<<pixel_grid_size, 256>>>(
        g_accum_r,
        g_accum_g,
        g_accum_b,
        g_device_rgba,
        pixel_count,
        gamma);

    if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
        return 0;
    }

    if (cudaMemcpy(g_host_rgba, g_device_rgba, (size_t)pixel_count * 4 * sizeof(unsigned char), cudaMemcpyDeviceToHost) != cudaSuccess) {
        return 0;
    }

    return 1;
}

extern "C" int write_current_render_png(const char *output_path)
{
    if (output_path == NULL || g_host_rgba == NULL || g_renderer_width <= 0 || g_renderer_height <= 0) {
        return 0;
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
