@echo off
rem ===========================================================================
rem  setup-sdk.bat - double-click friendly shortcut: install Android SDK / NDK
rem  Equivalent to:  build-android.bat sdk
rem  Add --dry-run to only print the commands without executing them.
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" sdk %*
