#include <windows.h>

#include <GL/gl.h>

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "preview_window.h"

static HWND g_preview_window = NULL;
static int g_width = 0;
static int g_height = 0;
static const wchar_t *g_window_class_name = L"UniversitySimulationPreviewWindow";
static char g_hud_text[512] = "";
static HDC g_gl_dc = NULL;
static HGLRC g_gl_rc = NULL;
static GLuint g_gl_texture = 0;
static GLuint g_gl_pbo = 0;

#ifndef GL_PIXEL_UNPACK_BUFFER
#define GL_PIXEL_UNPACK_BUFFER 0x88EC
#endif
#ifndef GL_STREAM_DRAW
#define GL_STREAM_DRAW 0x88E0
#endif
#ifndef GL_RGBA8
#define GL_RGBA8 0x8058
#endif
#ifndef APIENTRYP
#define APIENTRYP APIENTRY *
#endif

typedef void (APIENTRYP PFNGLGENBUFFERSPROC)(GLsizei n, GLuint *buffers);
typedef void (APIENTRYP PFNGLBINDBUFFERPROC)(GLenum target, GLuint buffer);
typedef void (APIENTRYP PFNGLBUFFERDATAPROC)(GLenum target, ptrdiff_t size, const void *data, GLenum usage);
typedef void (APIENTRYP PFNGLBUFFERSUBDATAPROC)(GLenum target, ptrdiff_t offset, ptrdiff_t size, const void *data);
typedef void (APIENTRYP PFNGLDELETEBUFFERSPROC)(GLsizei n, const GLuint *buffers);

static PFNGLGENBUFFERSPROC pglGenBuffers = NULL;
static PFNGLBINDBUFFERPROC pglBindBuffer = NULL;
static PFNGLBUFFERDATAPROC pglBufferData = NULL;
static PFNGLBUFFERSUBDATAPROC pglBufferSubData = NULL;
static PFNGLDELETEBUFFERSPROC pglDeleteBuffers = NULL;

static wchar_t *utf8_to_wide(const char *input)
{
    int size_needed;
    wchar_t *buffer;

    if (input == NULL) {
        return NULL;
    }

    size_needed = MultiByteToWideChar(CP_UTF8, 0, input, -1, NULL, 0);
    if (size_needed <= 0) {
        return NULL;
    }

    buffer = (wchar_t *)malloc((size_t)size_needed * sizeof(wchar_t));
    if (buffer == NULL) {
        return NULL;
    }

    if (MultiByteToWideChar(CP_UTF8, 0, input, -1, buffer, size_needed) <= 0) {
        free(buffer);
        return NULL;
    }

    return buffer;
}

static int load_gl_buffer_functions(void)
{
    pglGenBuffers = (PFNGLGENBUFFERSPROC)wglGetProcAddress("glGenBuffers");
    pglBindBuffer = (PFNGLBINDBUFFERPROC)wglGetProcAddress("glBindBuffer");
    pglBufferData = (PFNGLBUFFERDATAPROC)wglGetProcAddress("glBufferData");
    pglBufferSubData = (PFNGLBUFFERSUBDATAPROC)wglGetProcAddress("glBufferSubData");
    pglDeleteBuffers = (PFNGLDELETEBUFFERSPROC)wglGetProcAddress("glDeleteBuffers");

    return pglGenBuffers != NULL && pglBindBuffer != NULL && pglBufferData != NULL && pglBufferSubData != NULL && pglDeleteBuffers != NULL;
}

static int initialize_gl_resources(int width, int height)
{
    PIXELFORMATDESCRIPTOR pfd;
    int pixel_format;

    g_gl_dc = GetDC(g_preview_window);
    if (g_gl_dc == NULL) {
        return 0;
    }

    ZeroMemory(&pfd, sizeof(pfd));
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;

    pixel_format = ChoosePixelFormat(g_gl_dc, &pfd);
    if (pixel_format == 0 || !SetPixelFormat(g_gl_dc, pixel_format, &pfd)) {
        return 0;
    }

    g_gl_rc = wglCreateContext(g_gl_dc);
    if (g_gl_rc == NULL || !wglMakeCurrent(g_gl_dc, g_gl_rc)) {
        return 0;
    }

    if (!load_gl_buffer_functions()) {
        return 0;
    }

    glViewport(0, 0, width, height);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_TEXTURE_2D);

    glGenTextures(1, &g_gl_texture);
    glBindTexture(GL_TEXTURE_2D, g_gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);

    pglGenBuffers(1, &g_gl_pbo);
    pglBindBuffer(GL_PIXEL_UNPACK_BUFFER, g_gl_pbo);
    pglBufferData(GL_PIXEL_UNPACK_BUFFER, (ptrdiff_t)((size_t)width * (size_t)height * 4), NULL, GL_STREAM_DRAW);
    pglBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);

    g_width = width;
    g_height = height;
    return 1;
}

