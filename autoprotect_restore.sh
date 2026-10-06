#!/usr/bin/env bash
set -euo pipefail

# autoprotect_restore.sh - Gestione, elenco e ripristino snapshot AutoProtect
# Supporta sia snapshot delta esterni (live non-blocking) sia snapshot interni (qcow2 standard).

usage() {
    local exit_code="${1:-1}"
    local script_name
    script_name="$(basename "$0")"
    echo "Uso: $script_name <file.qcow2> [opzioni]"
    echo ""
    echo "Parametri:"
    echo "  <file.qcow2>                 Percorso del file immagine disco qcow2 (obbligatorio)"
    echo ""
    echo "Opzioni:"
    echo "  -l, --list                   Elenca tutti gli snapshot disponibili ed esce"
    echo "  -s, --snapshot <tag|numero>  Seleziona direttamente lo snapshot da ripristinare"
    echo "  -c, --consolidate, --commit  Consolida tutte le scritture nel disco base e distrugge gli snapshot"
    echo "  -h, --help                   Mostra questo messaggio di aiuto"
    echo ""
    echo "Esempi:"
    echo "  $script_name mydisk.qcow2 --list"
    echo "  $script_name mydisk.qcow2 --snapshot 1"
    echo "  $script_name mydisk.qcow2 --consolidate"
    echo "  $script_name mydisk.qcow2"
    exit "$exit_code"
}

# Funzione per formattare la dimensione in formato leggibile (KB/MB/GB)
format_size() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b/1073741824 }'
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b/1048576 }'
    elif [[ "$bytes" -ge 1024 ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.2f KB", b/1024 }'
    else
        echo "${bytes} B"
    fi
}

# Risolve il binario QEMU (compilato localmente in build oppure in /opt/qemu)
get_qemu_bin() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "${script_dir}/build/qemu-system-x86_64" ]]; then
        echo "${script_dir}/build/qemu-system-x86_64"
        return 0
    elif [[ -x "/opt/qemu/bin/qemu-system-x86_64" ]]; then
        echo "/opt/qemu/bin/qemu-system-x86_64"
        return 0
    fi
    echo "Errore: 'qemu-system-x86_64' non trovato né in ${script_dir}/build né in /opt/qemu/bin." >&2
    exit 1
}

# Risolve qemu-img (compilato localmente in build oppure in /opt/qemu)
get_qemu_img() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "${script_dir}/build/qemu-img" ]]; then
        echo "${script_dir}/build/qemu-img"
        return 0
    elif [[ -x "/opt/qemu/bin/qemu-img" ]]; then
        echo "/opt/qemu/bin/qemu-img"
        return 0
    fi
    echo "Errore: 'qemu-img' non trovato né in ${script_dir}/build né in /opt/qemu/bin." >&2
    exit 1
}

# Risolve qemu-bridge-helper (tree locale oppure /opt/qemu/libexec)
get_bridge_helper() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "${script_dir}/build/qemu-bridge-helper" ]]; then
        echo "${script_dir}/build/qemu-bridge-helper"
        return 0
    elif [[ -x "${script_dir}/build/qemu-bundle/opt/qemu/libexec/qemu-bridge-helper" ]]; then
        echo "${script_dir}/build/qemu-bundle/opt/qemu/libexec/qemu-bridge-helper"
        return 0
    elif [[ -x "/opt/qemu/libexec/qemu-bridge-helper" ]]; then
        echo "/opt/qemu/libexec/qemu-bridge-helper"
        return 0
    fi
    return 1
}

