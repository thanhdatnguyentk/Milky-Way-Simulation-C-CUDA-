#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <conio.h>
#include <windows.h>
#endif

#ifdef USE_CUDA
#include "cuda_nbody.h"
#include "preview_window.h"
#endif
#include "io.h"
#include "simulation.h"
#include "system.h"

#define DEFAULT_NUM_BODIES 256
#define DEFAULT_NUM_STEPS 200
#define DEFAULT_DT 0.01f
#define DEFAULT_OUTPUT_INTERVAL 20
#define DEFAULT_SNAPSHOT_TIME_INTERVAL 0.0f
#define DEFAULT_RENDER_WIDTH 1280
#define DEFAULT_RENDER_HEIGHT 720
#define DEFAULT_RENDER_EXPOSURE 1.25f
#define DEFAULT_RENDER_GAMMA 2.2f
#define DEFAULT_RENDER_FOV 60.0f

typedef struct {
    float x;
    float y;
    float z;
    float yaw;
    float pitch;
    float zoom;
    float fov;
    float time_scale;
    int paused;
} InteractiveState;

static float clamp_float(float value, float min_value, float max_value)
{
    if (value < min_value) {
        return min_value;
    }
    if (value > max_value) {
        return max_value;
    }
    return value;
}

static void apply_camera_profile(const char *profile_name, InteractiveState *state)
{
    if (profile_name == NULL || state == NULL) {
        return;
    }

    if (strcmp(profile_name, "top") == 0) {
        state->x = 0.0f;
        state->y = 120.0f;
        state->z = 0.1f;
        state->yaw = 0.0f;
        state->pitch = -89.0f;
        state->zoom = 1.0f;
    } else if (strcmp(profile_name, "side") == 0) {
        state->x = 120.0f;
        state->y = 0.0f;
        state->z = 0.0f;
        state->yaw = 90.0f;
        state->pitch = 0.0f;
        state->zoom = 1.0f;
    } else if (strcmp(profile_name, "isometric") == 0) {
        state->x = 80.0f;
        state->y = 40.0f;
        state->z = 80.0f;
        state->yaw = 45.0f;
        state->pitch = -25.0f;
        state->zoom = 1.0f;
    } else {
        state->x = 0.0f;
        state->y = 0.0f;
        state->z = 120.0f;
        state->yaw = 0.0f;
        state->pitch = 0.0f;
        state->zoom = 1.0f;
    }
}

static void print_controls_help(void)
{
    printf("Interactive controls:\n");
    printf("  Move camera    : W/S (Y), A/D (X), R/F (Z)\n");
    printf("  Rotate camera  : Arrow keys (Yaw/Pitch)\n");
    printf("  Zoom           : Q (in), E (out)\n");
    printf("  FOV            : [ (narrow), ] (wide)\n");
    printf("  Exposure       : , (down), . (up)\n");
    printf("  Gamma          : ; (down), ' (up)\n");
    printf("  Camera preset  : 1(default), 2(top), 3(side), 4(isometric)\n");
    printf("  Time scale     : - (slower), = (faster)\n");
    printf("  Pause/Resume   : Space\n");
    printf("  Print state    : C\n");
    printf("  Quit early     : Esc\n");
}

static void print_interactive_state(
    const InteractiveState *state,
    float simulation_time,
    int step,
    float exposure,
    float gamma,
    float fps)
{
    printf(
        "[State] step=%d t=%.4f camera=(%.2f, %.2f, %.2f) yaw=%.1f pitch=%.1f zoom=%.2f fov=%.1f exposure=%.2f gamma=%.2f fps=%.1f time_scale=%.2fx %s\n",
        step,
        simulation_time,
        state->x,
        state->y,
        state->z,
        state->yaw,
        state->pitch,
        state->zoom,
        state->fov,
        exposure,
        gamma,
        fps,
        state->time_scale,
        state->paused ? "[PAUSED]" : ""
    );
}

