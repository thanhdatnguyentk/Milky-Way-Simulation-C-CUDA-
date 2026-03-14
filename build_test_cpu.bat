@echo off
setlocal

pushd "%~dp0"
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=x64 >nul
if errorlevel 1 goto :error

cl /nologo /W4 /Iinclude /Itests ^
    tests\test_cpu.c src\system.c src\simulation.c src\io.c ^
    /Fe:test_cpu.exe /link /MACHINE:X64
if errorlevel 1 goto :error

popd
echo.
echo CPU test build completed.
echo.
echo Running tests...
echo.
test_cpu.exe
exit /b %errorlevel%

:error
popd
echo.
echo CPU test build failed.
exit /b 1
