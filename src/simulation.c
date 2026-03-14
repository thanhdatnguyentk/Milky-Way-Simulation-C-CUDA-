#include <math.h>
#include <stdlib.h>

#include "simulation_config.h"
#include "simulation.h"

typedef struct {
    float center_x;
    float center_y;
    float center_z;
    float size;

    float total_mass;
    float cm_x;
    float cm_y;
    float cm_z;

    int children[8];
    int body_index;
} OctreeNode;

static OctreeNode *g_octree_pool = NULL;
static int g_octree_pool_capacity = 0;
static int g_octree_pool_used = 0;

static int node_is_leaf(const OctreeNode *node)
{
    int child;
    for (child = 0; child < 8; ++child) {
        if (node->children[child] != -1) {
            return 0;
        }
    }
    return 1;
}

static void init_node(int node_index, float center_x, float center_y, float center_z, float size)
{
    int child;
    OctreeNode *node = &g_octree_pool[node_index];

    node->center_x = center_x;
    node->center_y = center_y;
    node->center_z = center_z;
    node->size = size;

    node->total_mass = 0.0f;
    node->cm_x = center_x;
    node->cm_y = center_y;
    node->cm_z = center_z;
    node->body_index = -1;

    for (child = 0; child < 8; ++child) {
        node->children[child] = -1;
    }
}

static int ensure_octree_pool_capacity(int required_capacity)
{
    OctreeNode *new_pool;
    int new_capacity;

    if (required_capacity <= g_octree_pool_capacity) {
        return 1;
    }

    new_capacity = (g_octree_pool_capacity > 0) ? g_octree_pool_capacity : 1024;
    while (new_capacity < required_capacity) {
        new_capacity *= 2;
    }

    new_pool = (OctreeNode *)realloc(g_octree_pool, (size_t)new_capacity * sizeof(OctreeNode));
    if (new_pool == NULL) {
        return 0;
    }

    g_octree_pool = new_pool;
    g_octree_pool_capacity = new_capacity;
    return 1;
}

static void reset_octree_pool(void)
{
    g_octree_pool_used = 0;
}

static int alloc_node(void)
{
    int node_index;

    if (g_octree_pool_used >= g_octree_pool_capacity) {
        return -1;
    }

    node_index = g_octree_pool_used;
    ++g_octree_pool_used;
    return node_index;
}

