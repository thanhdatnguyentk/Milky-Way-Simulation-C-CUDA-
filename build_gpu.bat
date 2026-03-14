@echo off
setlocal

set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.4"
set "HOST_CL=C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64"

pushd "%~dp0"
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=x64 >nul
if errorlevel 1 goto :error

nvcc -ccbin "%HOST_CL%" -c -Iinclude cuda\nbody.cu -o nbody_cuda.obj
if errorlevel 1 goto :error

cl /nologo /EHsc /Iinclude /c src\png_writer.cpp /Fo:png_writer.obj
if errorlevel 1 goto :error

cl /nologo /EHsc /Iinclude /c src\preview_window.cpp /Fo:preview_window.obj
if errorlevel 1 goto :error

cl /nologo /W4 /DUSE_CUDA /Iinclude main.c src\system.c src\simulation.c src\io.c png_writer.obj preview_window.obj nbody_cuda.obj /Fe:simulation_gpu.exe /link /MACHINE:X64 /LIBPATH:"%CUDA_PATH%\lib\x64" cudart.lib windowscodecs.lib ole32.lib user32.lib gdi32.lib
if errorlevel 1 goto :error

del png_writer.obj 2>nul
del preview_window.obj 2>nul

popd
echo GPU build completed.
exit /b 0

:error
del png_writer.obj 2>nul
del preview_window.obj 2>nul
popd
echo GPU build failed.
exit /b 1