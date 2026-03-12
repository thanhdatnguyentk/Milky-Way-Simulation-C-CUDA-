@echo off
setlocal

pushd "%~dp0"
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=x64 >nul
if errorlevel 1 goto :error

cl /nologo /W4 /Iinclude main.c src\system.c src\simulation.c src\io.c /Fe:simulation_cpu.exe /link /MACHINE:X64
if errorlevel 1 goto :error

popd
echo CPU build completed.
exit /b 0

:error
popd
echo CPU build failed.
exit /b 1