static unsigned int mix_bits(unsigned int x)
{
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static int axis_octant_bit(float value, float center, int body_index, int depth, int axis_tag)
{
    if (value > center) {
        return 1;
    }
    if (value < center) {
        return 0;
    }

    return (int)((mix_bits((unsigned int)body_index ^ ((unsigned int)depth * 0x9e3779b9U) ^ (unsigned int)axis_tag) & 1U));
}

static int get_octant_for_body(const OctreeNode *node, const SystemOfBodies *system, int body_index, int depth)
{
    int x_bit = axis_octant_bit(system->x[body_index], node->center_x, body_index, depth, 0);
    int y_bit = axis_octant_bit(system->y[body_index], node->center_y, body_index, depth, 1);
    int z_bit = axis_octant_bit(system->z[body_index], node->center_z, body_index, depth, 2);

    return x_bit | (y_bit << 1) | (z_bit << 2);
}

static int ensure_child_node(int parent_index, int child_slot)
{
    OctreeNode *parent = &g_octree_pool[parent_index];
    int child_index = parent->children[child_slot];

    if (child_index != -1) {
        return child_index;
    }

    child_index = alloc_node();
    if (child_index == -1) {
        return -1;
    }

    {
        float quarter = parent->size * 0.25f;
        float child_center_x = parent->center_x + ((child_slot & 1) ? quarter : -quarter);
        float child_center_y = parent->center_y + ((child_slot & 2) ? quarter : -quarter);
        float child_center_z = parent->center_z + ((child_slot & 4) ? quarter : -quarter);
        float child_size = parent->size * 0.5f;

        init_node(child_index, child_center_x, child_center_y, child_center_z, child_size);
    }

    parent->children[child_slot] = child_index;
    return child_index;
}

static int insert_body(int node_index, int body_index, const SystemOfBodies *system, int depth)
{
    OctreeNode *node = &g_octree_pool[node_index];
    const int MAX_TREE_DEPTH = 64;

    if (node->body_index == -1 && node_is_leaf(node)) {
        node->body_index = body_index;
        return 1;
    }

    if (node->body_index != -1 && node_is_leaf(node)) {
        int existing_body = node->body_index;
        int old_slot;
        int new_slot;
        int old_child;
        int new_child;

        node->body_index = -1;

        if (depth >= MAX_TREE_DEPTH || node->size <= 1e-8f) {
            node->body_index = existing_body;
            return 0;
        }

        old_slot = get_octant_for_body(node, system, existing_body, depth);
        old_child = ensure_child_node(node_index, old_slot);
        if (old_child == -1 || !insert_body(old_child, existing_body, system, depth + 1)) {
            return 0;
        }

        new_slot = get_octant_for_body(node, system, body_index, depth);
        new_child = ensure_child_node(node_index, new_slot);
        if (new_child == -1 || !insert_body(new_child, body_index, system, depth + 1)) {
            return 0;
        }

        return 1;
    }

    {
        int slot = get_octant_for_body(node, system, body_index, depth);
        int child = ensure_child_node(node_index, slot);

        if (child == -1) {
            return 0;
        }

        return insert_body(child, body_index, system, depth + 1);
    }
}

static void compute_root_bounding_box(const SystemOfBodies *system, int num_bodies,
    float *center_x, float *center_y, float *center_z, float *size)
{
    int i;
    float min_x = system->x[0];
    float min_y = system->y[0];
    float min_z = system->z[0];
    float max_x = system->x[0];
    float max_y = system->y[0];
    float max_z = system->z[0];

    for (i = 1; i < num_bodies; ++i) {
        float x = system->x[i];
        float y = system->y[i];
        float z = system->z[i];

        if (x < min_x) min_x = x;
        if (y < min_y) min_y = y;
        if (z < min_z) min_z = z;
        if (x > max_x) max_x = x;
        if (y > max_y) max_y = y;
        if (z > max_z) max_z = z;
    }

    *center_x = 0.5f * (min_x + max_x);
    *center_y = 0.5f * (min_y + max_y);
    *center_z = 0.5f * (min_z + max_z);

    {
        float extent_x = max_x - min_x;
        float extent_y = max_y - min_y;
        float extent_z = max_z - min_z;
        float max_extent = extent_x;

        if (extent_y > max_extent) max_extent = extent_y;
        if (extent_z > max_extent) max_extent = extent_z;

        if (max_extent < SOFTENING_LENGTH) {
            max_extent = SOFTENING_LENGTH;
        }

        *size = max_extent * 1.00001f;
    }
}

static void compute_mass_distribution(int node_index, const SystemOfBodies *system)
{
    OctreeNode *node = &g_octree_pool[node_index];

    if (node_is_leaf(node)) {
        if (node->body_index >= 0) {
            int b = node->body_index;
            node->total_mass = system->mass[b];
            node->cm_x = system->x[b];
            node->cm_y = system->y[b];
            node->cm_z = system->z[b];
        } else {
            node->total_mass = 0.0f;
            node->cm_x = node->center_x;
            node->cm_y = node->center_y;
            node->cm_z = node->center_z;
        }
        return;
    }

    {
        int child;
        float total_mass = 0.0f;
        float weighted_x = 0.0f;
        float weighted_y = 0.0f;
        float weighted_z = 0.0f;

        for (child = 0; child < 8; ++child) {
            int child_index = node->children[child];
            if (child_index == -1) {
                continue;
            }

            compute_mass_distribution(child_index, system);
            if (g_octree_pool[child_index].total_mass > 0.0f) {
                float child_mass = g_octree_pool[child_index].total_mass;
                total_mass += child_mass;
                weighted_x += child_mass * g_octree_pool[child_index].cm_x;
                weighted_y += child_mass * g_octree_pool[child_index].cm_y;
                weighted_z += child_mass * g_octree_pool[child_index].cm_z;
            }
        }

        node->total_mass = total_mass;
        if (total_mass > 0.0f) {
            float inv_total_mass = 1.0f / total_mass;
            node->cm_x = weighted_x * inv_total_mass;
            node->cm_y = weighted_y * inv_total_mass;
            node->cm_z = weighted_z * inv_total_mass;
        } else {
            node->cm_x = node->center_x;
            node->cm_y = node->center_y;
            node->cm_z = node->center_z;
        }
    }
}

static void calculate_force_barnes_hut(
    int target_body_index,
    int node_index,
    const SystemOfBodies *system,
    float theta,
    float g_constant,
    float softening_eps2,
    float *ax,
    float *ay,
    float *az)
{
    OctreeNode *node;
    float dx;
    float dy;
    float dz;
    float distance_squared;
    float distance;

    if (node_index == -1) {
        return;
    }

    node = &g_octree_pool[node_index];
    if (node->total_mass <= 0.0f) {
        return;
    }

    if (node_is_leaf(node) && node->body_index == target_body_index) {
        return;
    }

    dx = node->cm_x - system->x[target_body_index];
    dy = node->cm_y - system->y[target_body_index];
    dz = node->cm_z - system->z[target_body_index];
    distance_squared = dx * dx + dy * dy + dz * dz + softening_eps2;
    distance = sqrtf(distance_squared);

    if (node_is_leaf(node) || (node->size / distance) < theta) {
        float inverse_distance = 1.0f / distance;
        float inverse_distance_cubed = inverse_distance * inverse_distance * inverse_distance;
        float scale = g_constant * node->total_mass * inverse_distance_cubed;

        *ax += dx * scale;
        *ay += dy * scale;
        *az += dz * scale;
        return;
    }

    {
        int child;
        for (child = 0; child < 8; ++child) {
            int child_index = node->children[child];
            if (child_index != -1) {
                calculate_force_barnes_hut(target_body_index, child_index, system, theta, g_constant, softening_eps2, ax, ay, az);
            }
        }
    }
}

void compute_accelerations(SystemOfBodies *system, int num_bodies)
{
    int body_index;
    int other_index;

    for (body_index = 0; body_index < num_bodies; ++body_index) {
        float ax = 0.0f;
        float ay = 0.0f;
        float az = 0.0f;

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

            dx = system->x[other_index] - system->x[body_index];
            dy = system->y[other_index] - system->y[body_index];
            dz = system->z[other_index] - system->z[body_index];

            distance_squared = dx * dx + dy * dy + dz * dz + SOFTENING_EPS2;
            inverse_distance = 1.0f / sqrtf(distance_squared);
            inverse_distance_cubed = inverse_distance * inverse_distance * inverse_distance;
            scale = G_CONSTANT * system->mass[other_index] * inverse_distance_cubed;

            ax += dx * scale;
            ay += dy * scale;
            az += dz * scale;
        }

        system->ax[body_index] = ax;
        system->ay[body_index] = ay;
        system->az[body_index] = az;
    }
}

