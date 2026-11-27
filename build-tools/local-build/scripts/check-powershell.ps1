#Requires -Version 5.1
# =============================================================================
#  check-powershell.ps1 -- sanity check for the Windows build scripts
#
#  Why: windows/*.ps1 must be UTF-8 **with BOM** (PowerShell 5.1 decodes
#  BOM-less files as ANSI/GBK, which breaks every Chinese string and can turn
#  the whole script into a parse error). They must also keep CRLF line endings.
#  *.bat (windows/ and entrypoints/) must stay pure ASCII (cmd.exe mis-parses
#  UTF-8 batch files).
#
#  This script is used by CI (ubuntu-latest + pwsh) and can be run locally:
#     pwsh -File scripts/check-powershell.ps1
#     powershell -ExecutionPolicy Bypass -File scripts\check-powershell.ps1
#
#  Output is ASCII-only on purpose (works in any console / CI log).
# =============================================================================
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$winDir = Join-Path $root 'windows'
$failed = 0

function Test-HasBom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Test-HasCrLf {
    param([byte[]]$Bytes)
    for ($i = 0; $i -lt ($Bytes.Length - 1); $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10) { return $true }
    }
    return $false
}

function Test-IsAscii {
    param([byte[]]$Bytes)
    foreach ($b in $Bytes) { if ($b -gt 127) { return $false } }
    return $true
}

$psFiles = @(Get-ChildItem -Path $winDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
if ($psFiles.Count -eq 0) {
    Write-Host 'FAIL no *.ps1 found under windows/'
    exit 1
}

foreach ($f in $psFiles) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bom = Test-HasBom -Bytes $bytes
    $crlf = Test-HasCrLf -Bytes $bytes
    $errs = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    } catch {
        $errs = @($_.Exception)
    }
    $parseCount = 0
    if ($errs) { $parseCount = @($errs).Count }

    if ($bom -and $crlf -and $parseCount -eq 0) {
        Write-Host ("OK   {0}" -f $f.Name)
    } else {
        $failed++
        Write-Host ("FAIL {0}  bom={1} crlf={2} parseErrors={3}" -f $f.Name, $bom, $crlf, $parseCount)
        if ($errs) {
            foreach ($e in @($errs)) {
                if ($e.Extent) {
                    Write-Host ("     line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
                } else {
                    Write-Host ("     {0}" -f $e)
                }
            }
        }
    }
}

$batDirs = @(
    $winDir,
    (Join-Path $root 'entrypoints'),
    $root
)
foreach ($dir in $batDirs) {
    $batFiles = @(Get-ChildItem -Path $dir -Filter '*.bat' -File -ErrorAction SilentlyContinue)
    foreach ($f in $batFiles) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $ascii = Test-IsAscii -Bytes $bytes
        $crlf = Test-HasCrLf -Bytes $bytes
        if ($ascii -and $crlf) {
            Write-Host ("OK   {0}" -f $f.Name)
        } else {
            $failed++
            Write-Host ("FAIL {0}  ascii={1} crlf={2}" -f $f.Name, $ascii, $crlf)
        }
    }
}

if ($failed -gt 0) {
    Write-Host ("`n{failed} file(s) failed the check.")
    exit 1
}
Write-Host "`nAll Windows scripts OK (BOM + CRLF + parseable)."
exit 0