static void poll_interactive_input(
    InteractiveState *state,
    int *quit_requested,
    float simulation_time,
    int step,
    float *exposure,
    float *gamma,
    float fps)
{
#ifdef _WIN32
    while (_kbhit()) {
        int key = _getch();

        if (key == 27) {
            *quit_requested = 1;
            continue;
        }

        if (key == 0 || key == 224) {
            int arrow = _getch();
            if (arrow == 72) {
                state->pitch += 2.0f;
            } else if (arrow == 80) {
                state->pitch -= 2.0f;
            } else if (arrow == 75) {
                state->yaw -= 2.0f;
            } else if (arrow == 77) {
                state->yaw += 2.0f;
            }
            state->pitch = clamp_float(state->pitch, -89.0f, 89.0f);
            continue;
        }

        switch (key) {
        case 'w':
        case 'W':
            state->y += 1.0f;
            break;
        case 's':
        case 'S':
            state->y -= 1.0f;
            break;
        case 'a':
        case 'A':
            state->x -= 1.0f;
            break;
        case 'd':
        case 'D':
            state->x += 1.0f;
            break;
        case 'r':
        case 'R':
            state->z += 1.0f;
            break;
        case 'f':
        case 'F':
            state->z -= 1.0f;
            break;
        case 'q':
        case 'Q':
            state->zoom *= 1.1f;
            state->zoom = clamp_float(state->zoom, 0.1f, 20.0f);
            break;
        case 'e':
        case 'E':
            state->zoom *= 0.9f;
            state->zoom = clamp_float(state->zoom, 0.1f, 20.0f);
            break;
        case '[':
            state->fov = clamp_float(state->fov - 2.0f, 20.0f, 120.0f);
            break;
        case ']':
            state->fov = clamp_float(state->fov + 2.0f, 20.0f, 120.0f);
            break;
        case ',':
        case '<':
            *exposure = clamp_float(*exposure * 0.9f, 0.05f, 20.0f);
            break;
        case '.':
        case '>':
            *exposure = clamp_float(*exposure * 1.1f, 0.05f, 20.0f);
            break;
        case ';':
        case ':':
            *gamma = clamp_float(*gamma * 0.95f, 0.5f, 4.0f);
            break;
        case '\'':
        case '"':
            *gamma = clamp_float(*gamma * 1.05f, 0.5f, 4.0f);
            break;
        case '-':
        case '_':
            state->time_scale *= 0.9f;
            state->time_scale = clamp_float(state->time_scale, 0.01f, 50.0f);
            break;
        case '=':
        case '+':
            state->time_scale *= 1.1f;
            state->time_scale = clamp_float(state->time_scale, 0.01f, 50.0f);
            break;
        case ' ':
            state->paused = !state->paused;
            break;
        case 'c':
        case 'C':
            print_interactive_state(state, simulation_time, step, *exposure, *gamma, fps);
            break;
        case 'h':
        case 'H':
            print_controls_help();
            break;
        case '1':
            apply_camera_profile("default", state);
            break;
        case '2':
            apply_camera_profile("top", state);
            break;
        case '3':
            apply_camera_profile("side", state);
            break;
        case '4':
            apply_camera_profile("isometric", state);
            break;
        default:
            break;
        }
    }
#else
    (void)state;
    (void)quit_requested;
    (void)simulation_time;
    (void)step;
    (void)exposure;
    (void)gamma;
    (void)fps;
#endif
}

static int parse_int_arg(const char *value, int fallback)
{
    char *end_ptr = NULL;
    long parsed = strtol(value, &end_ptr, 10);

    if (end_ptr == value || *end_ptr != '\0' || parsed <= 0) {
        return fallback;
    }

    return (int)parsed;
}

static int parse_num_steps_arg(const char *value, int fallback)
{
    if (value == NULL) {
        return fallback;
    }

    if (strcmp(value, "inf") == 0 || strcmp(value, "infinite") == 0) {
        return -1;
    }

    return parse_int_arg(value, fallback);
}

static float parse_float_arg(const char *value, float fallback)
{
    char *end_ptr = NULL;
    float parsed = strtof(value, &end_ptr);

    if (end_ptr == value || *end_ptr != '\0' || parsed <= 0.0f) {
        return fallback;
    }

    return parsed;
}

static int is_gpu_backend(const char *value)
{
    return strcmp(value, "gpu") == 0 || strcmp(value, "cuda") == 0;
}

static IntegratorMode parse_integrator_mode(const char *value)
{
    if (value != NULL && (strcmp(value, "euler") == 0 || strcmp(value, "forward-euler") == 0)) {
        return INTEGRATOR_EULER;
    }

    return INTEGRATOR_LEAPFROG;
}

