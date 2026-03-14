@echo off
setlocal

set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.4"
set "HOST_CL=C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64"

pushd "%~dp0"
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=x64 >nul
if errorlevel 1 goto :error

rem --- Compile C source modules ---
cl /nologo /W4 /Iinclude /c src\system.c     /Fo:_sys.obj
if errorlevel 1 goto :error

cl /nologo /W4 /Iinclude /c src\simulation.c /Fo:_sim.obj
if errorlevel 1 goto :error

cl /nologo /W4 /Iinclude /c src\io.c         /Fo:_io.obj
if errorlevel 1 goto :error

cl /nologo /EHsc /Iinclude /c src\png_writer.cpp /Fo:_png.obj
if errorlevel 1 goto :error

rem --- Compile CUDA kernels ---
nvcc -ccbin "%HOST_CL%" -c -Iinclude cuda\nbody.cu -o _nbody.obj
if errorlevel 1 goto :error

rem --- Compile GPU test driver (CUDA + C++ harness) ---
nvcc -ccbin "%HOST_CL%" -c -Iinclude -Itests tests\test_gpu.cu -o _test_gpu.obj
if errorlevel 1 goto :error

rem --- Link everything; cl handles CUDA .obj produced by nvcc ---
cl /nologo /Iinclude /DUSE_CUDA ^
    _sys.obj _sim.obj _io.obj _png.obj _nbody.obj _test_gpu.obj ^
    /Fe:test_gpu.exe ^
    /link /MACHINE:X64 /LIBPATH:"%CUDA_PATH%\lib\x64" cudart.lib windowscodecs.lib ole32.lib
if errorlevel 1 goto :error

del _sys.obj _sim.obj _io.obj _png.obj _nbody.obj _test_gpu.obj 2>nul

popd
echo.
echo GPU test build completed.
echo.
echo Running tests...
echo.
test_gpu.exe
exit /b %errorlevel%

:error
del _sys.obj _sim.obj _io.obj _png.obj _nbody.obj _test_gpu.obj 2>nul
popd
echo.
echo GPU test build failed.
exit /b 1
