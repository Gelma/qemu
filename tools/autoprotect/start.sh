#!/usr/bin/env bash
set -euo pipefail

# QEMU AutoProtect start script
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_SOCKET="/tmp/qemu-qmp.sock"
readonly DEFAULT_PIDFILE="/tmp/qemu-autoprotect.pid"
readonly DEFAULT_LOGFILE="/tmp/qemu-autoprotect.log"

QMP_SOCKET="${QMP_SOCKET:-"$DEFAULT_SOCKET"}"
PIDFILE="${PIDFILE:-"$DEFAULT_PIDFILE"}"
LOGFILE="${LOGFILE:-"$DEFAULT_LOGFILE"}"
INTERVAL_MINUTES="${INTERVAL_MINUTES:-"30"}"
RETENTION_HOURS="${RETENTION_HOURS:-"24"}"
PREFIX="${PREFIX:-"autoprotect-"}"
EXTRA_ARGS="${EXTRA_ARGS:-""}"

start_daemon() {
    local pid
    if [[ -f "$PIDFILE" ]]; then
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "[AutoProtect] Daemon is already running (PID: $pid)."
            return 0
        else
            echo "[AutoProtect] Removing stale PID file '$PIDFILE'."
            rm -f "$PIDFILE"
        fi
    fi

    echo "[AutoProtect] Starting AutoProtect daemon..."
    echo "[AutoProtect]   QMP Socket:       $QMP_SOCKET"
    echo "[AutoProtect]   Interval:         $INTERVAL_MINUTES minute(s)"
    echo "[AutoProtect]   Retention:        $RETENTION_HOURS hour(s)"
    echo "[AutoProtect]   Snapshot Prefix:  $PREFIX"
    echo "[AutoProtect]   Log file:         $LOGFILE"
    echo "[AutoProtect]   PID file:         $PIDFILE"

    # Start in background
    nohup "$SCRIPT_DIR/autoprotect.py" \
        --socket "$QMP_SOCKET" \
        --interval-minutes "$INTERVAL_MINUTES" \
        --retention-hours "$RETENTION_HOURS" \
        --prefix "$PREFIX" \
        --pidfile "$PIDFILE" \
        --log-file "$LOGFILE" \
        --mode daemon \
        $EXTRA_ARGS >/dev/null 2>&1 &

    local new_pid="$!"
    sleep 1

    if kill -0 "$new_pid" 2>/dev/null; then
        echo "[AutoProtect] Daemon successfully started with PID: $new_pid"
        return 0
    else
        echo "[AutoProtect] ERROR: Daemon process exited immediately. Inspect log: '$LOGFILE'"
        return 1
    fi
}

start_daemon
