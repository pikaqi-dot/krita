@echo off
rem ===========================================================================
rem  krita-build.bat -- build Krita for Windows natively (llvm-mingw + Ninja)
rem
rem  This is a thin wrapper around build-krita-windows.ps1 so you can
rem  double-click it. Everything is logged to <Workspace>\logs\win-build-*.log
rem
rem  Usage:
rem    krita-build.bat                 same as -Step all
rem    krita-build.bat check           only check prerequisites
rem    krita-build.bat toolchain       download llvm-mingw / ninja / cmake
rem    krita-build.bat env             venv + deps + env.bat
rem    krita-build.bat sources         clone krita
rem    krita-build.bat configure       cmake -G Ninja
rem    krita-build.bat build           ninja install
rem    krita-build.bat deploy          copy llvm-mingw runtime DLLs (so the exe
rem                                    can be double-clicked without env.bat)
rem    krita-build.bat run             start _install\bin\krita.exe
rem    krita-build.bat clean           remove b_krita
rem
rem  Extra options (pass through to PowerShell):
rem    -Root D:\krita           put EVERYTHING (toolchain + sources + dependency
rem                             cache + build output) on that drive:
rem                               D:\krita\dev   (workspace)
rem                               D:\krita\deps  (toolchain)
rem    -Workspace C:\krita-dev  -DepsRoot C:\krita-deps   (set each one yourself)
rem    -Force                   ignore the incremental stamps: re-run cmake and
rem                             rebuild everything even if nothing changed
rem                             (default: configure/build are SKIPPED when the
rem                              sources and settings are unchanged)
rem    -InstallPython           -UseSystemTools     -ForceToolchain    -CleanBuild
rem    -Jobs 8                  -Shallow           -Update
rem    -RunArgs "--nosplash"     extra arguments passed to krita.exe (with "run")
rem    -HttpProxy http://127.0.0.1:7890   (also sets HTTP(S)_PROXY + NO_PROXY)
rem    -NoProxy                 bypass every proxy for this run (clears env vars and
rem                             sets NO_PROXY=*, which also overrides the Windows
rem                             "system proxy" in the registry -- use it for TUN/VPN)
rem    -SkipEnv                 reuse the existing env.bat, skip dependency fetch
rem                             (4 seconds to build when deps are already installed)
rem    -RefreshEnv              force a fresh dependency fetch (network) even if
rem                             nothing changed. By default step 3 is SKIPPED when
rem                             env.bat exists and deps-management/ci-utilities
rem                             commits are unchanged.
rem    -EnvRetries 3            how many times the env step retries (alternates
rem                             proxy <-> direct)
rem    -EnvIdleTimeout 120      kill one env attempt after N seconds without any
rem                             output (0 = unlimited)
rem                             NOTE: if env still fails but env.bat exists, the
rem                             build continues with the existing environment.
rem    -RecreateVenv            delete and recreate PythonEnv (requires Python 3.13)
rem
rem  Examples:
rem    krita-build.bat all -Root D:\krita -InstallPython
rem    krita-build.bat all -InstallPython -HttpProxy http://127.0.0.1:7890
rem    krita-build.bat build -Jobs 12
rem
rem  Requirements: Windows 10/11, PowerShell 5.1+, Git.
rem  Set KRITA_WIN_NOPAUSE=1 to skip the "press any key" at the end.
rem ===========================================================================
setlocal
chcp 65001 >nul

if not exist "%~dp0build-krita-windows.ps1" (
    echo [x] build-krita-windows.ps1 not found next to this .bat
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-krita-windows.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [x] FAILED, exit code %RC%
    echo [i] See the log under the workspace logs folder.
)

if /i "%KRITA_WIN_NOPAUSE%"=="1" exit /b %RC%
pause
exit /b %RC%
