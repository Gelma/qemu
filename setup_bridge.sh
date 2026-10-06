#!/usr/bin/env bash
set -euo pipefail

# setup_bridge.sh - Configura bridge / macvtap su interfaccia di rete (es. eth0)
# per permettere a QEMU di esporre la VM direttamente sulla LAN fisica.

usage() {
    local script_name
    script_name="$(basename "$0")"
    echo "Uso: $script_name [comando] [interfaccia_fisica]"
    echo ""
    echo "Comandi disponibili:"
    echo "  macvtap   (predefinito) Crea macvtap in modalità bridge su eth0 (zero impatto sull'IP dell'host)"
    echo "  bridge    Crea bridge Linux br0 e associa eth0"
    echo "  status    Mostra lo stato della configurazione di rete"
    echo "  cleanup   Rimuove l'interfaccia macvtap o il bridge creato"
    echo ""
    echo "Esempi:"
    echo "  sudo ./$script_name macvtap eth0"
    echo "  sudo ./$script_name bridge eth0"
    echo "  ./$script_name status"
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "Errore: questo comando richiede privilegi di root (esegui con 'sudo $0')." >&2
        exit 1
    fi
}

cmd_status() {
    local iface="${1:-eth0}"
    echo "=== Stato Interfacce di Rete ==="
    echo "[Host interface: $iface]"
    if ip link show "$iface" >/dev/null 2>&1; then
        ip -br link show "$iface"
        ip -br addr show "$iface"
    else
        echo "Interfaccia '$iface' non trovata!"
    fi
    echo ""
    echo "[Bridge Linux br0]"
    if ip link show br0 >/dev/null 2>&1; then
        ip -br link show br0
        ip -br addr show br0
    else
        echo "Bridge 'br0' non configurato."
    fi
    echo ""
    echo "[Macvtap macvtap0]"
    if ip link show macvtap0 >/dev/null 2>&1; then
        ip -br link show macvtap0
        local tap_mac
        tap_mac="$(cat /sys/class/net/macvtap0/address 2>/dev/null || echo "")"
        if [[ -n "$tap_mac" ]]; then
            echo "MAC Address hardware: $tap_mac"
        fi
        local tap_idx
        tap_idx="$(cat /sys/class/net/macvtap0/ifindex 2>/dev/null || echo "")"
        if [[ -n "$tap_idx" && -e "/dev/tap${tap_idx}" ]]; then
            echo "Device character file: /dev/tap${tap_idx} (permessi: $(ls -l "/dev/tap${tap_idx}" | awk '{print $1, $3, $4}'))"
        fi
    else
        echo "Interfaccia 'macvtap0' non configurata."
    fi
}

cmd_macvtap() {
    require_root
    local iface="${1:-eth0}"
    local desired_mac="${2:-}"
    local tap_name="macvtap0"

    echo "[setup_bridge] Configurazione macvtap su '$iface' in modalità bridge..."

    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "Errore: l'interfaccia fisica '$iface' non esiste." >&2
        exit 1
    fi

    local mac_arg=()
    if [[ -n "$desired_mac" ]]; then
        mac_arg=("address" "$desired_mac")
    fi

    # Crea interfaccia macvtap se non esiste già
    if ip link show "$tap_name" >/dev/null 2>&1; then
        echo "[setup_bridge] Interfaccia '$tap_name' già esistente."
        if [[ -n "$desired_mac" ]]; then
            ip link set "$tap_name" down
            ip link set "$tap_name" address "$desired_mac"
            echo "[setup_bridge] Indirizzo MAC impostato su: $desired_mac"
        fi
    else
        ip link add link "$iface" name "$tap_name" "${mac_arg[@]}" type macvtap mode bridge
        echo "[setup_bridge] Interfaccia '$tap_name' creata."
    fi

    ip link set "$tap_name" up
    echo "[setup_bridge] Interfaccia '$tap_name' attivata (UP)."

    local current_mac
    current_mac="$(cat "/sys/class/net/${tap_name}/address" 2>/dev/null || echo "")"
    echo "[setup_bridge] Indirizzo MAC attivo: $current_mac"

    # Configura permessi su /dev/tapX per permettere l'accesso a utenti standard
    local tap_idx
    tap_idx="$(cat "/sys/class/net/${tap_name}/ifindex")"
    if [[ -e "/dev/tap${tap_idx}" ]]; then
        chmod 666 "/dev/tap${tap_idx}"
        echo "[setup_bridge] Permessi impostati su /dev/tap${tap_idx} (rw-rw-rw-)."
    fi

    echo "[setup_bridge] Configurazione macvtap completata con successo!"
    echo "  I pacchetti della VM transiteranno direttamente su '$iface' verso il router LAN / DHCP."
    echo "  (QEMU utilizzerà automaticamente il MAC $current_mac per la scheda virtio)."
}

cmd_bridge() {
    require_root
    local iface="${1:-eth0}"
    local br_name="br0"

    echo "[setup_bridge] Configurazione bridge Linux '$br_name' su '$iface'..."

    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "Errore: l'interfaccia fisica '$iface' non esiste." >&2
        exit 1
    fi

    if ! ip link show "$br_name" >/dev/null 2>&1; then
        ip link add name "$br_name" type bridge
        echo "[setup_bridge] Bridge '$br_name' creato."
    fi

    ip link set "$iface" master "$br_name" 2>/dev/null || true
    ip link set "$br_name" up
    echo "[setup_bridge] Bridge '$br_name' attivo."

    # Configura /etc/qemu/bridge.conf
    mkdir -p /etc/qemu
    if ! grep -q "allow $br_name" /etc/qemu/bridge.conf 2>/dev/null; then
        echo "allow $br_name" >> /etc/qemu/bridge.conf
        chmod 644 /etc/qemu/bridge.conf
        echo "[setup_bridge] Aggiunto 'allow $br_name' a /etc/qemu/bridge.conf."
    fi

    # Configura setuid su qemu-bridge-helper (tree locale oppure /opt/qemu/libexec)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local helper_targets=(
        "${script_dir}/build/qemu-bridge-helper"
        "${script_dir}/build/qemu-bundle/opt/qemu/libexec/qemu-bridge-helper"
        "/opt/qemu/libexec/qemu-bridge-helper"
    )
    for h in "${helper_targets[@]}"; do
        if [[ -f "$h" ]]; then
            chmod u+s "$h" 2>/dev/null || true
            echo "[setup_bridge] Abilitato SUID su $h."
        fi
    done

    echo "[setup_bridge] Bridge Linux '$br_name' configurato con successo!"
}

cmd_cleanup() {
    require_root
    local tap_name="macvtap0"
    local br_name="br0"

    if ip link show "$tap_name" >/dev/null 2>&1; then
        ip link delete "$tap_name"
        echo "[setup_bridge] Rimossa interfaccia '$tap_name'."
    fi

    if ip link show "$br_name" >/dev/null 2>&1; then
        ip link delete "$br_name"
        echo "[setup_bridge] Rimosso bridge '$br_name'."
    fi

    echo "[setup_bridge] Pulizia completata."
}

main() {
    local cmd="${1:-macvtap}"
    local iface="${2:-eth0}"

    case "$cmd" in
        macvtap)
            cmd_macvtap "$iface"
            ;;
        bridge)
            cmd_bridge "$iface"
            ;;
        status)
            cmd_status "$iface"
            ;;
        cleanup)
            cmd_cleanup
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "Comando sconosciuto: '$cmd'" >&2
            usage
            ;;
    esac
}

main "$@"
