#ifndef IO_H
#define IO_H

#include "system.h"

void print_snapshot(const SystemOfBodies *system, int num_bodies, int step);
int write_snapshot_csv(const SystemOfBodies *system, int num_bodies, int step, const char *output_directory);

#endif