#ifndef PREVIEW_WINDOW_H
#define PREVIEW_WINDOW_H

#ifdef __cplusplus
extern "C" {
#endif

int initialize_preview_window(const char *title, int width, int height);
int process_preview_window_events(int *quit_requested);
int update_preview_window(const unsigned char *rgba, int width, int height, const char *title, const char *hud_text);
int get_preview_cuda_pbo(unsigned int *pbo, int *width, int *height);
void shutdown_preview_window(void);

#ifdef __cplusplus
}
#endif

#endif
