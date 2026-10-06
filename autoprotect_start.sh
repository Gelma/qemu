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
    echo "  --base                Forza l'avvio dal disco base originale (ignora la catena di delta snapshot)"
    echo "  --snapshot <tag>      Avvia da uno snapshot specifico della catena delta"
    echo "  --night-prune         Abilita la cancellazione massiva differita solo di notte (23:00 - 06:00)"
    echo "  --bridge <iface>      Specifica l'interfaccia bridge da utilizzare (predefinita: macvtap0 su eth0 oppure br0)"
    echo "  --mac <indirizzo_mac> Indirizzo MAC personalizzato per la VM (predefinito: 52:54:00:12:34:56)"
    echo "  --dry-run             Mostra la configurazione e il comando generato senza avviare la VM"
    echo "  [opzioni_qemu...]     Ulteriori argomenti passati direttamente a QEMU"
    echo ""
    echo "Comportamento predefinito:"
    echo "  All'avvio, rileva automaticamente l'ultimo overlay (foglia attiva) della catena"
    echo "  e garantisce il boot dallo stato esatto dell'ultimo snapshot/scrittura!"
    echo ""
    echo "Esempi:"
    echo "  $script_name mydisk.qcow2"
    echo "  $script_name mydisk.qcow2 --night-prune"
    echo "  $script_name mydisk.qcow2 --base"
    echo "  $script_name mydisk.qcow2 --snapshot autoprotect-20261006-143338"
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
    local force_base=0
    local target_snapshot=""
    local dry_run=0
    local qemu_extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --night-prune)
                night_prune="on"
                shift
                ;;
            --base)
                force_base=1
                shift
                ;;
            --snapshot)
                if [[ $# -lt 2 ]]; then
                    echo "Errore: specificare il tag dello snapshot dopo --snapshot." >&2
                    exit 1
                fi
                target_snapshot="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
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

    # Determina il binario qemu-img
    local qemu_img="qemu-img"
    if [[ -x "${script_dir}/build/qemu-img" ]]; then
        qemu_img="${script_dir}/build/qemu-img"
    elif [[ -x "/opt/qemu/bin/qemu-img" ]]; then
        qemu_img="/opt/qemu/bin/qemu-img"
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

    # Risoluzione automatica della foglia attiva della catena di snapshot delta
    local find_leaf_cmd=("python3" "${script_dir}/autoprotect_find_leaf.py" "$disk_abs" "--json" "--qemu-img" "$qemu_img")
    if [[ "$force_base" -eq 1 ]]; then
        find_leaf_cmd+=("--base")
    elif [[ -n "$target_snapshot" ]]; then
        find_leaf_cmd+=("--snapshot" "$target_snapshot")
    fi

    local leaf_json
    if ! leaf_json="$("${find_leaf_cmd[@]}")"; then
        echo "Errore nella risoluzione della catena di snapshot delta tramite autoprotect_find_leaf.py." >&2
        exit 1
    fi

    local boot_disk
    local active_leaf
    local base_image
    local chain_depth
    local matching_count

    boot_disk="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('selected_boot_disk', ''))" "$leaf_json")"
    active_leaf="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('active_leaf', ''))" "$leaf_json")"
    base_image="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('base_image', ''))" "$leaf_json")"
    chain_depth="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('chain_depth', 0))" "$leaf_json")"
    matching_count="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('matching_overlays_count', 0))" "$leaf_json")"

    if [[ -z "$boot_disk" || ! -f "$boot_disk" ]]; then
        boot_disk="$disk_abs"
    fi

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
    echo "[AutoProtect] - Binario QEMU:      $qemu_bin"
    echo "[AutoProtect] - Disco base:        $base_image"
    echo "[AutoProtect] - Directory delta:   $delta_dir"
    echo "[AutoProtect] - Memoria RAM:       3 GB"
    echo "[AutoProtect] - Rete:              $net_desc (MAC: $mac_addr)"
    echo "[AutoProtect] - Snapshot:          Ogni 60 secondi (live non-blocking)"
    echo "[AutoProtect] - Retention:         1 ora"
    echo "[AutoProtect] - Night-Prune:       $night_prune (pruning differito di notte)"
    echo ""

    if [[ "$force_base" -eq 1 ]]; then
        echo "[AutoProtect - BOOT] MODALITA' DISCO BASE (--base):"
        echo "  Disco di boot:   $boot_disk"
        echo "  ATTENZIONE: Avvio dal disco originale base; gli snapshot delta esistenti ($matching_count) non saranno applicati."
    elif [[ -n "$target_snapshot" ]]; then
        echo "[AutoProtect - BOOT] MODALITA' SNAPSHOT SPECIFICO (--snapshot):"
        echo "  Tag snapshot:    $target_snapshot"
        echo "  Disco di boot:   $boot_disk"
    elif [[ "$matching_count" -gt 0 ]]; then
        echo "[AutoProtect - BOOT] GARANZIA ULTIMO STATO / SCRITTURA ATTIVA:"
        echo "  Rilevata catena delta attiva ($matching_count snapshot trovati, profondita': $chain_depth)."
        echo "  Foglia attiva:   $(basename "$active_leaf")"
        echo "  Disco di boot:   $boot_disk"
        echo "  -> La VM riparte al 100% dall'ultimo stato/scrittura eseguita prima dello spegnimento/riavvio!"
        echo "  (Usa '--base' per avviare dal disco base pulito o '--snapshot <tag>' per un punto temporale specifico)."
    else
        echo "[AutoProtect - BOOT] NUOVA SESSIONE DISCO BASE:"
        echo "  Nessun delta snapshot esistente nella directory. Avvio da: $boot_disk"
    fi
    echo ""

    if [[ "$dry_run" -eq 1 ]]; then
        echo "[AutoProtect - DRY RUN] Comando QEMU che verrebbe eseguito:"
        echo "$qemu_bin" \
            "${accel_opts[@]}" \
            -m 3G \
            -drive "file=${boot_disk},format=qcow2,if=virtio" \
            "${net_opts[@]}" \
            -autoprotect "$ap_config" \
            -pidfile "$pid_file" \
            "${qemu_extra_args[@]}"
        echo ""
        echo "[AutoProtect - DRY RUN] Esecuzione simulata completata con successo."
        exit 0
    fi

    exec "$qemu_bin" \
        "${accel_opts[@]}" \
        -m 3G \
        -drive "file=${boot_disk},format=qcow2,if=virtio" \
        "${net_opts[@]}" \
        -autoprotect "$ap_config" \
        -pidfile "$pid_file" \
        "${qemu_extra_args[@]}"
}

main "$@"
