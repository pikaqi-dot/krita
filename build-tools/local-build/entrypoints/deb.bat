@echo off
rem ===========================================================================
rem  deb.bat -- build the Linux desktop Krita and package it as a .deb
rem
rem  Equivalent to:  build-android.bat deb %*
rem  It always runs inside WSL (a Linux desktop build cannot be done on Windows).
rem
rem  Usage:
rem    deb.bat --check-deps        only list missing build dependencies
rem    deb.bat --install-deps      apt-get install the build dependencies (sudo)
rem    deb.bat                     configure + compile + package (incremental)
rem    deb.bat --clean --jobs 12   rebuild from scratch
rem    deb.bat --qt6               build the Qt6 flavour (experimental, 6.x)
rem
rem  Output: dist\krita_<version>_<arch>.deb
rem  The Android pipeline is untouched: Linux uses <src>\_build_linux,
rem  Android keeps using <src>\_build.
rem ===========================================================================
setlocal
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" deb %*
exit /b %ERRORLEVEL%

:help
echo Usage: deb.bat [options]
echo.
echo   --check-deps      list missing build dependencies only
echo   --install-deps    apt-get install them (needs sudo)
echo   --build-type T    RelWithDebInfo (default) / Release / Debug
echo   --qt6             Qt6 flavour (experimental)
echo   --jobs N          parallel build jobs
echo   --prefix PATH     install prefix inside the deb (default /usr)
echo   --clean           delete _build_linux first
echo   --no-deb          compile + stage only, skip dpkg-deb
echo   --force           ignore the incremental stamp
echo   --dry-run         print the commands only
echo.
echo Output: dist\krita_^<version^>_^<arch^>.deb
echo Full help (Chinese):  build-android.bat deb --help
exit /b 0
