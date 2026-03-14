#ifndef SIMULATION_CONFIG_H
#define SIMULATION_CONFIG_H

#define G_CONSTANT 1.0f
/*
 * Softening length epsilon for N-body force regularization.
 * We add epsilon^2 to r^2 to avoid singular forces when particles get too close.
 */
#define SOFTENING_LENGTH_MILLI 100
#define SOFTENING_LENGTH ((float)SOFTENING_LENGTH_MILLI / 1000.0f)
#define SOFTENING_EPS2 (SOFTENING_LENGTH * SOFTENING_LENGTH)

#if SOFTENING_LENGTH_MILLI <= 0
#error "SOFTENING_LENGTH must be > 0"
#endif

#endif