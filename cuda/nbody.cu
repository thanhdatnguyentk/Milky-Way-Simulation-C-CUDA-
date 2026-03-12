#include <cuda_runtime.h>

#include "cuda_nbody.h"
#include "simulation_config.h"

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

static int allocate_device_buffer(float **buffer, int num_bodies)
{
    return cudaMalloc((void **)buffer, (size_t)num_bodies * sizeof(float)) == cudaSuccess;
}

static void free_device_buffers(
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
        free_device_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    if (cudaMemcpy(device_mass, system->mass, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(device_x, system->x, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(device_y, system->y, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(device_z, system->z, (size_t)num_bodies * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess) {
        free_device_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
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
        num_bodies
    );

    if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
        free_device_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    if (cudaMemcpy(system->ax, device_ax, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->ay, device_ay, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(system->az, device_az, (size_t)num_bodies * sizeof(float), cudaMemcpyDeviceToHost) != cudaSuccess) {
        free_device_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
        return 0;
    }

    free_device_buffers(device_mass, device_x, device_y, device_z, device_ax, device_ay, device_az);
    return 1;
}