#ifndef PNG_WRITER_H
#define PNG_WRITER_H

#ifdef __cplusplus
extern "C" {
#endif

int write_png_rgba(const char *output_path, const unsigned char *rgba, int width, int height);

#ifdef __cplusplus
}
#endif

#endif