void integrate(SystemOfBodies *system, int num_bodies, float dt)
{
    int index;

    for (index = 0; index < num_bodies; ++index) {
        system->vx[index] += system->ax[index] * dt;
        system->vy[index] += system->ay[index] * dt;
        system->vz[index] += system->az[index] * dt;

        system->x[index] += system->vx[index] * dt;
        system->y[index] += system->vy[index] * dt;
        system->z[index] += system->vz[index] * dt;
    }
}

void compute_accelerations_bh(SystemOfBodies *system, int num_bodies, float theta)
{
    int i;
    int root_index;
    float root_center_x;
    float root_center_y;
    float root_center_z;
    float root_size;
    int estimated_nodes;

    if (num_bodies <= 0) {
        return;
    }

    if (theta <= 0.0f) {
        theta = 0.5f;
    }

    estimated_nodes = (num_bodies * 16) + 8;
    if (!ensure_octree_pool_capacity(estimated_nodes)) {
        compute_accelerations(system, num_bodies);
        return;
    }

    reset_octree_pool();

    root_index = alloc_node();
    if (root_index == -1) {
        compute_accelerations(system, num_bodies);
        return;
    }

    compute_root_bounding_box(system, num_bodies, &root_center_x, &root_center_y, &root_center_z, &root_size);
    init_node(root_index, root_center_x, root_center_y, root_center_z, root_size);

    for (i = 0; i < num_bodies; ++i) {
        if (!insert_body(root_index, i, system, 0)) {
            compute_accelerations(system, num_bodies);
            return;
        }
    }

    compute_mass_distribution(root_index, system);

    for (i = 0; i < num_bodies; ++i) {
        float ax = 0.0f;
        float ay = 0.0f;
        float az = 0.0f;

        calculate_force_barnes_hut(i, root_index, system, theta, G_CONSTANT, SOFTENING_EPS2, &ax, &ay, &az);

        system->ax[i] = ax;
        system->ay[i] = ay;
        system->az[i] = az;
    }
}