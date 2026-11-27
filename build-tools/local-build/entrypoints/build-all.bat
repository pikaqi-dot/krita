@echo off
rem ===========================================================================
rem  build-all.bat - double-click friendly shortcut: full build pipeline
rem  Equivalent to:  build-android.bat all
rem
rem  NOTE: on Windows the real compilation needs Linux. Prefer:
rem        wsl-build.bat        (runs the whole pipeline inside WSL2)
rem  Use this file only if you are already inside a Linux-like environment
rem  or want to drive the WSL route manually.
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" all %*
