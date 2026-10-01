#!/usr/bin/env bash
# configure_max.sh - Launch QEMU configure with maximum possible features enabled for this host.
set -euo pipefail

# Directory of this script (QEMU source tree)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Features from ./configure --help "Optional features, enabled with --enable-FEATURE and"
# that are verified to pass configure on this system.
# (Total: 116 enabled features)
readonly ENABLED_FEATURES=(
    af-xdp
    alsa
    attr
    auth-pam
    bochs
    bpf
    brlapi
    bzip2
    cap-ng
    capstone
    cloop
    colo-proxy
    crypto-afalg
    curl
    curses
    dbus-display
    dmg
    docs
    fuse
    fuse-lseek
    gcrypt
    gettext
    gio
    gnutls
    gtk
    guest-agent
    hmp
    hv-balloon
    iconv
    jack
    keyring
    kvm
    l2tpv3
    libcbor
    libdaxctl
    libdw
    libiscsi
    libkeyutils
    libnfs
    libpmem
    libssh
    libudev
    libusb
    libvduse
    linux-aio
    linux-io-uring
    lzfse
    lzo
    malloc-trim
    membarrier
    modules
    multiprocess
    nitro
    numa
    opengl
    oss
    pa
    parallels
    passt
    pipewire
    pixman
    plugins
    png
    qcow1
    qed
    qemu-vnc
    rbd
    rdma
    replication
    sdl
    sdl-image
    seccomp
    selinux
    slirp
    slirp-smbd
    smartcard
    snappy
    sndio
    sparse
    spice
    spice-protocol
    stack-protector
    tcg
    tests
    tools
    tpm
    usb-redir
    valgrind
    vde
    vdi
    vduse-blk-export
    vfio-user-server
    vhdx
    vhost-crypto
    vhost-kernel
    vhost-net
    vhost-user
    vhost-user-blk-server
    vhost-vdpa
    virglrenderer
    virtfs
    vmdk
    vnc
    vnc-jpeg
    vnc-sasl
    vpc
    vte
    vvfat
    werror
    xen
    xen-pci-passthrough
    xkbcommon
    zstd
    system
    linux-user
    pie
)

# Build configure argument list
CONFIGURE_ARGS=(
    "--prefix=/opt/qemu"
)

for feat in "${ENABLED_FEATURES[@]}"; do
    CONFIGURE_ARGS+=("--enable-${feat}")
done

# Allow passing additional custom flags to configure (e.g. --target-list=...)
if [[ $# -gt 0 ]]; then
    CONFIGURE_ARGS+=("$@")
fi

echo "=========================================================="
echo "Configuring QEMU with ${#ENABLED_FEATURES[@]} optional features enabled..."
echo "Prefix: /opt/qemu"
echo "=========================================================="

cd "${SOURCE_DIR}"
exec "${SOURCE_DIR}/configure" "${CONFIGURE_ARGS[@]}"
