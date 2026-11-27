@echo off
rem ===========================================================================
rem  wsl-network.bat - fix WSL2 networking / proxy (the reason apt & git hang)
rem  Equivalent to:  build-android.bat wsl-network
rem
rem  Symptom it fixes:
rem    Windows runs a system proxy (e.g. 127.0.0.1:7890) with fake-IP DNS.
rem    In NAT mode WSL cannot reach the host's 127.0.0.1:7890 and resolves
rem    domains to blackhole addresses (198.18.x.x) - so apt / git time out.
rem
rem  What it does, in order:
rem    1) nothing, if the distribution already has internet access
rem    2) if the Windows proxy is reachable from WSL (proxy "Allow LAN" on):
rem         writes /etc/apt/apt.conf.d/99-krita-proxy and a profile.d script
rem    3) otherwise writes networkingMode=mirrored into %USERPROFILE%\.wslconfig
rem       and runs "wsl --shutdown" (mirrored mode makes 127.0.0.1 the host)
rem
rem  Options: --check (diagnose only), --proxy HOST:PORT, --mirrored
rem ===========================================================================
set "KRITA_BAT_FORCE_PAUSE=1"
call "%~dp0..\build-android.bat" wsl-network %*