# Raccoglie gli snapshot disponibili
collect_snapshots() {
    local disk_image="$1"
    local disk_dir
    disk_dir="$(cd "$(dirname "$disk_image")" && pwd)"
    local base_name
    base_name="$(basename "$disk_image")"

    local qemu_img
    qemu_img="$(get_qemu_img)"

    # Snapshot list arrays
    SNAPSHOT_TAGS=()
    SNAPSHOT_TYPES=()
    SNAPSHOT_DATES=()
    SNAPSHOT_DISKS=()
    SNAPSHOT_RAMS=()

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local active_leaf=""
    if [[ -x "${script_dir}/autoprotect_find_leaf.py" ]]; then
        active_leaf="$("${script_dir}/autoprotect_find_leaf.py" "$disk_image" --qemu-img "$qemu_img" 2>/dev/null || echo "")"
    fi

    # 1. Trova snapshot delta live nella directory del disco base
    local overlay_file
    for overlay_file in "${disk_dir}"/*-disk-*.qcow2; do
        if [[ ! -f "$overlay_file" ]]; then
            continue
        fi

        local filename
        filename="$(basename "$overlay_file")"

        # Estrai il tag (tutto prima di -disk-)
        local tag
        tag="${filename%%-disk-*}"

        # Verifica che non sia già stato aggiunto
        local already_added=0
        local existing_tag
        for existing_tag in "${SNAPSHOT_TAGS[@]:-}"; do
            if [[ "$existing_tag" == "$tag" ]]; then
                already_added=1
                break
            fi
        done
        if [[ "$already_added" -eq 1 ]]; then
            continue
        fi

        # Cerca file di stato associati
        local ram_file="${disk_dir}/${tag}-ram.state"
        local dev_file="${disk_dir}/${tag}-dev.state"

        local disk_size="0"
        if [[ -f "$overlay_file" ]]; then
            disk_size="$(stat -c %s "$overlay_file" 2>/dev/null || echo "0")"
        fi

        local ram_size="N/A"
        if [[ -f "$ram_file" ]]; then
            local rbytes
            rbytes="$(stat -c %s "$ram_file" 2>/dev/null || echo "0")"
            ram_size="$(format_size "$rbytes")"
        fi

        local mod_date
        mod_date="$(date -r "$overlay_file" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Sconosciuta")"

        local snap_type="Live Delta"
        if [[ -n "$active_leaf" && "$overlay_file" == "$active_leaf" ]]; then
            snap_type="Live Delta [ATTIVO]"
        fi

        SNAPSHOT_TAGS+=("$tag")
        SNAPSHOT_TYPES+=("$snap_type")
        SNAPSHOT_DATES+=("$mod_date")
        SNAPSHOT_DISKS+=("$overlay_file")
        SNAPSHOT_RAMS+=("$ram_size")
    done

    # 2. Trova snapshot interni al qcow2
    if [[ -x "$qemu_img" ]]; then
        local sn_output
        sn_output="$("$qemu_img" snapshot -l "$disk_image" 2>/dev/null || echo "")"
        if [[ -n "$sn_output" ]]; then
            while IFS= read -r line; do
                # Formato tipico qemu-img snapshot -l:
                # ID        TAG                 VM SIZE                DATE       VM CLOCK
                # 1         autoprotect-1234       150M 2026-10-06 14:00:00   00:01:23.456
                if [[ "$line" =~ ^[0-9]+[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
                    local int_tag="${BASH_REMATCH[1]}"
                    local int_vmsize="${BASH_REMATCH[2]}"
                    local int_date="${BASH_REMATCH[3]}"

                    SNAPSHOT_TAGS+=("$int_tag")
                    SNAPSHOT_TYPES+=("Interno (qcow2)")
                    SNAPSHOT_DATES+=("$int_date")
                    SNAPSHOT_DISKS+=("$disk_image")
                    SNAPSHOT_RAMS+=("$int_vmsize")
                fi
            done <<< "$sn_output"
        fi
    fi
}

print_snapshots_table() {
    local total="${#SNAPSHOT_TAGS[@]}"
    if [[ "$total" -eq 0 ]]; then
        echo "Nessuno snapshot trovato per l'immagine '$1'."
        return 0
    fi

    echo "=========================================================================================="
    printf "%-4s | %-28s | %-16s | %-19s | %-10s\n" "NUM" "TAG SNAPSHOT" "TIPO" "DATA E ORA" "STATO RAM"
    echo "-----+------------------------------+------------------+---------------------+------------"

    local i
    for ((i=0; i<total; i++)); do
        local num=$((i + 1))
        local tag="${SNAPSHOT_TAGS[$i]}"
        local type="${SNAPSHOT_TYPES[$i]}"
        local date_str="${SNAPSHOT_DATES[$i]}"
        local ram_info="${SNAPSHOT_RAMS[$i]}"
        printf "%-4d | %-28s | %-16s | %-19s | %-10s\n" "$num" "$tag" "$type" "$date_str" "$ram_info"
    done
    echo "=========================================================================================="
    echo "Totale snapshot disponibili: $total"
    echo ""
}

start_vm_live_delta() {
    local disk_image="$1"
    local overlay_path="$2"
    local tag="$3"

    local qemu_bin
    qemu_bin="$(get_qemu_bin)"

    echo ""
    echo "[Ripristino] Avvio VM dallo snapshot live delta: $tag"
    echo "[Ripristino] - Overlay disco: $overlay_path"

    # Per non sovrascrivere lo snapshot storico durante l'esecuzione,
    # crea opzionalmente un overlay di sessione temporaneo a partire dallo snapshot
    local disk_dir
    disk_dir="$(cd "$(dirname "$disk_image")" && pwd)"
    local session_overlay="${disk_dir}/session-${tag}-$$.qcow2"

    echo -n "Vuoi creare un overlay di sicurezza per non alterare lo snapshot storico? [S/n]: "
    read -r choice || choice="s"
    local run_disk="$overlay_path"

    if [[ "$choice" =~ ^[Ss]?$ ]]; then
        local qemu_img
        qemu_img="$(get_qemu_img)"
        "$qemu_img" create -f qcow2 -b "$overlay_path" -F qcow2 "$session_overlay" >/dev/null
        run_disk="$session_overlay"
        echo "[Ripristino] Overlay temporaneo creato in: $run_disk"
    fi

    # Rilevamento accelerazione
    local accel_opts=()
    if [[ -w /dev/kvm ]]; then
        accel_opts=("-enable-kvm" "-cpu" "host")
    else
        accel_opts=("-accel" "tcg")
    fi

    # Rilevamento bridge helper
    local bridge_helper=""
    if bridge_helper="$(get_bridge_helper 2>/dev/null)"; then
        bridge_helper=",helper=${bridge_helper}"
    else
        bridge_helper=""
    fi

    # Rilevamento rete bridge/macvtap
    local net_opts=()
    local mac_addr="52:54:00:12:34:56"
    if [[ -e /dev/tap$(cat /sys/class/net/macvtap0/ifindex 2>/dev/null || echo "") && -r /dev/tap$(cat /sys/class/net/macvtap0/ifindex 2>/dev/null || echo "") ]]; then
        local tap_idx
        tap_idx="$(cat /sys/class/net/macvtap0/ifindex)"
        if [[ -r /sys/class/net/macvtap0/address ]]; then
            mac_addr="$(cat /sys/class/net/macvtap0/address)"
        fi
        exec 3<>"/dev/tap${tap_idx}"
        net_opts=("-netdev" "tap,id=net0,fd=3" "-device" "virtio-net-pci,netdev=net0,mac=${mac_addr}")
    elif ip link show br0 >/dev/null 2>&1; then
        net_opts=("-netdev" "bridge,id=net0,br=br0${bridge_helper}" "-device" "virtio-net-pci,netdev=net0,mac=${mac_addr}")
    else
        net_opts=("-netdev" "user,id=net0" "-device" "virtio-net-pci,netdev=net0")
    fi

    # Scheda di gestione host SSH locale (porta 10022 -> guest:22)
    local mgmt_opts=("-netdev" "user,id=net_mgmt,restrict=on,hostfwd=tcp::10022-:22"
                     "-device" "virtio-net-pci,netdev=net_mgmt")

    echo "[Ripristino] Esecuzione QEMU: $qemu_bin"
    echo "[Ripristino] - Rete LAN:      Bridge macvtap (MAC: $mac_addr)"
    echo "[Ripristino] - Rete Gestione: SSH locale (ssh -p 10022 gelma@localhost)"
    exec "$qemu_bin" \
        "${accel_opts[@]}" \
        -m 3G \
        -drive "file=${run_disk},format=qcow2,if=virtio" \
        "${net_opts[@]}" \
        "${mgmt_opts[@]}"
}

start_vm_internal() {
    local disk_image="$1"
    local tag="$2"

    local qemu_bin
    qemu_bin="$(get_qemu_bin)"
    local qemu_img
    qemu_img="$(get_qemu_img)"

    echo ""
    echo "[Ripristino] Snapshot interno selezionato: $tag"
    echo "Opzioni:"
    echo "  1) Avvia VM caricando lo stato di memoria e CPU (-loadvm $tag)"
    echo "  2) Applica lo snapshot al disco qcow2 in modo permanente (qemu-img snapshot -a)"
    echo "  3) Annulla"
    echo -n "Scegli un'opzione [1/2/3]: "
    read -r opt

    case "$opt" in
        1)
            local accel_opts=()
            if [[ -w /dev/kvm ]]; then
                accel_opts=("-enable-kvm" "-cpu" "host")
            else
                accel_opts=("-accel" "tcg")
            fi
            echo "[Ripristino] Avvio VM con -loadvm $tag..."
            exec "$qemu_bin" \
                "${accel_opts[@]}" \
                -m 3G \
                -drive "file=${disk_image},format=qcow2,if=virtio" \
                -loadvm "$tag"
            ;;
        2)
            echo "[Ripristino] Applicazione dello snapshot '$tag' al file $disk_image..."
            "$qemu_img" snapshot -a "$tag" "$disk_image"
            echo "[Ripristino] Snapshot applicato con successo al disco!"
            echo "Puoi ora avviare la VM normalmente con './autoprotect_start.sh $disk_image'."
            ;;
        *)
            echo "Operazione annullata."
            exit 0
            ;;
    esac
}

main() {
    if [[ $# -ge 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage 0
    fi
    if [[ $# -lt 1 ]]; then
        usage 1
    fi

    local disk_image="$1"
    shift

    if [[ ! -f "$disk_image" ]]; then
        echo "Errore: il file immagine '$disk_image' non esiste." >&2
        exit 1
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local list_only=0
    local target_choice=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--consolidate|--commit)
                shift
                exec "${script_dir}/autoprotect_consolidate.sh" "$disk_image" "$@"
                ;;
            -l|--list)
                list_only=1
                shift
                ;;
            -s|--snapshot)
                if [[ $# -lt 2 ]]; then
                    echo "Errore: specificare il tag o numero di snapshot dopo $1." >&2
                    exit 1
                fi
                target_choice="$2"
                shift 2
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                echo "Opzione non riconosciuta: $1" >&2
                usage
                ;;
        esac
    done

    collect_snapshots "$disk_image"

    if [[ "$list_only" -eq 1 ]]; then
        print_snapshots_table "$disk_image"
        exit 0
    fi

    print_snapshots_table "$disk_image"

    local total="${#SNAPSHOT_TAGS[@]}"
    if [[ "$total" -eq 0 ]]; then
        exit 0
    fi

    local selected_idx=-1
    if [[ -n "$target_choice" ]]; then
        if [[ "$target_choice" =~ ^[0-9]+$ ]] && [[ "$target_choice" -ge 1 && "$target_choice" -le "$total" ]]; then
            selected_idx=$((target_choice - 1))
        else
            for ((i=0; i<total; i++)); do
                if [[ "${SNAPSHOT_TAGS[$i]}" == "$target_choice" ]]; then
                    selected_idx="$i"
                    break
                fi
            done
        fi
        if [[ "$selected_idx" -lt 0 ]]; then
            echo "Errore: snapshot '$target_choice' non trovato." >&2
            exit 1
        fi
    else
        echo -n "Inserisci il numero o il tag dello snapshot da ripristinare, 'c' per consolidare nel disco base (oppure 'q' per uscire): "
        read -r input
        if [[ "$input" =~ ^[Qq]$ || -z "$input" ]]; then
            echo "Uscita."
            exit 0
        fi
        if [[ "$input" =~ ^[Cc]$ ]]; then
            exec "${script_dir}/autoprotect_consolidate.sh" "$disk_image"
        fi
        if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le "$total" ]]; then
            selected_idx=$((input - 1))
        else
            for ((i=0; i<total; i++)); do
                if [[ "${SNAPSHOT_TAGS[$i]}" == "$input" ]]; then
                    selected_idx="$i"
                    break
                fi
            done
        fi
        if [[ "$selected_idx" -lt 0 ]]; then
            echo "Scelta non valida: '$input'." >&2
            exit 1
        fi
    fi

    local tag="${SNAPSHOT_TAGS[$selected_idx]}"
    local type="${SNAPSHOT_TYPES[$selected_idx]}"
    local disk_path="${SNAPSHOT_DISKS[$selected_idx]}"

    echo ""
    echo "Selezionato: [$((selected_idx + 1))] $tag ($type)"

    if [[ "$type" == "Live Delta" ]]; then
        start_vm_live_delta "$disk_image" "$disk_path" "$tag"
    else
        start_vm_internal "$disk_image" "$tag"
    fi
}

main "$@"
