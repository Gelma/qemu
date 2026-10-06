#!/usr/bin/env bash
set -euo pipefail

# autoprotect_consolidate.sh - Consolida tutti gli snapshot delta nel file base originario
# - Trova l'overlay foglia attiva (ultimo stato/scrittura)
# - Applica tutte le scritture direttamente nel file base tramite qemu-img commit
# - Rimuove tutti gli snapshot delta (*-disk-*.qcow2) e i relativi file di stato (*-ram.state, *-dev.state)
# - Il file base originario diventa un disco unico standalone contenente il 100% delle ultime scritture

usage() {
    local exit_code="${1:-1}"
    local script_name
    script_name="$(basename "$0")"
    echo "Uso: $script_name <file.qcow2> [opzioni]"
    echo ""
    echo "Parametri:"
    echo "  <file.qcow2>          Percorso dell'immagine disco base o di un suo overlay (obbligatorio)"
    echo ""
    echo "Opzioni:"
    echo "  -y, --yes             Conferma automatica (non richiede conferma interattiva)"
    echo "  -k, --keep-state      Consolida i dischi ma conserva i file di memoria (*-ram.state / *-dev.state)"
    echo "  --dry-run             Mostra cosa verrebbe consolidato e lo spazio liberabile senza toccare i file"
    echo "  -h, --help            Mostra questo messaggio di aiuto"
    echo ""
    echo "Esempi:"
    echo "  $script_name disk0.qcow2"
    echo "  $script_name /mnt/bidone-sda8/super_protezione/disk0.qcow2 --yes"
    echo "  $script_name disk0.qcow2 --dry-run"
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

# Risolve il binario qemu-img (priorità: build locale -> /opt/qemu/bin)
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
        echo "Errore: il file '$disk_image' non esiste o non è un file regolare." >&2
        exit 1
    fi

    local auto_yes=0
    local keep_state=0
    local dry_run=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                auto_yes=1
                shift
                ;;
            -k|--keep-state)
                keep_state=1
                shift
                ;;
            --dry-run)
                dry_run=1
                shift
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

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local qemu_img
    qemu_img="$(get_qemu_img)"

    # Verifica di sicurezza: la VM non deve essere in esecuzione!
    local pid_file="/tmp/qemu_autoprotect.pid"
    if [[ -f "$pid_file" ]]; then
        local running_pid
        running_pid="$(cat "$pid_file" 2>/dev/null || echo "")"
        if [[ -n "$running_pid" ]] && kill -0 "$running_pid" 2>/dev/null; then
            echo "ERRORE DI SICUREZZA: La VM QEMU (PID: $running_pid) è attualmente in esecuzione!" >&2
            echo "Non è possibile consolidare gli snapshot mentre la macchina virtuale è attiva." >&2
            echo "Arrestare prima la VM con:  ./autoprotect_stop.sh" >&2
            exit 1
        fi
    fi

    # Analisi della catena tramite autoprotect_find_leaf.py
    local leaf_json
    if ! leaf_json="$("python3" "${script_dir}/autoprotect_find_leaf.py" "$disk_image" --json --qemu-img "$qemu_img")"; then
        echo "Errore: impossibile analizzare la catena del disco '$disk_image'." >&2
        exit 1
    fi

    local base_image
    local active_leaf
    local chain_depth
    local matching_count

    base_image="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('base_image', ''))" "$leaf_json")"
    active_leaf="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('active_leaf', ''))" "$leaf_json")"
    chain_depth="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('chain_depth', 0))" "$leaf_json")"
    matching_count="$(python3 -c "import json, sys; d = json.loads(sys.argv[1]); print(d.get('matching_overlays_count', 0))" "$leaf_json")"

    if [[ "$matching_count" -eq 0 ]] || [[ "$base_image" == "$active_leaf" ]]; then
        echo "[Consolidamento] Il disco base '$base_image' è già consolidato."
        echo "Nessuno snapshot delta presente nella catena. Nessuna operazione necessaria."
        exit 0
    fi

    # Estrai l'elenco dei file overlay da eliminare
    local -a overlays=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            overlays+=("$line")
        fi
    done < <(python3 -c "import json, sys; [print(x) for x in json.loads(sys.argv[1]).get('overlays', [])]" "$leaf_json")

    # Trova i file di stato RAM e dev associati da eliminare
    local base_dir
    base_dir="$(dirname "$base_image")"
    local -a state_files=()

    local ov
    for ov in "${overlays[@]}"; do
        local fname
        fname="$(basename "$ov")"
        local tag="${fname%%-disk-*}"
        local ram_file="${base_dir}/${tag}-ram.state"
        local dev_file="${base_dir}/${tag}-dev.state"
        if [[ -f "$ram_file" ]]; then
            state_files+=("$ram_file")
        fi
        if [[ -f "$dev_file" ]]; then
            state_files+=("$dev_file")
        fi
    done

    # Calcolo dimensione totale liberabile
    local total_bytes=0
    for ov in "${overlays[@]}"; do
        if [[ -f "$ov" ]]; then
            local sz
            sz="$(stat -c %s "$ov" 2>/dev/null || echo "0")"
            total_bytes=$((total_bytes + sz))
        fi
    done

    local state_bytes=0
    for sf in "${state_files[@]}"; do
        if [[ -f "$sf" ]]; then
            local ssz
            ssz="$(stat -c %s "$sf" 2>/dev/null || echo "0")"
            state_bytes=$((state_bytes + ssz))
        fi
    done

    local total_reclaimable=$((total_bytes + (keep_state == 0 ? state_bytes : 0)))
    local readable_reclaimable
    readable_reclaimable="$(format_size "$total_reclaimable")"
    local readable_ov_size
    readable_ov_size="$(format_size "$total_bytes")"
    local readable_st_size
    readable_st_size="$(format_size "$state_bytes")"

    echo "=========================================================================="
    echo "           CONSOLIDAMENTO SNAPSHOT AUTOPROTECT NEL DISCO BASE"
    echo "=========================================================================="
    echo "Disco base di destinazione:  $base_image"
    echo "Foglia attiva (ultimi dati): $(basename "$active_leaf")"
    echo "Numero di snapshot nella catena: $matching_count (profondità: $chain_depth)"
    echo ""
    echo "Dettaglio file da eliminare dopo il commit:"
    echo "  - File delta qcow2:        ${#overlays[@]} file ($readable_ov_size)"
    if [[ "$keep_state" -eq 0 ]]; then
        echo "  - File di stato RAM/dev:   ${#state_files[@]} file ($readable_st_size)"
    else
        echo "  - File di stato RAM/dev:   CONSERVATI (-k / --keep-state attivo)"
    fi
    echo "Spazio disco stimato liberabile: $readable_reclaimable"
    echo "=========================================================================="
    echo ""

    if [[ "$dry_run" -eq 1 ]]; then
        echo "[DRY RUN] Comando che verrebbe eseguito per il commit:"
        echo "  $qemu_img commit -b \"$base_image\" -p \"$active_leaf\""
        echo ""
        echo "[DRY RUN] File che verrebbero rimossi:"
        for ov in "${overlays[@]}"; do
            echo "  - $ov"
        done
        if [[ "$keep_state" -eq 0 ]]; then
            for sf in "${state_files[@]}"; do
                echo "  - $sf"
            done
        fi
        echo ""
        echo "[DRY RUN] Simulazione completata. Nessuna modifica apportata ai file."
        exit 0
    fi

    # Richiesta conferma utente
    if [[ "$auto_yes" -eq 0 ]]; then
        echo "ATTENZIONE: Questa operazione scriverà permanentemente tutte le modifiche"
        echo "della catena nel file '$base_image' e cancellerà tutti gli snapshot intermedi."
        echo -n "Procedere con il consolidamento? [s/N]: "
        local answer
        read -r answer
        if [[ ! "$answer" =~ ^[Ss]$ ]]; then
            echo "Operazione annullata dall'utente."
            exit 0
        fi
    fi

    echo ""
    echo "[Consolidamento] Inizio unione scritture nel file base via qemu-img commit..."
    echo "[Consolidamento] - Base:   $base_image"
    echo "[Consolidamento] - Foglia: $active_leaf"
    echo ""

    # Esecuzione qemu-img commit con barra di avanzamento (-p)
    if ! "$qemu_img" commit -b "$base_image" -p "$active_leaf"; then
        echo ""
        echo "ERRORE CRITICO: 'qemu-img commit' è fallito!" >&2
        echo "I file di snapshot NON sono stati toccati o cancellati per preservare i dati." >&2
        exit 1
    fi

    echo ""
    echo "[Consolidamento] Commit completato con successo nel file base!"
    echo "[Consolidamento] Rimozione dei file di snapshot delta intermedi..."

    local removed_count=0
    for ov in "${overlays[@]}"; do
        if [[ -f "$ov" ]]; then
            rm -f "$ov"
            removed_count=$((removed_count + 1))
        fi
    done
    echo "[Consolidamento] - Rimossi $removed_count file di delta qcow2."

    if [[ "$keep_state" -eq 0 ]]; then
        local removed_state=0
        for sf in "${state_files[@]}"; do
            if [[ -f "$sf" ]]; then
                rm -f "$sf"
                removed_state=$((removed_state + 1))
            fi
        done
        echo "[Consolidamento] - Rimossi $removed_state file di stato memoria (RAM/dev)."
    fi

    echo ""
    echo "=========================================================================="
    echo "          CONSOLIDAMENTO COMPLETATO CON SUCCESSO!"
    echo "=========================================================================="
    echo "Il file base '$base_image' è ora standalone e contiene il 100% delle"
    echo "ultime scritture eseguite dalla VM."
    echo "Spazio liberato sul disco: ~$readable_reclaimable"
    echo "La macchina virtuale può ora essere avviata normalmente con:"
    echo "  ./autoprotect_start.sh $base_image"
    echo "=========================================================================="
}

main "$@"
