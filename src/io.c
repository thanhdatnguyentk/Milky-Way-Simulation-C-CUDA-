#include <errno.h>
#include <direct.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "io.h"

static int ensure_output_directory(const char *output_directory)
{
    int status = _mkdir(output_directory);

    if (status == 0 || errno == EEXIST) {
        return 1;
    }

    return 0;
}

void print_snapshot(const SystemOfBodies *system, int num_bodies, int step)
{
    int bodies_to_print = num_bodies < 3 ? num_bodies : 3;
    int index;

    printf("Step %d\n", step);

    for (index = 0; index < bodies_to_print; ++index) {
        printf(
            "  Body %d: pos=(%.3f, %.3f, %.3f) vel=(%.3f, %.3f, %.3f) acc=(%.3f, %.3f, %.3f) mass=%.3f\n",
            index,
            system->x[index],
            system->y[index],
            system->z[index],
            system->vx[index],
            system->vy[index],
            system->vz[index],
            system->ax[index],
            system->ay[index],
            system->az[index],
            system->mass[index]
        );
    }
}

int write_snapshot_csv(const SystemOfBodies *system, int num_bodies, int step, const char *output_directory)
{
    char file_path[256];
    FILE *output_file = NULL;
    int index;

    if (!ensure_output_directory(output_directory)) {
        return 0;
    }

    snprintf(file_path, sizeof(file_path), "%s/step_%04d.csv", output_directory, step);
    if (fopen_s(&output_file, file_path, "w") != 0) {
        return 0;
    }

    if (output_file == NULL) {
        return 0;
    }

    fprintf(output_file, "body_id,mass,x,y,z,vx,vy,vz,ax,ay,az\n");

    for (index = 0; index < num_bodies; ++index) {
        fprintf(
            output_file,
            "%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            index,
            system->mass[index],
            system->x[index],
            system->y[index],
            system->z[index],
            system->vx[index],
            system->vy[index],
            system->vz[index],
            system->ax[index],
            system->ay[index],
            system->az[index]
        );
    }

    fclose(output_file);
    return 1;
}

