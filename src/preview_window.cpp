#include <windows.h>

#include <stdlib.h>
#include <string.h>

#include "preview_window.h"

static HWND g_preview_window = NULL;
static unsigned char *g_bgra = NULL;
static int g_width = 0;
static int g_height = 0;
static BITMAPINFO g_bitmap_info = {0};
static const wchar_t *g_window_class_name = L"UniversitySimulationPreviewWindow";
static char g_hud_text[512] = "";

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

static void ensure_bitmap_info(int width, int height)
{
    ZeroMemory(&g_bitmap_info, sizeof(g_bitmap_info));
    g_bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    g_bitmap_info.bmiHeader.biWidth = width;
    g_bitmap_info.bmiHeader.biHeight = -height;
    g_bitmap_info.bmiHeader.biPlanes = 1;
    g_bitmap_info.bmiHeader.biBitCount = 32;
    g_bitmap_info.bmiHeader.biCompression = BI_RGB;
}

static void ensure_buffer(int width, int height)
{
    if (g_bgra != NULL && g_width == width && g_height == height) {
        return;
    }

    free(g_bgra);
    g_bgra = (unsigned char *)malloc((size_t)width * (size_t)height * 4);
    g_width = width;
    g_height = height;
    ensure_bitmap_info(width, height);
}

static LRESULT CALLBACK preview_window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    switch (message) {
    case WM_PAINT:
    {
        PAINTSTRUCT paint_struct;
        HDC device_context = BeginPaint(hwnd, &paint_struct);
        RECT client_rect;

        GetClientRect(hwnd, &client_rect);
        if (g_bgra != NULL) {
            StretchDIBits(
                device_context,
                0,
                0,
                client_rect.right - client_rect.left,
                client_rect.bottom - client_rect.top,
                0,
                0,
                g_width,
                g_height,
                g_bgra,
                &g_bitmap_info,
                DIB_RGB_COLORS,
                SRCCOPY);

            SetBkMode(device_context, TRANSPARENT);
            SetTextColor(device_context, RGB(255, 255, 255));
            TextOutA(device_context, 8, 8, g_hud_text, (int)strlen(g_hud_text));
        }
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
    ensure_buffer(width, height);
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
        free(g_bgra);
        g_bgra = NULL;
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
    size_t pixel_count;
    size_t index;

    if (g_preview_window == NULL || rgba == NULL || width <= 0 || height <= 0) {
        return 0;
    }

    ensure_buffer(width, height);
    pixel_count = (size_t)width * (size_t)height;
    if (g_bgra == NULL) {
        return 0;
    }

    for (index = 0; index < pixel_count; ++index) {
        size_t src = index * 4;
        size_t dst = index * 4;
        g_bgra[dst + 0] = rgba[src + 2];
        g_bgra[dst + 1] = rgba[src + 1];
        g_bgra[dst + 2] = rgba[src + 0];
        g_bgra[dst + 3] = rgba[src + 3];
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

    InvalidateRect(g_preview_window, NULL, FALSE);
    UpdateWindow(g_preview_window);
    return 1;
}

extern "C" void shutdown_preview_window(void)
{
    if (g_preview_window != NULL) {
        DestroyWindow(g_preview_window);
        g_preview_window = NULL;
    }

    free(g_bgra);
    g_bgra = NULL;
    g_width = 0;
    g_height = 0;
    g_hud_text[0] = '\0';
}