static const char *integrator_mode_name(IntegratorMode mode)
{
    return (mode == INTEGRATOR_EULER) ? "euler" : "leapfrog";
}

static SolverMode parse_solver_mode(const char *value)
{
    if (value != NULL) {
        if (strcmp(value, "bh") == 0 || strcmp(value, "barnes-hut") == 0 || strcmp(value, "barneshut") == 0) {
            return SOLVER_BH;
        }
        if (strcmp(value, "fmm") == 0) {
            return SOLVER_FMM;
        }
    }

    return SOLVER_DIRECT;
}

static const char *solver_mode_name(SolverMode mode)
{
    if (mode == SOLVER_BH) {
        return "bh";
    }
    if (mode == SOLVER_FMM) {
        return "fmm";
    }
    return "direct";
}

#ifdef USE_CUDA
static CudaRenderMode parse_render_mode(const char *value)
{
    if (value != NULL && (strcmp(value, "raster") == 0 || strcmp(value, "splat") == 0)) {
        return CUDA_RENDER_MODE_RASTER;
    }

    return CUDA_RENDER_MODE_RAYTRACE;
}

static const char *render_mode_name(CudaRenderMode mode)
{
    return (mode == CUDA_RENDER_MODE_RASTER) ? "raster" : "raytrace";
}
#endif

#ifdef USE_CUDA
static int update_live_preview(
    const InteractiveState *interactive,
    float render_exposure,
    float render_gamma,
    float simulation_time,
    int step,
    float fps,
    int *quit_requested)
{
    RenderCamera render_camera;
    const unsigned char *rgba;
    int width;
    int height;
    char title[256];
    char hud_text[512];
    const char *mode_name;

    render_camera.x = interactive->x;
    render_camera.y = interactive->y;
    render_camera.z = interactive->z;
    render_camera.yaw = interactive->yaw;
    render_camera.pitch = interactive->pitch;
    render_camera.zoom = interactive->zoom;
    render_camera.fov = interactive->fov;

    if (!render_current_frame_cuda(&render_camera, render_exposure, render_gamma)) {
        return 0;
    }

    mode_name = render_mode_name(get_cuda_render_mode());

    rgba = get_cuda_render_rgba(&width, &height);

    snprintf(
        title,
        sizeof(title),
        "Milky Way Preview | step=%d t=%.3f fps=%.1f mode=%s",
        step,
        simulation_time,
        fps,
        mode_name);

    snprintf(
        hud_text,
        sizeof(hud_text),
        "step=%d  t=%.3f  fps=%.1f  mode=%s  exp=%.2f  gamma=%.2f  fov=%.1f  zoom=%.2f  speed=%.2fx",
        step,
        simulation_time,
        fps,
        mode_name,
        render_exposure,
        render_gamma,
        interactive->fov,
        interactive->zoom,
        interactive->time_scale);

    if (!update_preview_window(rgba, width, height, title, hud_text)) {
        return 0;
    }

    if (!process_preview_window_events(quit_requested)) {
        return 0;
    }

    return 1;
}
#endif

