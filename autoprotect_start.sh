#!/usr/bin/env bash
set -euo pipefail

# autoprotect_start.sh - Launch QEMU VM with AutoProtect enabled
# Configured for:
# - 3GB of RAM (-m 3G)
# - qcow2 disk image
# - AutoProtect snapshots every minute (interval=60s)
# - Retention of 1 hour (retention=1h)

usage() {
    local script_name
    script_name="$(basename "$0")"
    echo "Uso: $script_name <file.qcow2> [opzioni_qemu_aggiuntive...]"
    echo ""
    echo "Parametri:"
    echo "  <file.qcow2>       Percorso del file immagine disco in formato qcow2 (obbligatorio)"
    echo "  [opzioni_qemu...]  Ulteriori argomenti da passare direttamente a QEMU"
    echo ""
    echo "Esempio:"
    echo "  $script_name /var/lib/libvirt/images/ubuntu.qcow2"
    echo "  $script_name mydisk.qcow2 -nographic"
    exit 1
}

main() {
    if [[ $# -lt 1 ]]; then
        echo "Errore: specificare il file qcow2 come primo argomento." >&2
        usage
    fi

    local disk_image="$1"
    shift

    if [[ ! -f "$disk_image" ]]; then
        echo "Errore: il file '$disk_image' non esiste o non è un file regolare." >&2
        exit 1
    fi

    # Determina il percorso del binario QEMU compilato localmente (mai quello di sistema)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local qemu_bin="${script_dir}/build/qemu-system-x86_64"

    if [[ ! -x "$qemu_bin" ]]; then
        echo "Errore: binario QEMU compilato localmente non trovato o non eseguibile in:" >&2
        echo "  $qemu_bin" >&2
        echo "Compilare il progetto prima di avviare la VM (es. con 'ninja -C build qemu-system-x86_64' o 'make')." >&2
        exit 1
    fi

    local pid_file="/tmp/qemu_autoprotect.pid"

    # Selezione acceleratore (KVM se disponibile, altrimenti fallback su TCG)
    local accel_opts=()
    if [[ -w /dev/kvm ]]; then
        accel_opts=("-enable-kvm" "-cpu" "host")
        echo "[AutoProtect] Accelerazione KVM abilitata."
    else
        accel_opts=("-accel" "tcg")
        echo "[AutoProtect] KVM non disponibile, accelerazione TCG attiva."
    fi

    echo "[AutoProtect] Avvio macchina virtuale..."
    echo "[AutoProtect] - Binario QEMU: $qemu_bin"
    echo "[AutoProtect] - Disco:        $disk_image"
    echo "[AutoProtect] - Memoria RAM:  3 GB"
    echo "[AutoProtect] - Snapshot:     Ogni 60 secondi (1 minuto)"
    echo "[AutoProtect] - Retention:    1 ora (pruning automatico snapshot > 1h)"
    echo "[AutoProtect] - Modalità:     auto (live se UFFD-WP disponibile, altrimenti internal)"

    exec "$qemu_bin" \
        "${accel_opts[@]}" \
        -m 3G \
        -drive "file=${disk_image},format=qcow2,if=virtio" \
        -autoprotect "interval=60,retention=1,mode=auto" \
        -pidfile "$pid_file" \
        "$@"
}

main "$@"
