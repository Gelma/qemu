#!/usr/bin/env bash
set -euo pipefail

# autoprotect_start.sh - Launch QEMU VM with AutoProtect enabled
# Configured for:
# - 3GB of RAM (-m 3G)
# - qcow2 disk image
# - AutoProtect live non-blocking snapshots every minute (interval=60s)
# - Retention of 1 hour (retention=1h)
# - Delta files placed in the same directory as the base qcow2 file
# - Night prune support (cancellazione massiva differita nelle ore notturne 23:00-06:00)
# - Bridged networking on eth0 (guest appare come PC indipendente sulla LAN fisica con DHCP proprio)

usage() {
    local script_name
    script_name="$(basename "$0")"
    echo "Uso: $script_name <file.qcow2> [opzioni...]"
    echo ""
    echo "Parametri:"
    echo "  <file.qcow2>          Percorso del file immagine disco in formato qcow2 (obbligatorio)"
    echo ""
    echo "Opzioni:"
    echo "  --night-prune         Abilita la cancellazione massiva differita solo di notte (23:00 - 06:00)"
    echo "  --bridge <iface>      Specifica l'interfaccia bridge da utilizzare (predefinita: macvtap0 su eth0 oppure br0)"
    echo "  --mac <indirizzo_mac> Indirizzo MAC personalizzato per la VM (predefinito: 52:54:00:12:34:56)"
    echo "  [opzioni_qemu...]     Ulteriori argomenti passati direttamente a QEMU"
    echo ""
    echo "Esempi:"
    echo "  $script_name mydisk.qcow2"
    echo "  $script_name mydisk.qcow2 --night-prune"
    echo "  $script_name mydisk.qcow2 -nographic"
    exit 1
}

