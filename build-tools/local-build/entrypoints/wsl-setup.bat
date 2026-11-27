@echo off
rem ===========================================================================
rem  wsl-setup.bat - install the build toolchain inside your WSL2 distribution
rem  Equivalent to:  build-android.bat wsl-install
rem
rem  It runs (as WSL root, no sudo password needed):
rem    apt-get update
rem    apt-get install -y build-essential cmake ninja-build pkgconf git curl
rem        unzip openjdk-17-jdk python3 python3-pip python3-venv
rem
rem  Then it switches java/javac to JDK 17 via update-alternatives if needed,
rem  and re-checks the result.
rem
rem  Network required. Add --check to only inspect without installing.
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" wsl-install %*
