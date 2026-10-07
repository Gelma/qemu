#!/usr/bin/env bash
set -euo pipefail

# autoprotect_delete.sh - Eliminazione selettiva consistente di snapshot singoli o multipli
# - Supporta la selezione di qualsiasi snapshot nella catena (singolo, multiplo es. 1,3,5 o intervallo 2-5)
# - Preserva la consistenza della catena eseguendo il rebase automatico dei nodi successivi
# - Rimuove in sicurezza file overlay qcow2 e file di stato RAM/dispositivi associati

usage() {
    local exit_code="${1:-1}"
    local script_name
    script_name="$(basename "$0")"
    echo "Uso: $script_name <file.qcow2> [opzioni] [selettore...]"
    echo ""
    echo "Parametri:"
    echo "  <file.qcow2>                 Percorso dell'immagine disco base o di un suo overlay (obbligatorio)"
    echo "  [selettore...]               Numeri, intervalli o tag da eliminare (es. 2 oppure 1,3,5 oppure 2-4)"
    echo ""
    echo "Opzioni:"
    echo "  -s, --snapshot <selettore>   Specifica la selezione degli snapshot da eliminare"
    echo "  -l, --list                   Elenca tutti gli snapshot disponibili ed esce"
    echo "  -y, --yes                    Conferma automatica (non richiede conferma interattiva)"
    echo "  -k, --keep-state             Elimina i dischi ma conserva i file di stato (*-ram.state / *-dev.state)"
    echo "  --dry-run                    Simula l'eliminazione e mostra i rebase necessari senza toccare i file"
    echo "  -h, --help                   Mostra questo messaggio di aiuto"
    echo ""
    echo "Esempi:"
    echo "  $script_name disk0.qcow2 --list"
    echo "  $script_name disk0.qcow2 2"
    echo "  $script_name disk0.qcow2 1,3,5"
    echo "  $script_name disk0.qcow2 2-4"
    echo "  $script_name disk0.qcow2 --snapshot autoprotect-20261006-164531"
    echo "  $script_name disk0.qcow2 2,4 --dry-run"
    echo "  $script_name disk0.qcow2 (senza argomenti: avvia il menu interattivo)"
    exit "$exit_code"
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

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local qemu_img
    qemu_img="$(get_qemu_img)"
    local delete_py="${script_dir}/autoprotect_delete.py"

    if [[ ! -x "$delete_py" ]]; then
        echo "Errore: '${delete_py}' non trovato o non eseguibile." >&2
        exit 1
    fi

    local list_only=0
    local auto_yes=0
    local keep_state=0
    local dry_run=0
    local selector=""
    local -a positional_selectors=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--list)
                list_only=1
                shift
                ;;
            -s|--snapshot)
                if [[ $# -lt 2 ]]; then
                    echo "Errore: specificare il selettore dopo $1." >&2
                    exit 1
                fi
                selector="$2"
                shift 2
                ;;
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
                positional_selectors+=("$1")
                shift
                ;;
        esac
    done

    # Unisci eventuali selettori passati come argomenti posizionali
    if [[ -z "$selector" && "${#positional_selectors[@]}" -gt 0 ]]; then
        selector="$(IFS=','; echo "${positional_selectors[*]}")"
    fi

    # Se richiesta solo la lista, mostra ed esci
    if [[ "$list_only" -eq 1 ]]; then
        python3 "$delete_py" "$disk_image" --qemu-img "$qemu_img" --list
        exit 0
    fi

    # Controllo di sicurezza: VM in esecuzione
    local pid_file="/tmp/qemu_autoprotect.pid"
    if [[ -f "$pid_file" ]]; then
        local running_pid
        running_pid="$(cat "$pid_file" 2>/dev/null || echo "")"
        if [[ -n "$running_pid" ]] && kill -0 "$running_pid" 2>/dev/null; then
            echo "ERRORE DI SICUREZZA: La VM QEMU (PID: $running_pid) è attualmente in esecuzione!" >&2
            echo "Non è possibile eliminare o riorganizzare gli snapshot mentre la macchina virtuale è attiva." >&2
            echo "Arrestare prima la VM con:  ./autoprotect_stop.sh" >&2
            exit 1
        fi
    fi

    # Se nessun selettore specificato, mostra la tabella e chiedi all'utente
    if [[ -z "$selector" ]]; then
        local snap_json
        snap_json="$(python3 "$delete_py" "$disk_image" --qemu-img "$qemu_img" --list --json 2>/dev/null || echo "[]")"
        local snap_count
        snap_count="$(python3 -c "import json, sys; print(len(json.loads(sys.argv[1])))" "$snap_json" 2>/dev/null || echo "0")"

        if [[ "$snap_count" -eq 0 ]]; then
            echo ""
            echo "Nessuno snapshot disponibile per '$disk_image'."
            exit 0
        fi

        echo ""
        echo "Snapshot disponibili per '$disk_image':"
        python3 "$delete_py" "$disk_image" --qemu-img "$qemu_img" --list
        echo ""
        echo -n "Inserisci i numeri o tag degli snapshot da eliminare (es. 2,4 o 3-5 o 'all', 'q' per uscire): "
        local input
        read -r input
        if [[ "$input" =~ ^[Qq]$ || -z "$input" ]]; then
            echo "Operazione annullata."
            exit 0
        fi
        selector="$input"
    fi

    # Se modalità dry-run
    if [[ "$dry_run" -eq 1 ]]; then
        local dry_cmd=("python3" "$delete_py" "$disk_image" "--qemu-img" "$qemu_img" "--select" "$selector" "--dry-run")
        if [[ "$keep_state" -eq 1 ]]; then
            dry_cmd+=("--keep-state")
        fi
        "${dry_cmd[@]}"
        exit 0
    fi

    # Analisi piano con output
    local -a py_cmd=("python3" "$delete_py" "$disk_image" "--qemu-img" "$qemu_img" "--select" "$selector")
    if [[ "$keep_state" -eq 1 ]]; then
        py_cmd+=("--keep-state")
    fi

    # Esegui prima in simulazione/anteprima per mostrare all'utente cosa accadrà
    "${py_cmd[@]}" --dry-run

    # Richiesta conferma
    if [[ "$auto_yes" -eq 0 ]]; then
        echo ""
        echo -n "Procedere con l'eliminazione consistente degli snapshot selezionati? [s/N]: "
        local answer
        read -r answer
        if [[ ! "$answer" =~ ^[Ss]$ && ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Operazione annullata dall'utente."
            exit 0
        fi
    fi

    # Esecuzione effettiva
    echo ""
    "${py_cmd[@]}" --execute
}

main "$@"
