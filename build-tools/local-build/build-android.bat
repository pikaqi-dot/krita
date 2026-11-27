@echo off
rem ===========================================================================
rem  build-android.bat - launcher for the Krita-for-Android build scripts
rem
rem  Why this file exists (the "window closes instantly" problem):
rem    1) On many Windows machines "bash" in PATH resolves to
rem       C:\Windows\System32\bash.exe, which is the *WSL* launcher, not
rem       Git Bash. It cannot access MSYS-style paths such as /c/... and
rem       exits immediately, so the console window disappears.
rem       This launcher therefore locates Git Bash explicitly and rejects
rem       the WSL launcher.
rem    2) A plain launcher also closes its window when a command fails.
rem       This one pauses (when double-clicked) and writes a full log to
rem       .\logs\ so the error message is never lost.
rem
rem  Usage:  build-android.bat <command> [options]
rem  Env:    KRITA_BASH            full path to Git's bash.exe (optional)
rem          KRITA_BAT_NOPAUSE=1   never pause at the end
rem
rem  Notes:  This file intentionally contains NO non-ASCII text: cmd.exe can
rem          mis-parse UTF-8 batch files when the code page changes.
rem          All Chinese output comes from the bash scripts (through tee).
rem ===========================================================================
setlocal enableextensions enabledelayedexpansion
chcp 65001 >nul 2>&1
title Krita Android build (Git Bash)

rem --- move to this script's folder (makes double-click predictable) --------
cd /d "%~dp0"

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "HERE_FWD=%HERE:\=/%"

if not defined KRITA_BAT_NOPAUSE set "KRITA_BAT_NOPAUSE=0"

rem --- 1) locate Git Bash ---------------------------------------------------
set "GBASH="
call :try_bash "%KRITA_BASH%"
call :try_bash "%ProgramFiles%\Git\bin\bash.exe"
call :try_bash "%ProgramFiles(x86)%\Git\bin\bash.exe"
call :try_bash "%LocalAppData%\Programs\Git\bin\bash.exe"
call :try_bash "%USERPROFILE%\scoop\apps\git\current\bin\bash.exe"
call :try_bash "%USERPROFILE%\scoop\apps\git\current\usr\bin\bash.exe"
if not defined GBASH call :find_from_git
if not defined GBASH goto :no_bash

rem --- 2) reject the WSL bash.exe ------------------------------------------
set "IS_WSL=0"
call :probe_bash "%GBASH%"
if "%IS_WSL%"=="1" goto :wsl_bash

rem --- 3) run ---------------------------------------------------------------
echo [INFO] Git Bash : %GBASH%
echo [INFO] Project  : %HERE%
echo [INFO] Command  : %*
echo.

if "%~1"=="" goto :show_usage

if exist "%HERE%\scripts\run.sh" (
  "%GBASH%" --noprofile --norc "%HERE_FWD%/scripts/run.sh" %*
) else (
  "%GBASH%" --noprofile --norc "%HERE_FWD%/build-android.sh" %*
)
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo [OK] finished, exit code 0
) else (
  echo [FAILED] exit code %RC%
  echo          see the log for the first [err] line.
)
goto :hold

:show_usage
call :usage
set "RC=0"
goto :hold

rem ===========================================================================
rem  subroutines
rem ===========================================================================
:try_bash
rem keep the first hit; %1 may be "" when the variable is undefined
if defined GBASH exit /b 0
if "%~1"=="" exit /b 0
if exist "%~1" set "GBASH=%~f1"
exit /b 0

:find_from_git
rem git.exe normally lives in <GitRoot>\cmd\git.exe, bash in <GitRoot>\bin
for /f "delims=" %%I in ('where git.exe 2^>nul') do (
  if not defined GBASH (
    set "CAND=%%~dpI..\bin\bash.exe"
    if exist "!CAND!" set "GBASH=!CAND!"
  )
)
exit /b 0

:probe_bash
rem Git Bash reports an "msys" OSTYPE, the WSL launcher reports "linux-gnu"
set "IS_WSL=0"
if "%~1"=="" exit /b 0
if /i "%~f1"=="%SystemRoot%\System32\bash.exe" set "IS_WSL=1"
set "PROBE="
for /f "delims=" %%O in ('"%~1" --noprofile --norc -c "echo $OSTYPE" 2^>nul') do set "PROBE=%%O"
if not defined PROBE exit /b 0
echo !PROBE! | findstr /i /c:"linux" >nul
if !errorlevel! equ 0 set "IS_WSL=1"
exit /b 0

:usage
rem ---------------------------------------------------------------------------
rem  Delegate the command list to the bash side.
rem
rem  There must be exactly ONE source of truth. The hand-maintained list that
rem  used to live here silently went stale (it was missing sign / deb / report
rem  and never mentioned apk --release), which is exactly the kind of drift
rem  scripts/check-docs.sh is meant to catch.
rem ---------------------------------------------------------------------------
echo Usage: build-android.bat ^<command^> [options]
echo.
echo Command list comes from build-android.sh (Chinese output):
echo.
"%GBASH%" --noprofile --norc "%HERE_FWD%/build-android.sh" help
echo.
echo Logs      : .\logs\latest.log
echo No pause  : set KRITA_BAT_NOPAUSE=1
echo Shortcuts : .\entrypoints\  (wsl-build.bat = one click: network + toolchain + build)
echo.
echo Tip: the same commands work directly as ./build-android.sh ^<command^>
echo      inside Git Bash / WSL / Linux.
exit /b 0

rem ===========================================================================
rem  error exits
rem ===========================================================================
:no_bash
echo.
echo [ERROR] Git Bash was not found.
echo.
echo   Install Git for Windows : https://git-scm.com/download/win
echo   or point KRITA_BASH at your bash.exe, for example:
echo     set "KRITA_BASH=C:\Program Files\Git\bin\bash.exe"
echo.
echo   NOTE: C:\Windows\System32\bash.exe is the WSL launcher and cannot
echo         run these scripts (it also closes the window instantly).
set "RC=1"
goto :hold

:wsl_bash
echo.
echo [ERROR] The bash found is the WSL launcher, not Git Bash:
echo         %GBASH%
echo.
echo   Please install Git for Windows, or set:
echo     set "KRITA_BASH=C:\Program Files\Git\bin\bash.exe"
echo.
echo   To build inside WSL2 on purpose see README.md, section "Windows .bat".
set "RC=1"
goto :hold

rem ===========================================================================
rem  keep the window open
rem ===========================================================================
:hold
echo.
if exist "%HERE%\logs\latest.log" echo   Log file: %HERE%\logs\latest.log
call :decide_pause
if "%DO_PAUSE%"=="1" (
  echo.
  echo   Press any key to close this window . . .
  pause >nul
)
endlocal & exit /b %RC%

:decide_pause
set "DO_PAUSE=0"
if "%KRITA_BAT_NOPAUSE%"=="1" exit /b 0
if "%KRITA_BAT_FORCE_PAUSE%"=="1" set "DO_PAUSE=1"
rem %cmdcmdline% contains this file name only when started by double-click
rem or by "cmd /c <file>.bat" - i.e. exactly when the window would close.
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul
if %errorlevel% equ 0 set "DO_PAUSE=1"
exit /b 0
