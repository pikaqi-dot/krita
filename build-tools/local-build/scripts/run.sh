#!/usr/bin/env bash
# =============================================================================
#  run.sh —— 由 build-android.bat 调用的日志包装器
#
#  作用：
#    1) 调用 build-android.sh，命令行的原始参数原样转发
#    2) 输出**同时**打印到控制台（实时可见）并写入 logs/<时间戳>-<命令>.log
#    3) 结束时把日志复制为 logs/latest.log，并返回真实退出码
#
#  为什么需要它：
#    在 .bat 里用 `>` 重定向会丢掉实时输出；用 cmd 的管道又拿不到退出码。
#    放在 bash 内部用 `tee` + PIPESTATUS 可以同时满足“实时可见 / 留档 / 退出码”。
#
#  用法（一般由 build-android.bat 调用，也可手工执行）:
#    ./scripts/run.sh <子命令> [参数...]
#    ./scripts/run.sh all --jobs 8
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

LOG_DIR="${KRITA_LOG_DIR:-$PROJECT_ROOT/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null

# 由 .bat 启动时，窗口保持交给 .bat 的 pause 处理，避免"等两次"
export KRITA_HOLD=0

cmd="${1:-help}"

# clean-logs 自己就是来删日志的：不能先建一个日志再删（会留下刚生成的这一个）
if [[ "$cmd" == "clean-logs" ]]; then
    exec bash "$PROJECT_ROOT/build-android.sh" "$@"
fi

# report 是只读快照：不需要日志包装（每次生成一个碎日志没意义），
# 而且它用退出码 1 表示"需要重新编译/打包"，被包装器当成"失败"会误导。
if [[ "$cmd" == "report" || "$cmd" == "status" ]]; then
    exec bash "$PROJECT_ROOT/build-android.sh" "$@"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
# 把命令名清洗成安全的文件名片段
safe="$(printf '%s' "$cmd" | tr -c 'A-Za-z0-9._-' '_')"
LOG="$LOG_DIR/${stamp}-${safe}.log"

# ---------------------------------------------------------------------------
# 磁盘剩余空间监视（默认每 30 秒一行）
#   * 第一行在构建开始前打印（基线），之后每 30 秒一行
#   * 同时写控制台与同一份构建日志，所以 CI 工件里也有
#   KRITA_DISK_MONITOR=0            关闭
#   KRITA_DISK_MONITOR_INTERVAL=N   间隔秒数（默认 30）
#   KRITA_DISK_MONITOR_PATH=DIR     监视哪个目录所在的卷（默认项目根）
# ---------------------------------------------------------------------------
disk_free_line() {
    local path="$1" out
    out="$(df -hP "$path" 2>/dev/null |
        awk 'NR==2 {printf "%s total, %s used, %s free (%s used)", $2, $3, $4, $5}')"
    [[ -n "$out" ]] || out='df unavailable'
    printf '%s' "$out"
}

disk_monitor_line() {
    local path="$1"
    printf '[disk] %s  %s  [%s]\n' "$(date '+%H:%M:%S')" "$(disk_free_line "$path")" "$path"
}

start_disk_monitor() {
    [[ "${KRITA_DISK_MONITOR:-1}" == "0" ]] && return 0
    local interval="${KRITA_DISK_MONITOR_INTERVAL:-30}"
    local path="${KRITA_DISK_MONITOR_PATH:-$PROJECT_ROOT}"

    # 基线（构建开始前）
    disk_monitor_line "$path" | tee -a "$LOG"

    (
        while :; do
            sleep "$interval"
            disk_monitor_line "$path"
            disk_monitor_line "$path" >>"$LOG"
        done
    ) &
    DISK_MONITOR_PID=$!
}

stop_disk_monitor() {
    [[ -n "${DISK_MONITOR_PID:-}" ]] || return 0
    kill "$DISK_MONITOR_PID" 2>/dev/null
    wait "$DISK_MONITOR_PID" 2>/dev/null
    DISK_MONITOR_PID=""
}

# ---------------------------------------------------------------------------
# 日志头（同时输出到控制台与日志文件）
# ---------------------------------------------------------------------------
{
    printf '# ============================================================\n'
    printf '# Krita for Android 构建日志\n'
    printf '# 时间   : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# 命令   : ./build-android.sh %s\n' "$*"
    printf '# 工作目录: %s\n' "$PROJECT_ROOT"
    printf '# 系统   : %s\n' "$(uname -srm 2>/dev/null || echo unknown)"
    printf '# bash   : %s\n' "$(bash --version 2>/dev/null | head -n 1)"
    printf '# 日志   : %s\n' "$LOG"
    printf '# ============================================================\n\n'
} | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 执行（实时输出 + 写入日志；期间每 30 秒打印一次磁盘剩余空间）
# ---------------------------------------------------------------------------
start_disk_monitor
bash "$PROJECT_ROOT/build-android.sh" "$@" 2>&1 | tee -a "$LOG"
rc="${PIPESTATUS[0]}"
stop_disk_monitor

if (( rc == 0 )); then
    printf '\n# ------------------------------------------------------------\n# 退出码: 0（成功）\n' | tee -a "$LOG"
else
    printf '\n# ------------------------------------------------------------\n# 退出码: %d（失败）\n' "$rc" | tee -a "$LOG"
    printf '# 排查建议: 先看本日志中第一条 [err]，或执行 ./build-android.sh check\n' | tee -a "$LOG"
fi
printf '# 日志文件: %s\n# ------------------------------------------------------------\n' "$LOG" | tee -a "$LOG"

# latest.log 便于快速定位最近一次运行的结果
cp -f "$LOG" "$LOG_DIR/latest.log" 2>/dev/null || true

exit "$rc"