main() {
    if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        usage
    fi

    local disk_image="$1"
    shift

    if [[ ! -f "$disk_image" ]]; then
        echo "Errore: il file '$disk_image' non esiste o non è un file regolare." >&2
        exit 1
    fi

    # Parsing opzioni specifiche di autoprotect_start.sh
    local night_prune="off"
    local custom_bridge=""
    local mac_addr="52:54:00:12:34:56"
    local qemu_extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --night-prune)
                night_prune="on"
                shift
                ;;
            --bridge)
                if [[ $# -lt 2 ]]; then
                    echo "Errore: specificare l'interfaccia dopo --bridge." >&2
                    exit 1
                fi
                custom_bridge="$2"
                shift 2
                ;;
            --mac)
                if [[ $# -lt 2 ]]; then
                    echo "Errore: specificare l'indirizzo MAC dopo --mac." >&2
                    exit 1
                fi
                mac_addr="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                qemu_extra_args+=("$1")
                shift
                ;;
        esac
    done

    # Determina il percorso del binario QEMU (compilato in questo tree oppure in /opt/qemu)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local qemu_bin=""

    if [[ -x "${script_dir}/build/qemu-system-x86_64" ]]; then
        qemu_bin="${script_dir}/build/qemu-system-x86_64"
    elif [[ -x "/opt/qemu/bin/qemu-system-x86_64" ]]; then
        qemu_bin="/opt/qemu/bin/qemu-system-x86_64"
    else
        echo "Errore: binario 'qemu-system-x86_64' non trovato né nel build tree locale (${script_dir}/build) né in /opt/qemu/bin." >&2
        echo "Compilare il progetto prima di avviare la VM (es. con 'ninja -C build qemu-system-x86_64') o installarlo in /opt/qemu." >&2
        exit 1
    fi

    # Determina il percorso del bridge helper (tree locale oppure /opt/qemu/libexec)
    local bridge_helper=""
    if [[ -x "${script_dir}/build/qemu-bridge-helper" ]]; then
        bridge_helper="${script_dir}/build/qemu-bridge-helper"
    elif [[ -x "${script_dir}/build/qemu-bundle/opt/qemu/libexec/qemu-bridge-helper" ]]; then
        bridge_helper="${script_dir}/build/qemu-bundle/opt/qemu/libexec/qemu-bridge-helper"
    elif [[ -x "/opt/qemu/libexec/qemu-bridge-helper" ]]; then
        bridge_helper="/opt/qemu/libexec/qemu-bridge-helper"
    fi

    local helper_opt=""
    if [[ -n "$bridge_helper" ]]; then
        helper_opt=",helper=${bridge_helper}"
    fi

    local pid_file="/tmp/qemu_autoprotect.pid"

    # Directory dei delta: stessa directory del file qcow2 base
    local disk_abs
    disk_abs="$(cd "$(dirname "$disk_image")" && pwd)/$(basename "$disk_image")"
    local delta_dir
    delta_dir="$(dirname "$disk_abs")"

    # Selezione acceleratore (KVM se disponibile, altrimenti fallback su TCG)
    local accel_opts=()
    if [[ -w /dev/kvm ]]; then
        accel_opts=("-enable-kvm" "-cpu" "host")
        echo "[AutoProtect] Accelerazione KVM abilitata."
    else
        accel_opts=("-accel" "tcg")
        echo "[AutoProtect] KVM non disponibile, accelerazione TCG attiva."
    fi

    # Configurazione scheda di rete in bridge su eth0
    local net_opts=()
    local net_desc=""

    if [[ -n "$custom_bridge" ]]; then
        net_desc="Bridge personalizzato: $custom_bridge"
        net_opts=("-netdev" "bridge,id=net0,br=${custom_bridge}${helper_opt}"
                  "-device" "virtio-net-pci,netdev=net0,mac=${mac_addr}")
    elif ip link show macvtap0 >/dev/null 2>&1; then
        local tap_idx
        tap_idx="$(cat /sys/class/net/macvtap0/ifindex 2>/dev/null || echo "")"
        if [[ -n "$tap_idx" && -r "/dev/tap${tap_idx}" && -w "/dev/tap${tap_idx}" ]]; then
            exec 3<>"/dev/tap${tap_idx}"
            net_desc="Bridge macvtap0 su eth0 (connessione diretta a LAN fisica)"
            net_opts=("-netdev" "tap,id=net0,fd=3"
                      "-device" "virtio-net-pci,netdev=net0,mac=${mac_addr}")
        else
            net_desc="macvtap0 rilevato ma permessi insufficienti su /dev/tap${tap_idx} (usare 'sudo chmod 666 /dev/tap${tap_idx}')"
        fi
    fi

    # Se macvtap non è pronto, controlla bridge br0
    if [[ ${#net_opts[@]} -eq 0 ]] && ip link show br0 >/dev/null 2>&1; then
        net_desc="Bridge Linux br0 su eth0"
        net_opts=("-netdev" "bridge,id=net0,br=br0${helper_opt}"
                  "-device" "virtio-net-pci,netdev=net0,mac=${mac_addr}")
    fi

    # Se ancora non è configurato alcun bridge, guida l'utente o usa fallback user mode
    if [[ ${#net_opts[@]} -eq 0 ]]; then
        echo ""
        echo "[AutoProtect - Rete] ATTENZIONE: Nessun bridge (macvtap0 o br0) su eth0 attivo per utente corrente."
        echo "  Per connettere la VM come PC indipendente alla LAN fisica e usare il DHCP del router:"
        echo "  Esegui una tantum:  sudo ./setup_bridge.sh macvtap eth0"
        echo ""
        echo "[AutoProtect - Rete] Utilizzo fallback rete User/SLIRP (NAT locale)..."
        net_opts=("-netdev" "user,id=net0"
                  "-device" "virtio-net-pci,netdev=net0,mac=${mac_addr}")
        net_desc="User Mode / NAT (fallback provvisorio)"
    fi

    # Configurazione AutoProtect: intervallo 60s, retention 1h, live non-blocking, dir disco, night-prune
    local ap_config="interval=60,retention=1,mode=live,dir=${delta_dir},night-prune=${night_prune}"

    echo "[AutoProtect] Avvio macchina virtuale..."
    echo "[AutoProtect] - Binario QEMU:   $qemu_bin"
    echo "[AutoProtect] - Disco base:     $disk_abs"
    echo "[AutoProtect] - Directory delta: $delta_dir"
    echo "[AutoProtect] - Memoria RAM:    3 GB"
    echo "[AutoProtect] - Rete:           $net_desc (MAC: $mac_addr)"
    echo "[AutoProtect] - Snapshot:       Ogni 60 secondi (live non-blocking)"
    echo "[AutoProtect] - Retention:      1 ora"
    echo "[AutoProtect] - Night-Prune:    $night_prune (pruning differito di notte)"
    echo ""

    exec "$qemu_bin" \
        "${accel_opts[@]}" \
        -m 3G \
        -drive "file=${disk_abs},format=qcow2,if=virtio" \
        "${net_opts[@]}" \
        -autoprotect "$ap_config" \
        -pidfile "$pid_file" \
        "${qemu_extra_args[@]}"
}

main "$@"
