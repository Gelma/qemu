#!/usr/bin/env python3
"""
autoprotect_find_leaf.py - Risolve la catena di snapshot delta qcow2 di AutoProtect.

Identifica in modo deterministico e sicuro l'ultimo overlay (foglia attiva)
in cui risiedono tutte le scritture più recenti della VM, garantendo che al boot
la macchina virtuale riparta dallo stato esatto dell'ultimo snapshot/scrittura.
"""

import os
import sys
import json
import argparse
import subprocess

def inspect_image(qemu_img, path):
    try:
        res = subprocess.run([qemu_img, 'info', '--output=json', path],
                             capture_output=True, text=True, check=True)
        return json.loads(res.stdout)
    except Exception:
        return None

def analyze_disk_chain(qemu_img, disk_input):
    abs_input = os.path.realpath(disk_input)
    disk_dir = os.path.dirname(abs_input)
    info = inspect_image(qemu_img, abs_input)
    if not info:
        return {
            'error': f"Impossibile leggere le informazioni qcow2 per '{disk_input}' tramite '{qemu_img}'."
        }

    # Risali lungo l'eventuale catena di backing per trovare l'immagine base radice
    curr = abs_input
    curr_info = info
    while curr_info and curr_info.get('backing-filename'):
        bf = curr_info['backing-filename']
        bf_abs = os.path.realpath(os.path.join(os.path.dirname(curr), bf))
        curr = bf_abs
        curr_info = inspect_image(qemu_img, curr)

    base_image = curr

    # Cerca tutti i file di overlay potenziali nella stessa directory
    all_overlays = []
    if os.path.isdir(disk_dir):
        for f in os.listdir(disk_dir):
            if f.endswith('.qcow2') and ('-disk-' in f or f.startswith('autoprotect-')):
                full_p = os.path.realpath(os.path.join(disk_dir, f))
                if full_p != base_image:
                    all_overlays.append(full_p)

    # Mappa backing file per ciascun overlay
    overlay_backing = {}
    backed_by_set = set()
    for ov in all_overlays:
        ov_info = inspect_image(qemu_img, ov)
        if ov_info and ov_info.get('backing-filename'):
            bf_abs = os.path.realpath(os.path.join(os.path.dirname(ov), ov_info['backing-filename']))
            overlay_backing[ov] = bf_abs
            backed_by_set.add(bf_abs)

    # Filtra solo gli overlay che risalgono a questa immagine base radice
    matching_overlays = []
    for ov in all_overlays:
        c = ov
        visited = set()
        while c in overlay_backing and c not in visited:
            visited.add(c)
            c = overlay_backing[c]
            if c == base_image:
                matching_overlays.append(ov)
                break

    if not matching_overlays:
        return {
            'base_image': base_image,
            'active_leaf': abs_input,
            'is_leaf': True,
            'chain_depth': 0,
            'matching_overlays_count': 0,
            'overlays': []
        }

    # Le foglie sono gli overlay non referenziati come backing da nessun altro
    leaves = [ov for ov in matching_overlays if ov not in backed_by_set]
    if not leaves:
        leaves = matching_overlays

    # Ordina le foglie per tempo di modifica discendente (più recente in testa)
    leaves.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    active_leaf = leaves[0]

    # Calcola la profondità della catena per l'active_leaf
    depth = 0
    c = active_leaf
    while c in overlay_backing:
        c = overlay_backing[c]
        depth += 1
        if c == base_image:
            break

    # Ordina tutti i matching_overlays per mtime
    matching_overlays.sort(key=lambda x: os.path.getmtime(x))

    return {
        'base_image': base_image,
        'active_leaf': active_leaf,
        'is_leaf': (abs_input == active_leaf),
        'chain_depth': depth,
        'matching_overlays_count': len(matching_overlays),
        'overlays': matching_overlays
    }

def main():
    parser = argparse.ArgumentParser(
        description="Trova la foglia attiva nella catena di delta snapshot qcow2."
    )
    parser.add_argument("disk", help="Percorso del disco base o di un overlay qcow2")
    parser.add_argument("--qemu-img", default="qemu-img", help="Percorso del binario qemu-img")
    parser.add_argument("--json", action="store_true", help="Stampa l'analisi completa in formato JSON")
    parser.add_argument("--base", action="store_true", help="Forza la selezione dell'immagine base")
    parser.add_argument("--snapshot", help="Seleziona un overlay specifico corrispondente al tag indicato")

    args = parser.parse_args()

    # Risoluzione automatica di qemu-img se non trovato nel PATH
    qemu_img = args.qemu_img
    if not os.path.isabs(qemu_img) and not subprocess.run(["which", qemu_img], capture_output=True).returncode == 0:
        script_dir = os.path.dirname(os.path.realpath(__file__))
        candidates = [
            os.path.join(script_dir, "build", "qemu-img"),
            "/opt/qemu/bin/qemu-img"
        ]
        for c in candidates:
            if os.path.isfile(c) and os.access(c, os.X_OK):
                qemu_img = c
                break

    analysis = analyze_disk_chain(qemu_img, args.disk)
    if 'error' in analysis:
        sys.stderr.write(f"Errore: {analysis['error']}\n")
        sys.exit(1)

    boot_disk = analysis['active_leaf']
    if args.base:
        boot_disk = analysis['base_image']
    elif args.snapshot:
        tag = args.snapshot
        found = None
        for ov in analysis.get('overlays', []):
            b = os.path.basename(ov)
            if tag in b:
                found = ov
                break
        if not found:
            sys.stderr.write(f"Errore: snapshot con tag '{tag}' non trovato nella catena.\n")
            sys.exit(1)
        boot_disk = found

    analysis['selected_boot_disk'] = boot_disk

    if args.json:
        print(json.dumps(analysis, indent=2))
    else:
        print(boot_disk)

if __name__ == '__main__':
    main()
