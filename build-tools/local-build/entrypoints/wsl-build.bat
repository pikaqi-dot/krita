@echo off
rem ===========================================================================
rem  wsl-build.bat  *** THIS IS THE ONE YOU WANT ***
rem
rem  One-click route on Windows: Git Bash drives WSL2, the Linux distribution
rem  does the real compilation (the officially required way).
rem
rem  It performs, all idempotently:
rem    1) network check   - fixes the proxy / fake-IP problem that makes apt
rem                         and git time out inside WSL
rem    2) toolchain setup - apt packages + JDK 17 (falls back to Adoptium
rem                         Temurin 17 when the repository has no openjdk-17-jdk,
rem                         as on Debian 13 / trixie)
rem    3) full build      - clone sources, prepare env, cmake, compile, package
rem
rem  Equivalent to:  build-android.bat wsl-oneclick
rem  Prepare only  :  build-android.bat wsl-oneclick --prepare-only
rem  Release build :  wsl-build.bat --release --sign
rem                   (release apk is -unsigned; --sign signs it at the end)
rem  Extra args are passed through: --release / --nightly / --sign / --aab /
rem                   --from N / --only N / --force / --jobs N
rem
rem  The build takes a long time (typically over an hour). Output is shown live
rem  AND written to .\logs\latest.log. The window stays open at the end.
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" wsl-oneclick %*