int clear_output_directory(const char *output_directory)
{
    char search_pattern[260];
    WIN32_FIND_DATAA find_data;
    HANDLE find_handle;

    if (output_directory == NULL || output_directory[0] == '\0') {
        return 0;
    }

    if (!ensure_output_directory(output_directory)) {
        return 0;
    }

    snprintf(search_pattern, sizeof(search_pattern), "%s/*", output_directory);
    find_handle = FindFirstFileA(search_pattern, &find_data);
    if (find_handle == INVALID_HANDLE_VALUE) {
        return 1;
    }

    do {
        if (strcmp(find_data.cFileName, ".") == 0 || strcmp(find_data.cFileName, "..") == 0) {
            continue;
        }

        if ((find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            char file_path[320];

            snprintf(file_path, sizeof(file_path), "%s/%s", output_directory, find_data.cFileName);
            DeleteFileA(file_path);
        }
    } while (FindNextFileA(find_handle, &find_data));

    FindClose(find_handle);
    return 1;
}

int initialize_snapshot_series(
    const char *output_directory,
    const char *backend,
    int num_bodies,
    int total_steps,
    float dt,
    int output_interval,
    float snapshot_time_interval)
{
    char meta_path[256];
    char index_path[256];
    FILE *meta_file = NULL;
    FILE *index_file = NULL;

    if (!ensure_output_directory(output_directory)) {
        return 0;
    }

    snprintf(meta_path, sizeof(meta_path), "%s/series_meta.json", output_directory);
    if (fopen_s(&meta_file, meta_path, "w") != 0 || meta_file == NULL) {
        return 0;
    }

    fprintf(meta_file, "{\n");
    fprintf(meta_file, "  \"format\": \"nbody_snapshot_series_v1\",\n");
    fprintf(meta_file, "  \"backend\": \"%s\",\n", backend != NULL ? backend : "cpu");
    fprintf(meta_file, "  \"num_bodies\": %d,\n", num_bodies);
    fprintf(meta_file, "  \"total_steps\": %d,\n", total_steps);
    fprintf(meta_file, "  \"dt\": %.8f,\n", dt);
    fprintf(meta_file, "  \"output_interval\": %d,\n", output_interval);
    fprintf(meta_file, "  \"snapshot_mode\": \"%s\",\n", snapshot_time_interval > 0.0f ? "time" : "step");
    fprintf(meta_file, "  \"snapshot_time_interval\": %.8f,\n", snapshot_time_interval);
    fprintf(meta_file, "  \"frame_pattern\": \"frame_%%06d.csv\",\n");
    fprintf(meta_file, "  \"index_file\": \"snapshots_index.csv\"\n");
    fprintf(meta_file, "}\n");
    fclose(meta_file);

    snprintf(index_path, sizeof(index_path), "%s/snapshots_index.csv", output_directory);
    if (fopen_s(&index_file, index_path, "w") != 0 || index_file == NULL) {
        return 0;
    }

    fprintf(index_file, "step,time,frame_file,num_bodies,min_x,max_x,min_y,max_y,min_z,max_z\n");
    fclose(index_file);
    return 1;
}

int write_snapshot_frame_csv(
    const SystemOfBodies *system,
    int num_bodies,
    int step,
    float simulation_time,
    const char *output_directory)
{
    char frame_path[256];
    char index_path[256];
    char frame_name[64];
    FILE *frame_file = NULL;
    FILE *index_file = NULL;
    float min_x;
    float max_x;
    float min_y;
    float max_y;
    float min_z;
    float max_z;
    int index;

    if (num_bodies <= 0) {
        return 0;
    }

    if (!ensure_output_directory(output_directory)) {
        return 0;
    }

    snprintf(frame_name, sizeof(frame_name), "frame_%06d.csv", step);
    snprintf(frame_path, sizeof(frame_path), "%s/%s", output_directory, frame_name);

    if (fopen_s(&frame_file, frame_path, "w") != 0 || frame_file == NULL) {
        return 0;
    }

    fprintf(frame_file, "body_id,mass,lum,absmag,ci,x,y,z,vx,vy,vz,ax,ay,az\n");

    min_x = max_x = system->x[0];
    min_y = max_y = system->y[0];
    min_z = max_z = system->z[0];

    for (index = 0; index < num_bodies; ++index) {
        float x = system->x[index];
        float y = system->y[index];
        float z = system->z[index];

        if (x < min_x) min_x = x;
        if (x > max_x) max_x = x;
        if (y < min_y) min_y = y;
        if (y > max_y) max_y = y;
        if (z < min_z) min_z = z;
        if (z > max_z) max_z = z;

        fprintf(
            frame_file,
            "%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            index,
            system->mass[index],
            system->lum[index],
            system->absmag[index],
            system->ci[index],
            x,
            y,
            z,
            system->vx[index],
            system->vy[index],
            system->vz[index],
            system->ax[index],
            system->ay[index],
            system->az[index]
        );
    }

    fclose(frame_file);

    snprintf(index_path, sizeof(index_path), "%s/snapshots_index.csv", output_directory);
    if (fopen_s(&index_file, index_path, "a") != 0 || index_file == NULL) {
        return 0;
    }

    fprintf(
        index_file,
        "%d,%.6f,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
        step,
        simulation_time,
        frame_name,
        num_bodies,
        min_x,
        max_x,
        min_y,
        max_y,
        min_z,
        max_z
    );

    fclose(index_file);
    return 1;
}

/* -------------------------------------------------------------------------
 * HYG v4.2 CSV loader
 * Column indices (0-based):
 *   14=absmag  16=ci  17=x  18=y  19=z  20=vx  21=vy  22=vz  33=lum
 * -------------------------------------------------------------------------*/

/* Advance past one CSV field (handles "quoted" fields) and past the comma. */
static const char *skip_csv_field(const char *p)
{
    if (*p == '"') {
        p++;
        while (*p && *p != '"') p++;
        if (*p == '"') p++;
    } else {
        while (*p && *p != ',' && *p != '\n' && *p != '\r') p++;
    }
    if (*p == ',') p++;
    return p;
}

/* Read one numeric CSV field into *out; leaves *out = default_val if empty. */
static const char *read_csv_float(const char *p, float *out, float default_val)
{
    char buf[64];
    char *end_ptr;
    int i = 0;
    double parsed;

    *out = default_val;

    if (*p == '"') {          /* quoted -> treat as empty */
        p++;
        while (*p && *p != '"') p++;
        if (*p == '"') p++;
    } else {
        while (*p && *p != ',' && *p != '\n' && *p != '\r' && i < 63)
            buf[i++] = *p++;
        buf[i] = '\0';
        if (i > 0) {
            parsed = strtod(buf, &end_ptr);
            if (end_ptr != buf) *out = (float)parsed;
        }
    }
    if (*p == ',') p++;
    return p;
}

/*
 * Parse the fields we care about from one HYG data line.
 * All other columns are skipped efficiently.
 */
static void parse_hyg_line(const char *line,
                            float *x,   float *y,   float *z,
                            float *vx,  float *vy,  float *vz,
                            float *absmag, float *ci, float *lum)
{
    const char *p = line;
    int col;

    /* Skip columns 0-13 */
    for (col = 0; col < 14; col++) p = skip_csv_field(p);

    p = read_csv_float(p, absmag, 0.0f); /* col 14 */
    p = skip_csv_field(p);               /* col 15: spect */
    p = read_csv_float(p, ci,     0.0f); /* col 16 */
    p = read_csv_float(p, x,      0.0f); /* col 17 */
    p = read_csv_float(p, y,      0.0f); /* col 18 */
    p = read_csv_float(p, z,      0.0f); /* col 19 */
    p = read_csv_float(p, vx,     0.0f); /* col 20 */
    p = read_csv_float(p, vy,     0.0f); /* col 21 */
    p = read_csv_float(p, vz,     0.0f); /* col 22 */

    /* Skip columns 23-32 */
    for (col = 23; col < 33; col++) p = skip_csv_field(p);

    p = read_csv_float(p, lum, 0.0f);   /* col 33 */
}

int load_hyg_csv(const char *file_path, SystemOfBodies *system, int *num_bodies_out)
{
    FILE *f;
    char line[1024];
    int count = 0;
    int index = 0;
    float x, y, z, vx, vy, vz, absmag, ci, lum;

    /* First pass: count data lines */
    if (fopen_s(&f, file_path, "r") != 0 || f == NULL) {
        fprintf(stderr, "load_hyg_csv: cannot open '%s'\n", file_path);
        return 0;
    }
    fgets(line, sizeof(line), f); /* skip header */
    while (fgets(line, sizeof(line), f)) count++;
    fclose(f);

    if (count == 0) {
        fprintf(stderr, "load_hyg_csv: no data rows found\n");
        return 0;
    }

    if (!allocate_system(system, count)) {
        fprintf(stderr, "load_hyg_csv: failed to allocate %d bodies\n", count);
        return 0;
    }

    /* Second pass: parse */
    if (fopen_s(&f, file_path, "r") != 0 || f == NULL) {
        free_system(system);
        return 0;
    }
    fgets(line, sizeof(line), f); /* skip header */

    while (fgets(line, sizeof(line), f) && index < count) {
        parse_hyg_line(line, &x, &y, &z, &vx, &vy, &vz, &absmag, &ci, &lum);

        system->x[index]      = x;
        system->y[index]      = y;
        system->z[index]      = z;
        system->vx[index]     = vx;
        system->vy[index]     = vy;
        system->vz[index]     = vz;
        system->ax[index]     = 0.0f;
        system->ay[index]     = 0.0f;
        system->az[index]     = 0.0f;
        system->lum[index]    = lum;
        system->absmag[index] = absmag;
        system->ci[index]     = ci;
        /* Derive mass from luminosity: M ~ L^(1/3.5) for main-sequence stars */
        system->mass[index]   = (lum > 0.0f) ? (float)pow((double)lum, 1.0 / 3.5) : 1.0f;

        index++;
    }

    fclose(f);
    *num_bodies_out = index;
    printf("load_hyg_csv: loaded %d stars from '%s'\n", index, file_path);
    return 1;
}