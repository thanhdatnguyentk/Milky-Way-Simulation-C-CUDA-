#ifndef IO_H
#define IO_H

#include "system.h"

void print_snapshot(const SystemOfBodies *system, int num_bodies, int step);
int write_snapshot_csv(const SystemOfBodies *system, int num_bodies, int step, const char *output_directory);
int clear_output_directory(const char *output_directory);
int initialize_snapshot_series(
	const char *output_directory,
	const char *backend,
	int num_bodies,
	int total_steps,
	float dt,
	int output_interval,
	float snapshot_time_interval);
int write_snapshot_frame_csv(
	const SystemOfBodies *system,
	int num_bodies,
	int step,
	float simulation_time,
	const char *output_directory);
int load_hyg_csv(const char *file_path, SystemOfBodies *system, int *num_bodies_out);

#endif