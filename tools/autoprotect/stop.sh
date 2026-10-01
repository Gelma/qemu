#!/usr/bin/env bash
set -euo pipefail

# QEMU AutoProtect stop script
readonly DEFAULT_PIDFILE="/tmp/qemu-autoprotect.pid"
PIDFILE="${PIDFILE:-"$DEFAULT_PIDFILE"}"

stop_daemon() {
    local pid
    if [[ ! -f "$PIDFILE" ]]; then
        echo "[AutoProtect] No PID file found at '$PIDFILE'. Daemon is not running."
        return 0
    fi

    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -z "$pid" ]]; then
        echo "[AutoProtect] PID file was empty. Removing '$PIDFILE'."
        rm -f "$PIDFILE"
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "[AutoProtect] Process $pid is not active. Removing stale PID file."
        rm -f "$PIDFILE"
        return 0
    fi

    echo "[AutoProtect] Sending SIGTERM to process $pid..."
    kill -TERM "$pid"

    local timeout=15
    local count=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [[ "$count" -ge "$timeout" ]]; then
            echo "[AutoProtect] Process did not terminate within $timeout seconds. Sending SIGKILL..."
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
    done

    rm -f "$PIDFILE"
    echo "[AutoProtect] Daemon (PID $pid) stopped successfully."
}

stop_daemon
