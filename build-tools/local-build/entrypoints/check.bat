@echo off
rem ===========================================================================
rem  check.bat - double-click friendly shortcut: environment check
rem  Equivalent to:  build-android.bat check
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" check %*
