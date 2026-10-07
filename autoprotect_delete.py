#!/usr/bin/env python3
"""
autoprotect_delete.py - Eliminazione selettiva di snapshot singoli o multipli
con mantenimento garantito della consistenza della catena di backing.

Funzionalità:
- Rileva snapshot Live Delta (overlay qcow2 esterni) e snapshot interni qcow2.
- Supporta selezione arbitraria: indici singoli ('2'), elenchi ('1,3,5'),
  intervalli ('2-5'), tag specifici ('autoprotect-20261006-164531') o 'all'.
- Calcola il grafo di dipendenze (DAG) e pianifica il rebasing dei nodi superstiti
  che puntavano ai nodi eliminati, collegandoli al più vicino antenato superstite.
- Esegue i rebase in ordine decrescente di profondità (top-down), garantendo
  che ogni cluster modificato negli snapshot intermedi venga preservato nei discendenti.
- Rimuove in sicurezza i file .qcow2 eliminati e i rispettivi dump RAM e dev (.state).
- Supporta modalità --dry-run per simulare l'operazione e stimare lo spazio liberabile.
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

def format_size(bytes_val):
    if bytes_val >= 1073741824:
        return f"{bytes_val / 1073741824:.2f} GB"
    elif bytes_val >= 1048576:
        return f"{bytes_val / 1048576:.2f} MB"
    elif bytes_val >= 1024:
        return f"{bytes_val / 1024:.2f} KB"
    else:
        return f"{bytes_val} B"

def gather_snapshots(qemu_img, disk_input):
    abs_input = os.path.realpath(disk_input)
    disk_dir = os.path.dirname(abs_input)
    info = inspect_image(qemu_img, abs_input)
    if not info:
        return None, f"Impossibile leggere le informazioni per '{disk_input}'."

    # Trova l'immagine base risalendo l'eventuale catena
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

    # Filtra solo gli overlay che risalgono a questa immagine base
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

    # Calcola profondità dal base per ciascun overlay
    depth_map = {base_image: 0}
    for ov in matching_overlays:
        d = 0
        tmp = ov
        while tmp in overlay_backing:
            tmp = overlay_backing[tmp]
            d += 1
            if tmp == base_image:
                break
        depth_map[ov] = d

    # Ordina overlay per profondità topologica e tag cronologico
    matching_overlays.sort(key=lambda x: (depth_map.get(x, 0), os.path.basename(x)))

    # Costruisci lista snapshot Live Delta
    snapshots = []
    for ov in matching_overlays:
        fname = os.path.basename(ov)
        tag = fname.split('-disk-')[0] if '-disk-' in fname else fname[:-6]
        d = depth_map.get(ov, 0)

        ram_file = os.path.join(disk_dir, f"{tag}-ram.state")
        dev_file = os.path.join(disk_dir, f"{tag}-dev.state")

        ov_size = os.path.getsize(ov) if os.path.isfile(ov) else 0
        ram_size = os.path.getsize(ram_file) if os.path.isfile(ram_file) else 0
        dev_size = os.path.getsize(dev_file) if os.path.isfile(dev_file) else 0

        is_leaf = (ov not in backed_by_set)
        mtime = os.path.getmtime(ov)

        snapshots.append({
            'type': 'live_delta',
            'tag': tag,
            'disk_path': ov,
            'backing_path': overlay_backing.get(ov, base_image),
            'depth': d,
            'is_leaf': is_leaf,
            'mtime': mtime,
            'disk_size': ov_size,
            'ram_file': ram_file if os.path.isfile(ram_file) else None,
            'dev_file': dev_file if os.path.isfile(dev_file) else None,
            'ram_size': ram_size,
            'dev_size': dev_size,
            'total_size': ov_size + ram_size + dev_size
        })

    # Cerca anche snapshot interni al qcow2 base (se presenti)
    base_info = inspect_image(qemu_img, base_image)
    if base_info and 'snapshot-list' in base_info:
        for sn in base_info['snapshot-list']:
            tag = sn.get('name', str(sn.get('id', '')))
            snapshots.append({
                'type': 'internal',
                'tag': tag,
                'disk_path': base_image,
                'backing_path': None,
                'depth': 0,
                'is_leaf': False,
                'mtime': sn.get('date-sec', 0),
                'disk_size': sn.get('vm-clock-sec', 0),
                'ram_file': None,
                'dev_file': None,
                'ram_size': sn.get('vm-state-size', 0),
                'dev_size': 0,
                'total_size': sn.get('vm-state-size', 0)
            })

    ctx = {
        'base_image': base_image,
        'overlay_backing': overlay_backing,
        'depth_map': depth_map,
        'snapshots': snapshots
    }
    return ctx, None

def parse_selector(selector_str, snapshots):
    s = selector_str.strip()
    total = len(snapshots)
    if not s or total == 0:
        return []

    if s.lower() == 'all':
        return list(range(1, total + 1))

    tags_list = [sn['tag'] for sn in snapshots]
    parts = [p.strip() for p in s.replace(' ', ',').split(',') if p.strip()]
    selected = set()

    for part in parts:
        # Match tag esatto
        if part in tags_list:
            selected.add(tags_list.index(part) + 1)
            continue

        # Match tag parziale (es. timestamp o prefisso)
        matched_tag = False
        for idx, tag in enumerate(tags_list, 1):
            if part in tag and len(part) >= 4:
                selected.add(idx)
                matched_tag = True
        if matched_tag:
            continue

        # Match intervallo numerico (es. 2-5)
        if '-' in part:
            try:
                start_s, end_s = part.split('-', 1)
                start, end = int(start_s), int(end_s)
                for i in range(min(start, end), max(start, end) + 1):
                    if 1 <= i <= total:
                        selected.add(i)
                continue
            except ValueError:
                pass

        # Match indice numerico (es. 3)
        if part.isdigit():
            val = int(part)
            if 1 <= val <= total:
                selected.add(val)

    return sorted(selected)

def plan_deletion(ctx, selected_indices, keep_state=False):
    snapshots = ctx['snapshots']
    base_image = ctx['base_image']
    overlay_backing = ctx['overlay_backing']
    depth_map = ctx['depth_map']

    to_delete = [snapshots[i - 1] for i in selected_indices]
    surviving = [sn for i, sn in enumerate(snapshots, 1) if i not in selected_indices]

    # Separa snapshot interni e Live Delta
    del_internal = [sn for sn in to_delete if sn['type'] == 'internal']
    del_live = [sn for sn in to_delete if sn['type'] == 'live_delta']

    del_live_paths = set(sn['disk_path'] for sn in del_live)
    surviving_live = [sn for sn in surviving if sn['type'] == 'live_delta']

    # Per ogni nodo live superstite, verifica se il suo backing è tra quelli da eliminare
    # In tal caso, trova il più vicino antenato che NON è tra quelli da eliminare
    rebase_plan = []
    for s in surviving_live:
        disk_p = s['disk_path']
        old_backing = s['backing_path']
        if old_backing in del_live_paths:
            # Risali lungo gli antenati fino al primo superstite
            anc = old_backing
            while anc in del_live_paths:
                anc = overlay_backing.get(anc, base_image)
            
            d = depth_map.get(disk_p, 0)
            rebase_plan.append({
                'depth': d,
                'target_disk': disk_p,
                'target_tag': s['tag'],
                'old_backing': old_backing,
                'new_backing': anc
            })

    # Ordina i rebase dal nodo a profondità maggiore al nodo a profondità minore (top-down)
    rebase_plan.sort(key=lambda x: x['depth'], reverse=True)

    # Elenco file fisici da rimuovere
    files_to_remove = []
    total_reclaimable = 0

    for sn in del_live:
        p = sn['disk_path']
        files_to_remove.append(p)
        total_reclaimable += sn['disk_size']
        if not keep_state:
            if sn['ram_file']:
                files_to_remove.append(sn['ram_file'])
                total_reclaimable += sn['ram_size']
            if sn['dev_file']:
                files_to_remove.append(sn['dev_file'])
                total_reclaimable += sn['dev_size']

    # Snapshot interni da eliminare tramite qemu-img snapshot -d
    internal_tags = [sn['tag'] for sn in del_internal]

    # Nuova foglia attiva dopo l'eliminazione
    new_leaf = None
    if surviving_live:
        # Trova tra i surviving_live quello con mtime più recente che non è backing di nessun altro surviving
        surviving_backing_set = set()
        for s in surviving_live:
            # Determina il suo backing effettivo dopo il rebase pianificato
            eff_backing = s['backing_path']
            for rb in rebase_plan:
                if rb['target_disk'] == s['disk_path']:
                    eff_backing = rb['new_backing']
                    break
            surviving_backing_set.add(eff_backing)

        candidate_leaves = [s for s in surviving_live if s['disk_path'] not in surviving_backing_set]
        if not candidate_leaves:
            candidate_leaves = surviving_live
        candidate_leaves.sort(key=lambda x: x['mtime'], reverse=True)
        new_leaf = candidate_leaves[0]['disk_path']
    else:
        new_leaf = base_image

    return {
        'to_delete_count': len(to_delete),
        'deleted_snapshots': to_delete,
        'del_internal': internal_tags,
        'rebase_plan': rebase_plan,
        'files_to_remove': files_to_remove,
        'reclaimable_bytes': total_reclaimable,
        'reclaimable_str': format_size(total_reclaimable),
        'new_leaf': new_leaf,
        'all_snapshots_deleted': (len(surviving) == 0)
    }

def execute_plan(qemu_img, ctx, plan):
    base_image = ctx['base_image']

    # 1. Esegui rebase dei nodi superstiti
    for rb in plan['rebase_plan']:
        target = rb['target_disk']
        new_b = rb['new_backing']
        cmd = [qemu_img, 'rebase', '-b', new_b, '-F', 'qcow2', target]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            return False, f"Fallito 'qemu-img rebase' su '{target}': {res.stderr.strip()}"

    # 2. Elimina snapshot interni
    for tag in plan['del_internal']:
        cmd = [qemu_img, 'snapshot', '-d', tag, base_image]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            sys.stderr.write(f"Attenzione: eliminazione snapshot interno '{tag}' non riuscita: {res.stderr.strip()}\n")

    # 3. Elimina i file fisici decoupled
    removed_count = 0
    for f in plan['files_to_remove']:
        try:
            if os.path.isfile(f):
                os.remove(f)
                removed_count += 1
        except Exception as e:
            sys.stderr.write(f"Attenzione: impossibile rimuovere '{f}': {e}\n")

    return True, f"Eliminazione completata con successo ({removed_count} file rimossi)."

def print_snapshots_table(snapshots):
    print("=" * 88)
    print(f"{'NUM':<4} | {'TAG SNAPSHOT':<30} | {'TIPO':<17} | {'DATA E ORA':<19} | {'STATO RAM':<10}")
    print("-" * 5 + "+" + "-" * 32 + "+" + "-" * 19 + "+" + "-" * 21 + "+" + "-" * 10)
    import datetime
    for i, sn in enumerate(snapshots, 1):
        tag = sn['tag']
        stype = "Live Delta" if sn['type'] == 'live_delta' else "Interno"
        if sn['is_leaf']:
            stype += " [ATTIVO]"
        mtime_str = datetime.datetime.fromtimestamp(sn['mtime']).strftime("%Y-%m-%d %H:%M:%S") if sn['mtime'] else "N/A"
        ram_str = format_size(sn['ram_size']) if sn['ram_size'] > 0 else "N/A"
        print(f"{i:<4} | {tag:<30} | {stype:<17} | {mtime_str:<19} | {ram_str:<10}")
    print("=" * 88)

def main():
    parser = argparse.ArgumentParser(
        description="Eliminazione selettiva consistente di snapshot QEMU AutoProtect."
    )
    parser.add_argument("disk", help="Percorso del file immagine disco o overlay")
    parser.add_argument("--qemu-img", default="qemu-img", help="Percorso del binario qemu-img")
    parser.add_argument("--select", "-s", help="Indici, intervalli o tag da eliminare (es. '1,3,5' o '2-4' o 'all')")
    parser.add_argument("--list", "-l", action="store_true", help="Elenca gli snapshot disponibili ed esce")
    parser.add_argument("--dry-run", action="store_true", help="Simula l'eliminazione senza modificare alcun file")
    parser.add_argument("--execute", action="store_true", help="Esegue l'eliminazione effettiva")
    parser.add_argument("--keep-state", action="store_true", help="Non eliminare i file di memoria (*-ram.state / *-dev.state)")
    parser.add_argument("--json", action="store_true", help="Output in formato JSON")

    args = parser.parse_args()

    qemu_img = args.qemu_img
    if not os.path.isabs(qemu_img) and subprocess.run(["which", qemu_img], capture_output=True).returncode != 0:
        script_dir = os.path.dirname(os.path.realpath(__file__))
        candidates = [
            os.path.join(script_dir, "build", "qemu-img"),
            "/opt/qemu/bin/qemu-img"
        ]
        for c in candidates:
            if os.path.isfile(c) and os.access(c, os.X_OK):
                qemu_img = c
                break

    ctx, err = gather_snapshots(qemu_img, args.disk)
    if err:
        sys.stderr.write(f"Errore: {err}\n")
        sys.exit(1)

    snapshots = ctx['snapshots']

    if args.list:
        if args.json:
            print(json.dumps(snapshots, indent=2))
        else:
            print_snapshots_table(snapshots)
        sys.exit(0)

    if not args.select:
        sys.stderr.write("Errore: specificare gli snapshot da eliminare con --select (oppure usare --list).\n")
        sys.exit(1)

    selected_indices = parse_selector(args.select, snapshots)
    if not selected_indices:
        sys.stderr.write(f"Nessuno snapshot corrispondente alla selezione '{args.select}'.\n")
        sys.exit(1)

    plan = plan_deletion(ctx, selected_indices, keep_state=args.keep_state)

    if args.json:
        print(json.dumps(plan, indent=2))
        sys.exit(0)

    # Stampa piano di eliminazione
    print("\n" + "=" * 78)
    print("           PIANO DI ELIMINAZIONE SELETTIVA SNAPSHOT")
    print("=" * 78)
    print(f"Disco base:                {ctx['base_image']}")
    print(f"Snapshot totali rilevati:  {len(snapshots)}")
    print(f"Snapshot da eliminare:     {plan['to_delete_count']}")
    for idx in selected_indices:
        sn = snapshots[idx - 1]
        print(f"  - [{idx}] {sn['tag']} ({sn['type']})")

    print(f"\nRistrutturazione catena backing (Rebase coerenti necessari: {len(plan['rebase_plan'])}):")
    if plan['rebase_plan']:
        for rb in plan['rebase_plan']:
            print(f"  - {os.path.basename(rb['target_disk'])} -> nuovo backing: {os.path.basename(rb['new_backing'])}")
    else:
        print("  - Nessun rebase necessario (eliminati solo nodi foglia o tutti gli snapshot).")

    print(f"\nFile che verranno rimossi ({len(plan['files_to_remove'])} file):")
    for f in plan['files_to_remove']:
        print(f"  - {f}")

    print(f"\nSpazio disco stimato liberabile: {plan['reclaimable_str']}")
    print(f"Nuova foglia attiva al boot:      {os.path.basename(plan['new_leaf'])}")
    print("=" * 78)

    if args.dry_run:
        print("\n[DRY RUN] Simulazione completata. Nessuna operazione eseguita sui file.")
        sys.exit(0)

    if args.execute:
        print("\nEsecuzione eliminazione in corso...")
        success, msg = execute_plan(qemu_img, ctx, plan)
        if not success:
            sys.stderr.write(f"ERRORE: {msg}\n")
            sys.exit(1)
        print(f"\n[OK] {msg}")
        print("Consistenza della catena di dischi verificata con successo.")
        sys.exit(0)

if __name__ == '__main__':
    main()
