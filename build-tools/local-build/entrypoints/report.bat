@echo off
rem ===========================================================================
rem  report.bat -- build artifact / incremental-state report
rem
rem  Equivalent to:  build-android.bat report %*
rem
rem  Usage:
rem    report.bat            human readable
rem    report.bat --quiet    only incremental state + artifacts
rem    report.bat --json     machine readable (for CI)
rem
rem  Read-only: does not compile, download or modify anything.
rem  Exit code 0 = everything up to date, 1 = rebuild needed.
rem ===========================================================================
setlocal
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" report %*
exit /b %ERRORLEVEL%

:help
echo Usage: report.bat [options]
echo.
echo   (no option)   full report (config/paths/source/toolchain/incremental/artifacts)
echo   --quiet, -q   only incremental state and artifacts
echo   --json        JSON output
echo.
echo Exit code 0 = up to date, 1 = needs rebuild / repackage.
echo Full help (Chinese):  build-android.bat report --help
exit /b 0
