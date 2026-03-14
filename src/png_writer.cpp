#include <windows.h>
#include <wincodec.h>

#include "png_writer.h"

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

    buffer = new wchar_t[(size_t)size_needed];
    if (buffer == NULL) {
        return NULL;
    }

    if (MultiByteToWideChar(CP_UTF8, 0, input, -1, buffer, size_needed) <= 0) {
        delete[] buffer;
        return NULL;
    }

    return buffer;
}

extern "C" int write_png_rgba(const char *output_path, const unsigned char *rgba, int width, int height)
{
    HRESULT hr;
    IWICImagingFactory *factory = NULL;
    IWICBitmapEncoder *encoder = NULL;
    IWICBitmapFrameEncode *frame = NULL;
    IWICStream *stream = NULL;
    IPropertyBag2 *property_bag = NULL;
    wchar_t *wide_path = NULL;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppRGBA;
    int initialized_com = 0;
    int success = 0;

    if (output_path == NULL || rgba == NULL || width <= 0 || height <= 0) {
        return 0;
    }

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (SUCCEEDED(hr)) {
        initialized_com = 1;
    } else if (hr != RPC_E_CHANGED_MODE) {
        return 0;
    }

    wide_path = utf8_to_wide(output_path);
    if (wide_path == NULL) {
        goto cleanup;
    }

    hr = CoCreateInstance(
        CLSID_WICImagingFactory,
        NULL,
        CLSCTX_INPROC_SERVER,
        IID_IWICImagingFactory,
        reinterpret_cast<void **>(&factory));
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = factory->CreateStream(&stream);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = stream->InitializeFromFilename(wide_path, GENERIC_WRITE);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = factory->CreateEncoder(GUID_ContainerFormatPng, NULL, &encoder);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = encoder->CreateNewFrame(&frame, &property_bag);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = frame->Initialize(property_bag);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = frame->SetSize((UINT)width, (UINT)height);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = frame->SetPixelFormat(&format);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = frame->WritePixels(
        (UINT)height,
        (UINT)(width * 4),
        (UINT)(width * height * 4),
        const_cast<BYTE *>(reinterpret_cast<const BYTE *>(rgba)));
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = frame->Commit();
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = encoder->Commit();
    if (FAILED(hr)) {
        goto cleanup;
    }

    success = 1;

cleanup:
    if (property_bag != NULL) {
        property_bag->Release();
    }
    if (frame != NULL) {
        frame->Release();
    }
    if (encoder != NULL) {
        encoder->Release();
    }
    if (stream != NULL) {
        stream->Release();
    }
    if (factory != NULL) {
        factory->Release();
    }
    delete[] wide_path;
    if (initialized_com) {
        CoUninitialize();
    }

    return success;
}
