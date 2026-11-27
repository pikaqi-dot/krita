@echo off
rem ===========================================================================
rem  clean-logs.bat -- delete all *.log / *.txt build logs and temp text files
rem
rem  Equivalent to:  build-android.bat clean-logs %*
rem
rem  Usage:
rem    clean-logs.bat                 list, then ask for confirmation
rem    clean-logs.bat --list          only list (delete nothing)
rem    clean-logs.bat -y              delete without asking
rem    clean-logs.bat --keep 5 -y     keep the 5 newest *.log per folder
rem    clean-logs.bat --log-only -y   only *.log (keep *.txt)
rem    clean-logs.bat --dirs "C:\krita-dev\logs" -y
rem                                   also clean extra folders (recursive)
rem
rem  Safety:
rem    * files tracked by git are SKIPPED (use --include-tracked to override)
rem    * .git / dist / _build* / _install* / PythonEnv* / node_modules skipped
rem ===========================================================================
setlocal
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" clean-logs %*
exit /b %ERRORLEVEL%

:help
echo Usage: clean-logs.bat [options]
echo.
echo   (no option)        list files, then ask for confirmation
echo   --list             only list, delete nothing
echo   -y, --yes          delete without asking
echo   --keep N           keep the N newest *.log per folder
echo   --log-only         only *.log
echo   --txt-only         only *.txt
echo   --dirs "A B"       extra folders to clean (recursive)
echo   --include-tracked  also delete files tracked by git (dangerous)
echo.
echo Full help (Chinese):  build-android.bat clean-logs --help
exit /b 0
