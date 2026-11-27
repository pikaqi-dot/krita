@echo off
rem ===========================================================================
rem  wsl-check.bat - double-click friendly shortcut: inspect the WSL2 side
rem  Equivalent to:  build-android.bat wsl --check
rem
rem  It reports: which distribution is used, the path mapping, and whether the
rem  needed toolchain (git / cmake / ninja / g++ / python3 / JDK 17 / unzip) is
rem  installed inside that distribution - plus the exact apt command to fix it.
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" wsl --check %*
