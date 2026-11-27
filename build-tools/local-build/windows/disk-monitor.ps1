param(
    [string]$LogFile = '',
    [string]$Drive = 'C:',
    [int]$IntervalSeconds = 30
)

# =============================================================================
#  disk-monitor.ps1 -- 周期性打印磁盘剩余空间
#
#  由 build-krita-windows.ps1 以子进程方式启动：
#    powershell -NoProfile -File disk-monitor.ps1 -LogFile <log> -Drive C: -IntervalSeconds 30
#
#  每 IntervalSeconds 秒输出一行到控制台，并追加到同一次构建的日志文件，
#  这样长构建过程中能直接看出磁盘是不是要被撑爆。
#
#  单独运行也可以（Ctrl+C 结束）：
#    powershell -File windows\disk-monitor.ps1 -Drive C: -IntervalSeconds 30
# =============================================================================

if ($IntervalSeconds -lt 1) { $IntervalSeconds = 30 }

while ($true) {
    $letter = $Drive.TrimEnd(':')
    $stamp = Get-Date -Format 'HH:mm:ss'
    try {
        $d = Get-PSDrive -Name $letter -ErrorAction Stop
        $total = $d.Free + $d.Used
        if ($total -gt 0) {
            $line = '[{0}] [disk] {1}: {2:N1} GB free / {3:N1} GB total ({4:P0} used)' -f `
                $stamp, $Drive, ($d.Free / 1GB), ($total / 1GB), ($d.Used / $total)
        } else {
            $line = '[{0}] [disk] {1}: {2:N1} GB free (total unknown)' -f `
                $stamp, $Drive, ($d.Free / 1GB)
        }
    } catch {
        $line = '[{0}] [disk] {1}: (unavailable)' -f $stamp, $Drive
    }

    Write-Host $line
    if ($LogFile) {
        try {
            Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        } catch {
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}