static void render_gl_frame(const char *hud_text)
{
    (void)hud_text;

    if (g_gl_dc == NULL || g_gl_texture == 0 || g_gl_pbo == 0) {
        return;
    }

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    pglBindBuffer(GL_PIXEL_UNPACK_BUFFER, g_gl_pbo);
    glBindTexture(GL_TEXTURE_2D, g_gl_texture);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, g_width, g_height, GL_RGBA, GL_UNSIGNED_BYTE, 0);
    pglBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    glBegin(GL_QUADS);
    glTexCoord2f(0.0f, 1.0f); glVertex2f(-1.0f, -1.0f);
    glTexCoord2f(1.0f, 1.0f); glVertex2f(1.0f, -1.0f);
    glTexCoord2f(1.0f, 0.0f); glVertex2f(1.0f, 1.0f);
    glTexCoord2f(0.0f, 0.0f); glVertex2f(-1.0f, 1.0f);
    glEnd();

    SwapBuffers(g_gl_dc);
}

static LRESULT CALLBACK preview_window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    switch (message) {
    case WM_PAINT:
    {
        PAINTSTRUCT paint_struct;
        BeginPaint(hwnd, &paint_struct);
        render_gl_frame(g_hud_text);
        EndPaint(hwnd, &paint_struct);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}

extern "C" int initialize_preview_window(const char *title, int width, int height)
{
    WNDCLASSW window_class;
    wchar_t *wide_title;

    if (g_preview_window != NULL) {
        return 1;
    }

    ZeroMemory(&window_class, sizeof(window_class));
    window_class.lpfnWndProc = preview_window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = g_window_class_name;
    window_class.hCursor = LoadCursor(NULL, IDC_ARROW);

    RegisterClassW(&window_class);
    wide_title = utf8_to_wide(title != NULL ? title : "Simulation Preview");
    if (wide_title == NULL) {
        return 0;
    }

    g_preview_window = CreateWindowExW(
        0,
        g_window_class_name,
        wide_title,
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        width + 32,
        height + 54,
        NULL,
        NULL,
        GetModuleHandleW(NULL),
        NULL);

    free(wide_title);

    if (g_preview_window == NULL) {
        return 0;
    }

    if (!initialize_gl_resources(width, height)) {
        DestroyWindow(g_preview_window);
        g_preview_window = NULL;
        return 0;
    }

    ShowWindow(g_preview_window, SW_SHOW);
    UpdateWindow(g_preview_window);
    return 1;
}

extern "C" int process_preview_window_events(int *quit_requested)
{
    MSG message;

    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
        if (message.message == WM_QUIT) {
            if (quit_requested != NULL) {
                *quit_requested = 1;
            }
            return 0;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    return g_preview_window != NULL;
}

extern "C" int update_preview_window(const unsigned char *rgba, int width, int height, const char *title, const char *hud_text)
{
    wchar_t *wide_title;
    size_t pixel_size;

    if (g_preview_window == NULL || width <= 0 || height <= 0 || g_gl_pbo == 0) {
        return 0;
    }

    if (width != g_width || height != g_height) {
        return 0;
    }

    if (rgba != NULL) {
        pixel_size = (size_t)width * (size_t)height * 4;
        pglBindBuffer(GL_PIXEL_UNPACK_BUFFER, g_gl_pbo);
        pglBufferSubData(GL_PIXEL_UNPACK_BUFFER, 0, (ptrdiff_t)pixel_size, rgba);
        pglBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    }

    if (title != NULL) {
        wide_title = utf8_to_wide(title);
        if (wide_title != NULL) {
            SetWindowTextW(g_preview_window, wide_title);
            free(wide_title);
        }
    }

    if (hud_text != NULL) {
        strncpy(g_hud_text, hud_text, sizeof(g_hud_text) - 1);
        g_hud_text[sizeof(g_hud_text) - 1] = '\0';
    } else {
        g_hud_text[0] = '\0';
    }

    render_gl_frame(g_hud_text);
    return 1;
}

extern "C" int get_preview_cuda_pbo(unsigned int *pbo, int *width, int *height)
{
    if (g_preview_window == NULL || g_gl_pbo == 0) {
        return 0;
    }

    if (pbo != NULL) {
        *pbo = (unsigned int)g_gl_pbo;
    }
    if (width != NULL) {
        *width = g_width;
    }
    if (height != NULL) {
        *height = g_height;
    }

    return 1;
}

extern "C" void shutdown_preview_window(void)
{
    if (g_gl_rc != NULL && g_gl_dc != NULL) {
        wglMakeCurrent(g_gl_dc, g_gl_rc);
    }

    if (g_gl_pbo != 0 && pglDeleteBuffers != NULL) {
        pglDeleteBuffers(1, &g_gl_pbo);
        g_gl_pbo = 0;
    }

    if (g_gl_texture != 0) {
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
    }

    if (g_gl_rc != NULL) {
        wglMakeCurrent(NULL, NULL);
        wglDeleteContext(g_gl_rc);
        g_gl_rc = NULL;
    }

    if (g_gl_dc != NULL && g_preview_window != NULL) {
        ReleaseDC(g_preview_window, g_gl_dc);
        g_gl_dc = NULL;
    }

    if (g_preview_window != NULL) {
        DestroyWindow(g_preview_window);
        g_preview_window = NULL;
    }

    g_width = 0;
    g_height = 0;
    g_hud_text[0] = '\0';
}
