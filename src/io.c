#include <errno.h>
#include <direct.h>
#include <stdio.h>

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