@echo off
rem ===========================================================================
rem  docker-build.bat  --  OPTIONAL: build inside a Docker container
rem
rem  Default route is still wsl-build.bat (no Docker). Use this one only if you
rem  want a reproducible containerized toolchain.
rem
rem  Requirements:
rem    * Docker available inside WSL2 (Docker Desktop WSL integration, or
rem      "sudo apt install docker.io" + "sudo service docker start")
rem    * First run builds the image (docker/Dockerfile, ~1-2 min)
rem
rem  Usage:
rem    docker-build.bat                        full pipeline in container
rem    docker-build.bat --build-image          (re)build image, then build
rem    docker-build.bat --from 5 --jobs 8      resume from step 5
rem
rem  Equivalent to:  build-android.bat docker %*
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" docker %*
