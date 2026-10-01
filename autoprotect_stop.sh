#!/usr/bin/env bash
set -euo pipefail

# autoprotect_stop.sh - Stop QEMU VM started with autoprotect_start.sh

main() {
    local pid_file="/tmp/qemu_autoprotect.pid"

    if [[ ! -f "$pid_file" ]]; then
        echo "[AutoProtect] Nessun file PID trovato in $pid_file. La VM potrebbe non essere in esecuzione."
        exit 0
    fi

    local pid
    pid="$(cat "$pid_file")"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        echo "[AutoProtect] Il processo PID $pid non è attivo. Pulizia del file PID..."
        rm -f "$pid_file"
        exit 0
    fi

    echo "[AutoProtect] Arresto della VM QEMU (PID: $pid)..."
    kill -TERM "$pid"

    local timeout=15
    local count=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [[ $count -ge $timeout ]]; then
            echo "[AutoProtect] Timeout raggiunto ($timeout s). Invio SIGKILL forzato..."
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
    done

    rm -f "$pid_file"
    echo "[AutoProtect] VM arrestata con successo."
}

main "$@"
