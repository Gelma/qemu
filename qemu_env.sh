#!/usr/bin/env bash
# qemu_env.sh - Imposta PATH e variabili d'ambiente per usare i tool QEMU
# compilati nel tree locale oppure installati in /opt/qemu.
#
# Utilizzo:
#   source qemu_env.sh

_setup_qemu_env() {
    local script_dir
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        script_dir="$(pwd)"
    fi

    local build_bin="${script_dir}/build"
    local opt_bin="/opt/qemu/bin"
    local opt_libexec="/opt/qemu/libexec"

    # Prepend build directory and /opt/qemu/bin to PATH
    if [[ -d "$build_bin" ]]; then
        export PATH="${build_bin}:${opt_bin}:${PATH}"
    else
        export PATH="${opt_bin}:${PATH}"
    fi

    echo "=== Ambiente QEMU Configurato ==="
    echo "PATH aggiornato con priorità: tree locale -> /opt/qemu"
    echo ""
    echo "Binari attivi rilevati:"
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo "  - qemu-system-x86_64: $(command -v qemu-system-x86_64)"
    else
        echo "  - qemu-system-x86_64: [NON TROVATO]"
    fi

    if command -v qemu-img >/dev/null 2>&1; then
        echo "  - qemu-img:           $(command -v qemu-img)"
    else
        echo "  - qemu-img:           [NON TROVATO]"
    fi

    if [[ -x "${build_bin}/qemu-bridge-helper" ]]; then
        echo "  - qemu-bridge-helper: ${build_bin}/qemu-bridge-helper"
    elif [[ -x "${opt_libexec}/qemu-bridge-helper" ]]; then
        echo "  - qemu-bridge-helper: ${opt_libexec}/qemu-bridge-helper"
    fi
    echo "================================="
}

_setup_qemu_env
unset -f _setup_qemu_env