int main(int argc, char **argv)
{
    SystemOfBodies system = {0};
    const char *output_directory = "output";
    const char *data_file_path = NULL;
    const char *backend_name = "cpu";
    const char *camera_profile = "default";
    InteractiveState interactive = {0.0f, 0.0f, 120.0f, 0.0f, 0.0f, 1.0f, DEFAULT_RENDER_FOV, 1.0f, 0};
    int num_bodies = DEFAULT_NUM_BODIES;
    int num_steps = DEFAULT_NUM_STEPS;
    int output_interval = DEFAULT_OUTPUT_INTERVAL;
    int render_enabled = 0;
    int clear_output_flag = 0;
    int render_width = DEFAULT_RENDER_WIDTH;
    int render_height = DEFAULT_RENDER_HEIGHT;
    int use_gpu = 0;
    int quit_requested = 0;
    float dt = DEFAULT_DT;
    float render_exposure = DEFAULT_RENDER_EXPOSURE;
    float render_gamma = DEFAULT_RENDER_GAMMA;
    float snapshot_time_interval = DEFAULT_SNAPSHOT_TIME_INTERVAL;
    float next_snapshot_time = 0.0f;
    float simulation_time = 0.0f;
    float preview_fps = 0.0f;
    IntegratorMode selected_integrator_mode = INTEGRATOR_LEAPFROG;
    SolverMode selected_solver_mode = SOLVER_DIRECT;
    float selected_solver_theta = 0.5f;
#ifdef USE_CUDA
    RenderTelemetry last_telemetry = {0, 0.0f, 0.0f};
    CudaRenderMode selected_render_mode = CUDA_RENDER_MODE_RAYTRACE;
#endif
#ifdef _WIN32
    LARGE_INTEGER fps_frequency = {0};
    LARGE_INTEGER fps_last_counter = {0};
#endif
    int step;

    if (argc > 1) {
        num_bodies = parse_int_arg(argv[1], DEFAULT_NUM_BODIES);
    }
    if (argc > 2) {
        num_steps = parse_num_steps_arg(argv[2], DEFAULT_NUM_STEPS);
    }
    if (argc > 3) {
        dt = parse_float_arg(argv[3], DEFAULT_DT);
    }
    if (argc > 4) {
        output_interval = parse_int_arg(argv[4], DEFAULT_OUTPUT_INTERVAL);
    }
    if (argc > 5 && is_gpu_backend(argv[5])) {
        use_gpu = 1;
        backend_name = "gpu";
    }
    if (argc > 6) {
        snapshot_time_interval = parse_float_arg(argv[6], DEFAULT_SNAPSHOT_TIME_INTERVAL);
    }
    if (argc > 7) {
        render_width = parse_int_arg(argv[7], DEFAULT_RENDER_WIDTH);
    }
    if (argc > 8) {
        render_height = parse_int_arg(argv[8], DEFAULT_RENDER_HEIGHT);
    }
    if (argc > 9) {
        interactive.fov = parse_float_arg(argv[9], DEFAULT_RENDER_FOV);
    }
    if (argc > 10) {
        render_exposure = parse_float_arg(argv[10], DEFAULT_RENDER_EXPOSURE);
    }
    if (argc > 11) {
        render_gamma = parse_float_arg(argv[11], DEFAULT_RENDER_GAMMA);
    }
    if (argc > 12) {
        camera_profile = argv[12];
    }

    for (int arg_index = 1; arg_index < argc; ++arg_index) {
        if (strcmp(argv[arg_index], "--clear-output") == 0) {
            clear_output_flag = 1;
        }
        if (strcmp(argv[arg_index], "--infinite") == 0) {
            num_steps = -1;
        }
        if (strcmp(argv[arg_index], "--data") == 0 && arg_index + 1 < argc) {
            data_file_path = argv[arg_index + 1];
        }
        if (strncmp(argv[arg_index], "--data=", 7) == 0) {
            data_file_path = argv[arg_index] + 7;
        }
        if (strcmp(argv[arg_index], "--integrator") == 0 && arg_index + 1 < argc) {
            selected_integrator_mode = parse_integrator_mode(argv[arg_index + 1]);
        }
        if (strncmp(argv[arg_index], "--integrator=", 13) == 0) {
            selected_integrator_mode = parse_integrator_mode(argv[arg_index] + 13);
        }
        if (strcmp(argv[arg_index], "--solver") == 0 && arg_index + 1 < argc) {
            selected_solver_mode = parse_solver_mode(argv[arg_index + 1]);
        }
        if (strncmp(argv[arg_index], "--solver=", 9) == 0) {
            selected_solver_mode = parse_solver_mode(argv[arg_index] + 9);
        }
        if (strcmp(argv[arg_index], "--theta") == 0 && arg_index + 1 < argc) {
            selected_solver_theta = parse_float_arg(argv[arg_index + 1], selected_solver_theta);
        }
        if (strncmp(argv[arg_index], "--theta=", 8) == 0) {
            selected_solver_theta = parse_float_arg(argv[arg_index] + 8, selected_solver_theta);
        }
#ifdef USE_CUDA
        if (strcmp(argv[arg_index], "--render-mode") == 0 && arg_index + 1 < argc) {
            selected_render_mode = parse_render_mode(argv[arg_index + 1]);
        }
        if (strncmp(argv[arg_index], "--render-mode=", 14) == 0) {
            selected_render_mode = parse_render_mode(argv[arg_index] + 14);
        }
#endif
    }

    apply_camera_profile(camera_profile, &interactive);
    if (argc > 9) {
        interactive.fov = parse_float_arg(argv[9], interactive.fov);
    }
    interactive.fov = clamp_float(interactive.fov, 20.0f, 120.0f);
    render_exposure = clamp_float(render_exposure, 0.05f, 20.0f);
    render_gamma = clamp_float(render_gamma, 0.5f, 4.0f);
    set_integrator_mode(selected_integrator_mode);
    set_solver_mode(selected_solver_mode);
    set_solver_theta(selected_solver_theta);

    if (data_file_path != NULL) {
        if (!load_hyg_csv(data_file_path, &system, &num_bodies)) {
            fprintf(stderr, "Failed to load dataset from '%s'.\n", data_file_path);
            return EXIT_FAILURE;
        }
        printf("Loaded dataset: %s (%d bodies)\n", data_file_path, num_bodies);
    } else {
        if (!allocate_system(&system, num_bodies)) {
            fprintf(stderr, "Failed to allocate memory for %d bodies.\n", num_bodies);
            return EXIT_FAILURE;
        }

        initialize_system(&system, num_bodies);
    }

    if (clear_output_flag) {
        if (!clear_output_directory(output_directory)) {
            fprintf(stderr, "Failed to clear output directory '%s'.\n", output_directory);
            free_system(&system);
            return EXIT_FAILURE;
        }
    }

#ifdef USE_CUDA
    if (use_gpu) {
        if (!initialize_cuda_simulation(&system, num_bodies)) {
            fprintf(stderr, "Failed to initialize persistent CUDA simulation state.\n");
            free_system(&system);
            return EXIT_FAILURE;
        }

        render_enabled = initialize_cuda_renderer(num_bodies, render_width, render_height);
        if (render_enabled) {
            unsigned int preview_pbo = 0;
            int pbo_width = 0;
            int pbo_height = 0;

            set_cuda_render_mode(selected_render_mode);
            if (!initialize_preview_window("Milky Way Preview", render_width, render_height)) {
                fprintf(stderr, "Preview window initialization failed; continuing without preview.\n");
                shutdown_cuda_renderer();
                render_enabled = 0;
            } else if (get_preview_cuda_pbo(&preview_pbo, &pbo_width, &pbo_height) &&
                       bind_cuda_render_pbo(preview_pbo, pbo_width, pbo_height)) {
                printf("Preview path: CUDA-OpenGL PBO interop enabled (%dx%d).\n", pbo_width, pbo_height);
            } else {
                printf("Preview path: host copy fallback (no CUDA-OpenGL interop).\n");
            }
        } else {
            fprintf(stderr, "CUDA renderer initialization failed; continuing without preview/render output.\n");
        }

    #ifdef _WIN32
        QueryPerformanceFrequency(&fps_frequency);
        QueryPerformanceCounter(&fps_last_counter);
    #endif
    }
#endif

    if (!initialize_snapshot_series(
            output_directory,
            backend_name,
            num_bodies,
            num_steps,
            dt,
            output_interval,
            snapshot_time_interval)) {
        fprintf(stderr, "Failed to initialize snapshot series in '%s'.\n", output_directory);
#ifdef USE_CUDA
        if (use_gpu) {
            shutdown_preview_window();
            shutdown_cuda_renderer();
            shutdown_cuda_simulation();
        }
#endif
        free_system(&system);
        return EXIT_FAILURE;
    }

    if (num_steps < 0) {
                 printf("Running %s N-body baseline with %d bodies, infinite steps, dt=%.4f (integrator=%s solver=%s theta=%.2f)\n",
               use_gpu ? "GPU" : "CPU",
               num_bodies,
             dt,
                         integrator_mode_name(selected_integrator_mode),
                         solver_mode_name(selected_solver_mode),
                         selected_solver_theta);
    } else {
                 printf("Running %s N-body baseline with %d bodies, %d steps, dt=%.4f (integrator=%s solver=%s theta=%.2f)\n",
               use_gpu ? "GPU" : "CPU",
               num_bodies,
               num_steps,
             dt,
                         integrator_mode_name(selected_integrator_mode),
                         solver_mode_name(selected_solver_mode),
                         selected_solver_theta);
    }
    if (render_enabled) {
         printf("CUDA renderer enabled at %dx%d (fov=%.1f exposure=%.2f gamma=%.2f profile=%s mode=%s)\n",
               render_width,
               render_height,
               interactive.fov,
               render_exposure,
               render_gamma,
             camera_profile,
    #ifdef USE_CUDA
             render_mode_name(selected_render_mode)
    #else
             "cpu"
    #endif
             );
    }

#ifdef USE_CUDA
    if (use_gpu) {
        if (!set_cuda_integrator_mode(selected_integrator_mode)) {
            fprintf(stderr, "Failed to configure CUDA integrator mode.\n");
            shutdown_preview_window();
            shutdown_cuda_renderer();
            shutdown_cuda_simulation();
            free_system(&system);
            return EXIT_FAILURE;
        }
        if (!set_cuda_solver_mode(selected_solver_mode)) {
            fprintf(stderr, "Failed to configure CUDA solver mode.\n");
            shutdown_preview_window();
            shutdown_cuda_renderer();
            shutdown_cuda_simulation();
            free_system(&system);
            return EXIT_FAILURE;
        }
        if (!set_cuda_solver_theta(selected_solver_theta)) {
            fprintf(stderr, "Failed to configure CUDA solver theta.\n");
            shutdown_preview_window();
            shutdown_cuda_renderer();
            shutdown_cuda_simulation();
            free_system(&system);
            return EXIT_FAILURE;
        }
    }
#endif
    print_controls_help();

    for (step = 0; num_steps < 0 || step < num_steps;) {
        float effective_dt;
        int should_write_snapshot = 0;

#ifdef USE_CUDA
        if (use_gpu && render_enabled) {
            process_preview_window_events(&quit_requested);
        }
#endif
        poll_interactive_input(&interactive, &quit_requested, simulation_time, step, &render_exposure, &render_gamma, preview_fps);
        if (quit_requested) {
            printf("Stopping simulation early on user request at step %d.\n", step);
            break;
        }

        if (interactive.paused) {
#ifdef USE_CUDA
            if (use_gpu && render_enabled) {
                if (!update_live_preview(&interactive, render_exposure, render_gamma, simulation_time, step, preview_fps, &quit_requested)) {
                    fprintf(stderr, "Preview update failed while paused; disabling renderer/preview.\n");
                    shutdown_preview_window();
                    shutdown_cuda_renderer();
                    render_enabled = 0;
                } else {
#ifdef _WIN32
                    LARGE_INTEGER fps_now;
                    double frame_dt;
                    QueryPerformanceCounter(&fps_now);
                    frame_dt = (double)(fps_now.QuadPart - fps_last_counter.QuadPart) / (double)fps_frequency.QuadPart;
                    fps_last_counter = fps_now;
                    if (frame_dt > 0.0) {
                        float instant_fps = (float)(1.0 / frame_dt);
                        preview_fps = preview_fps * 0.85f + instant_fps * 0.15f;
                    }
#endif
                    get_last_render_telemetry(&last_telemetry);
                          printf("[Render] step=%d mode=%s visible=%u cull=%.2fms draw=%.2fms fps=%.1f\n",
                              step,
                              render_mode_name(get_cuda_render_mode()),
                              last_telemetry.visible_count,
                              last_telemetry.cull_ms,
                              last_telemetry.trace_ms,
                              preview_fps);
                }
            }
#endif
#ifdef _WIN32
            Sleep(16);
#endif
            continue;
        }

        effective_dt = dt * interactive.time_scale;

#ifdef USE_CUDA
        if (use_gpu) {
            if (!step_cuda_simulation(&system, num_bodies, effective_dt, 0)) {
                fprintf(stderr, "Failed to advance persistent CUDA simulation at step %d.\n", step);
                shutdown_preview_window();
                shutdown_cuda_renderer();
                shutdown_cuda_simulation();
                free_system(&system);
                return EXIT_FAILURE;
            }
        } else {
            advance_simulation(&system, num_bodies, effective_dt);
        }
#else
        if (use_gpu) {
            fprintf(stderr, "This binary was built without CUDA support. Rebuild with USE_CUDA and cuda/nbody.cu.\n");
            free_system(&system);
            return EXIT_FAILURE;
        }
        advance_simulation(&system, num_bodies, effective_dt);
#endif
        simulation_time += effective_dt;

#ifdef USE_CUDA
        if (use_gpu && render_enabled) {
            if (!update_live_preview(&interactive, render_exposure, render_gamma, simulation_time, step, preview_fps, &quit_requested)) {
                fprintf(stderr, "Preview update failed at step %d; disabling renderer/preview.\n", step);
                shutdown_preview_window();
                shutdown_cuda_renderer();
                render_enabled = 0;
            } else {
#ifdef _WIN32
                LARGE_INTEGER fps_now;
                double frame_dt;
                QueryPerformanceCounter(&fps_now);
                frame_dt = (double)(fps_now.QuadPart - fps_last_counter.QuadPart) / (double)fps_frequency.QuadPart;
                fps_last_counter = fps_now;
                if (frame_dt > 0.0) {
                    float instant_fps = (float)(1.0 / frame_dt);
                    preview_fps = preview_fps * 0.85f + instant_fps * 0.15f;
                }
#endif
                get_last_render_telemetry(&last_telemetry);
                  printf("[Render] step=%d mode=%s visible=%u cull=%.2fms draw=%.2fms fps=%.1f\n",
                      step,
                      render_mode_name(get_cuda_render_mode()),
                      last_telemetry.visible_count,
                      last_telemetry.cull_ms,
                      last_telemetry.trace_ms,
                      preview_fps);
            }
        }
#endif

        if (snapshot_time_interval > 0.0f) {
            if (step == 0 || (num_steps > 0 && step == num_steps - 1) || simulation_time + 1e-6f >= next_snapshot_time) {
                should_write_snapshot = 1;
                while (next_snapshot_time <= simulation_time + 1e-6f) {
                    next_snapshot_time += snapshot_time_interval;
                }
            }
        } else if (step == 0 || (num_steps > 0 && step == num_steps - 1) || step % output_interval == 0) {
            should_write_snapshot = 1;
        }

        if (should_write_snapshot) {
#ifdef USE_CUDA
            if (use_gpu) {
                if (!sync_cuda_system_to_host(&system, num_bodies)) {
                    fprintf(stderr, "Failed to synchronize CUDA simulation state back to host at step %d.\n", step);
                    shutdown_preview_window();
                    shutdown_cuda_renderer();
                    shutdown_cuda_simulation();
                    free_system(&system);
                    return EXIT_FAILURE;
                }
            }
#endif
            print_snapshot(&system, num_bodies, step);

            if (!write_snapshot_csv(&system, num_bodies, step, output_directory)) {
                fprintf(stderr, "Failed to write CSV snapshot for step %d.\n", step);
#ifdef USE_CUDA
                if (use_gpu) {
                    shutdown_preview_window();
                    shutdown_cuda_renderer();
                    shutdown_cuda_simulation();
                }
#endif
                free_system(&system);
                return EXIT_FAILURE;
            }

            if (!write_snapshot_frame_csv(&system, num_bodies, step, simulation_time, output_directory)) {
                fprintf(stderr, "Failed to write structured snapshot for step %d.\n", step);
#ifdef USE_CUDA
                if (use_gpu) {
                    shutdown_preview_window();
                    shutdown_cuda_renderer();
                    shutdown_cuda_simulation();
                }
#endif
                free_system(&system);
                return EXIT_FAILURE;
            }

#ifdef USE_CUDA
            if (use_gpu && render_enabled) {
                char render_path[256];

                snprintf(render_path, sizeof(render_path), "%s/render_%06d.png", output_directory, step);
                if (!write_current_render_png(render_path)) {
                    fprintf(stderr, "Failed to write PNG render for step %d; disabling renderer output.\n", step);
                    shutdown_preview_window();
                    shutdown_cuda_renderer();
                    render_enabled = 0;
                } else {
                    printf("[Render] %s\n", render_path);
                }
            }
#endif
            print_interactive_state(&interactive, simulation_time, step, render_exposure, render_gamma, preview_fps);
        }

        ++step;
    }

#ifdef USE_CUDA
    if (use_gpu) {
        shutdown_preview_window();
        shutdown_cuda_renderer();
        shutdown_cuda_simulation();
    }
#endif
    free_system(&system);
    return EXIT_SUCCESS;
}
