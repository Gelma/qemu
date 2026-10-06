# SpecAI.md — QEMU AutoProtect: Analisi e Piano di Implementazione

## Progetto
Implementazione di una funzionalità simile a VMware AutoProtect nel codebase QEMU
(versione 11.1.50, development branch). Snapshot periodici automatici di RAM + storage
con retention a tempo e impatto minimo sul funzionamento della VM.

## Directory Workspace
`/home/gelma/dev/prg/qemu`

## Stato Corrente
- **Sessione 2026-10-01 — Analisi**: Completata analisi di fattibilità del codebase.
  Nessun file QEMU modificato. Report artifact generato.

---

## Storico Sessioni

| Data | Fase | Cosa è stato fatto | Step completati |
|:-----|:-----|:--------------------|:----------------|
| 2026-10-01 | Analisi | Analisi fattibilità completa, 3 strategie identificate (A/B/C) | Fase 0 ✅ |
| 2026-10-01 | Fase 1 | Implementato tool AutoProtect autonomo: `tools/autoprotect/autoprotect.py` (QMP client nativo, daemon, oneshot, list, prune, discovery), `start.sh`, `stop.sh`, `Makefile`, unit test `test_autoprotect.py`, systemd service/timer e `README.md` | Fase 1 ✅ |
| 2026-10-01 | Fase 2 | Implementato modulo interno QEMU: schema QAPI (`qapi/autoprotect.json`), header `include/migration/autoprotect.h`, implementazione stub C in `migration/autoprotect.c`, integrazione build in `qapi/meson.build`, `migration/meson.build`, `qapi/qapi-schema.json`. Compilazione e linking verificati, comandi QMP testati live. | Fase 2 ✅ |
| 2026-10-01 | Fase 3 | Implementata logica interna completa in `migration/autoprotect.c`: gestione `AutoProtectState`, timer `QEMUTimer` su `QEMU_CLOCK_REALTIME`, callback di snapshot periodico via `save_snapshot`, pruning automatico via `delete_snapshot` con salvaguardia snapshot manuali, comandi HMP `autoprotect` e `info autoprotect`. Test di funzionamento live su VM reale superati. | Fase 3 ✅ |
| 2026-10-01 | Tooling | Creato e aggiornato script `configure_max.sh` che lancia `./configure --prefix="/opt/qemu"` abilitando 116 feature opzionali supportate e compilabili sul laptop (aggiunte 9 nuove opzioni a seguito dell'installazione delle relative librerie di sviluppo: `af-xdp`, `capstone`, `libcbor`, `libdaxctl`, `lzfse`, `sdl-image`, `sparse`, `vde`, `vfio-user-server`). | Tooling ✅ |
| 2026-10-06 | Fase 6 | Eliminazione blocco VM guest durante snapshot: salvataggio delta storage + RAM nella directory del disco base via COW (`fork()` asincrono con `MADV_DOFORK`), scheduling cancellazione notturna (`night-prune` 23:00-06:00), script di supporto ripristino ed elenco snapshot (`autoprotect_restore.sh`), configurazione bridge/macvtap su `eth0` (`setup_bridge.sh` e `autoprotect_start.sh`). | Fase 6 ✅ |
| 2026-10-06 | Tooling & Paths | Vincolo prioritario risoluzione binari QEMU: utilizzo esclusivo del build tree locale (`./build`) o del path `/opt/qemu` (`bin`/`libexec`), escludendo categoricamente i binari di sistema (`/usr/bin`, `/usr/lib`). Creato `qemu_env.sh` e aggiornati tutti gli script di supporto. | Tooling & Paths ✅ |
| 2026-10-06 | Bugfix | Risolto crash `Assertion !(bs->open_flags & BDRV_O_INACTIVE) failed` su scritture guest post-snapshot: sostituita `qmp_xen_save_devices_state` con funzione dedicata `autoprotect_save_devices_state` (`qemu_save_device_state`) senza inattivare i block device. Aggiornato binario sia in `./build/` sia in `/opt/qemu/bin/`. | Bugfix ✅ |
| 2026-10-06 | Boot Guarantee | Garanzia assoluta di boot dall'ultimo snapshot/scrittura: creato risolutore `autoprotect_find_leaf.py` che ispeziona la catena qcow2 e individua la foglia attiva (overlay più recente). Aggiornato `autoprotect_start.sh` per avviare di default dalla foglia preservando il 100% dei dati scritti dal guest, con opzioni `--base`, `--snapshot <tag>` e `--dry-run`. Aggiornato `autoprotect_restore.sh` con marker `[ATTIVO]`. | Boot Guarantee ✅ |
| 2026-10-06 | Network & SSH | Risolta connettività di rete bridge macvtap su eth0 e accesso SSH guest: sincronizzato MAC address della scheda virtio con quello effettivo di macvtap0 (evitando lo scarto del kernel dei pacchetti di risposta DHCP/LAN); aggiunta scheda di rete di gestione locale con port forwarding SSH su porta 10022 (`ssh -p 10022 gelma@localhost`) con `restrict=on` per evitare conflitti di gateway predefinito. Verificata connettività LAN (IP 172.16.5.142/23), ping gateway e risoluzione DNS da dentro la VM. | Network & SSH ✅ |
| 2026-10-06 | Documentazione | Inserita sezione completa 'Guida Operativa Rapida ed Esempi di Utilizzo': comandi di configurazione bridge, avvio standard e differito con AutoProtect, selezione/ripristino snapshot, accesso SSH host, avvio da disco base e arresto controllato. | Documentazione ✅ |

---

## Riferimenti Chiave nel Codebase

### Snapshot — Path interno (blocca la VM)
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `save_snapshot()` | `migration/savevm.c` | 3299-3411 |
| `vm_stop(RUN_STATE_SAVE_VM)` — **il punto critico** | `migration/savevm.c` | 3357 |
| `SnapshotJob` struct | `migration/savevm.c` | 3633-3641 |
| `snapshot_save_job_driver` | `migration/savevm.c` | 3739-3743 |
| `qmp_snapshot_save()` | `migration/savevm.c` | 3752-3772 |
| `qmp_snapshot_delete()` | `migration/savevm.c` | 3796-3814 |
| `delete_snapshot()` | `migration/savevm.c` | (cerca "bool delete_snapshot") |

### Snapshot — Schema QAPI
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `snapshot-save` command | `qapi/migration.json` | 2061-2130 |
| `snapshot-delete` command | `qapi/migration.json` | 2203-2255 |
| `snapshot-load` command | `qapi/migration.json` | 2133-2200 |
| `SnapshotInfo` struct | `qapi/block-core.json` | 15-44 |
| `transaction` command | `qapi/transaction.json` | 203-274 |
| `blockdev-snapshot-sync` | `qapi/block-core.json` | 1825-1845 |

### Snapshot — Block layer
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `QEMUSnapshotInfo` struct | `include/block/snapshot.h` | 37-47 |
| `bdrv_snapshot_list()` | `block/snapshot.c` | 387-406 |
| `bdrv_all_can_snapshot()` | `block/snapshot.c` | 532 |
| `bdrv_all_create_snapshot()` | `block/snapshot.c` | 695 |
| `bdrv_all_delete_snapshot()` | `block/snapshot.c` | 565 |
| `bdrv_all_find_vmstate_bs()` | `block/snapshot.c` | 736 |

### Background Snapshot (UFFD-WP, non-blocking)
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `bg_migration_thread()` | `migration/migration.c` | 3825-3956 |
| `bg_migration_vm_start_bh()` | `migration/migration.c` | 3802-3808 |
| `ram_write_tracking_start()` | `migration/ram.c` | (cerca la funzione) |
| `ram_write_tracking_available()` | `migration/ram.c` | 1582 |
| `migrate_background_snapshot()` | `migration/options.c` | 318-322 |
| `x-background-snapshot` capability | `migration/options.c` | 214-215 |

### Timer System
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `QEMUTimer` struct | `include/qemu/timer.h` | 85-94 |
| `timer_new_ms()` / `timer_mod()` | `include/qemu/timer.h` | 472-482, 644-653 |
| `QEMU_CLOCK_VIRTUAL` | `include/qemu/timer.h` | 49-51 |
| `QEMU_CLOCK_REALTIME` | `include/qemu/timer.h` | 49 |

### Job System
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `JobDriver` struct | `include/qemu/job.h` | (cerca struct) |
| `job_create()` | `include/qemu/job.h` | (cerca dichiarazione) |
| `JOB_STATUS_CHANGE` event | `qapi/job.json` | (cerca evento) |
| `JOB_MANUAL_DISMISS` flag | `include/qemu/job.h` | (cerca define/enum) |

### HMP (monitor umano)
| Elemento | File | Riga/Range |
|:---------|:-----|:-----------|
| `hmp_savevm()` | `migration/migration-hmp-cmds.c` | 493-500 |
| `hmp_delvm()` | `migration/migration-hmp-cmds.c` | 502-509 |
| `hmp_info_snapshots()` | `block/monitor/block-hmp-cmds.c` | 797-880 |
| `savevm` HMP definition | `hmp-commands.hx` | 344-360 |

---

## Piano di Implementazione — Progressione per Fasi

L'implementazione segue una progressione **incrementale a 5 fasi**, dove ogni fase
produce un deliverable funzionante e testabile indipendentemente.

---

### FASE 0 — Analisi di Fattibilità ✅ COMPLETATA
**Obiettivo:** Capire il codebase, identificare le strategie, valutare sforzo/invasività.
**Output:** Report di fattibilità (artifact), questo documento.

---

### FASE 1 — Script Esterno QMP (Strategia A)
**Obiettivo:** Prototipo funzionante che valida il flusso end-to-end senza toccare QEMU.
**Stato:** ✅ Completata

#### Step 1.1 — Script base: singolo snapshot via QMP
- [x] Creare `tools/autoprotect/autoprotect.py`
- [x] Connessione al socket QMP UNIX (es. `/tmp/qemu-monitor.sock`)
- [x] Invio comando `snapshot-save` con parametri:
  ```json
  { "execute": "snapshot-save",
    "arguments": {
      "job-id": "autoprotect-<timestamp>",
      "tag": "autoprotect-<YYYYMMDD-HHMMSS>",
      "vmstate": "<node-name>",
      "devices": ["<node-name>"]
    }
  }
  ```
- [x] Polling/attesa `JOB_STATUS_CHANGE` → `concluded`
- [x] Gestione errori (job failed, socket non connesso, VM non running)
- **File:** `tools/autoprotect/autoprotect.py`
- **Test:** lanciare QEMU con `-qmp unix:/tmp/qmp.sock,server,wait=off`, eseguire script,
  verificare snapshot creato con `info snapshots` nel monitor HMP
- **Criteri di accettazione:**
  - Lo script crea uno snapshot con tag leggibile
  - Lo script riporta successo/fallimento
  - Lo snapshot è visibile in `info snapshots`

#### Step 1.2 — Listing e retention degli snapshot
- [x] Aggiungere al script la capacità di elencare gli snapshot esistenti
- [x] Usare `human-monitor-command` con `info snapshots` per ottenere la lista
  (oppure `query-named-block-nodes` → campo `snapshots` di tipo `SnapshotInfo[]`,
  che contiene `date-sec`, `date-nsec` per ogni snapshot)
- [x] Filtrare solo quelli con prefisso `autoprotect-`
- [x] Calcolare l'età: `now - date_sec` in ore
- [x] Per quelli oltre la soglia di retention (parametro `--retention-hours`),
  inviare `snapshot-delete`:
  ```json
  { "execute": "snapshot-delete",
    "arguments": {
      "job-id": "autodelete-<timestamp>",
      "tag": "<tag-vecchio>",
      "devices": ["<node-name>"]
    }
  }
  ```
- [x] Attendere completamento job di eliminazione
- **Criteri di accettazione:**
  - Con `--retention-hours 1`, gli snapshot più vecchi di 1 ora vengono eliminati
  - Gli snapshot manuali (senza prefisso `autoprotect-`) NON vengono toccati

#### Step 1.3 — Loop periodico e integrazione systemd
- [x] Aggiungere parametro `--interval-minutes N`
- [x] Due modalità di esecuzione:
  - **One-shot**: esegue un ciclo (snapshot + prune) ed esce (per cron/systemd timer)
  - **Daemon**: loop interno con `time.sleep(interval * 60)` (più semplice)
- [x] Creare `tools/autoprotect/autoprotect.service` (unit systemd timer)
- [x] Creare `tools/autoprotect/autoprotect.timer` (timer systemd)
- [x] Documentare nel README la configurazione
- **File:** `tools/autoprotect/autoprotect.py`, `tools/autoprotect/autoprotect.service`,
  `tools/autoprotect/autoprotect.timer`, `tools/autoprotect/README.md`
- **Criteri di accettazione:**
  - In modalità daemon, crea uno snapshot ogni N minuti
  - Elimina automaticamente quelli oltre la retention
  - Log leggibile su stdout/journal
  - Gestione graceful di SIGTERM/SIGINT

#### Step 1.4 — Robustezza e discovery
- [x] Auto-discovery del device vmstate via `query-named-block-nodes`
  (primo nodo che ha `"drv": "qcow2"` e supporta snapshot)
- [x] Gestione del caso "snapshot già in corso" (polling `query-jobs`)
- [x] Gestione del caso "disco pieno" (check spazio pre-snapshot)
- [x] Gestione del caso "QMP socket disconnesso" (retry con backoff)
- [x] Lock file per evitare istanze multiple
- **Criteri di accettazione:**
  - Lo script non crasha mai, logga errori e riprova
  - Su disco pieno, salta lo snapshot e logga warning

**Deliverable Fase 1:** Script Python funzionante, testato, documentato.
**Sforzo stimato:** 2-3 giorni.
**Limitazione nota:** La VM si blocca per tutta la durata del dump RAM (20-80+ secondi).

---

### FASE 2 — Modulo Interno QEMU: Schema QAPI (Strategia B, parte 1)
**Obiettivo:** Definire l'interfaccia QMP per AutoProtect e il boilerplate C.
**Stato:** ✅ Completata
**Prerequisiti:** Fase 1 completata (per avere esperienza operativa sul flusso)

#### Step 2.1 — Definizione schema QAPI
- [x] Creare `qapi/autoprotect.json` con:
  ```json
  { 'struct': 'AutoProtectConfig',
    'data': {
      'interval-seconds': 'int',
      'retention-hours': 'int',
      'vmstate': 'str',
      'devices': ['str'],
      '*name-prefix': 'str'
    }
  }

  { 'command': 'autoprotect-enable',
    'data': 'AutoProtectConfig',
    'boxed': true }

  { 'command': 'autoprotect-disable' }

  { 'command': 'autoprotect-status',
    'returns': 'AutoProtectInfo' }

  { 'struct': 'AutoProtectInfo',
    'data': {
      'enabled': 'bool',
      '*config': 'AutoProtectConfig',
      '*next-snapshot-seconds': 'int',
      '*last-snapshot-tag': 'str',
      '*snapshots-taken': 'int',
      '*snapshots-pruned': 'int'
    }
  }
  ```
- [x] Aggiungere include in `qapi/qapi-schema.json`:
  ```json
  { 'include': 'autoprotect.json' }
  ```
- [x] Verificare che `meson.build` generi i file QAPI
- **File:** `qapi/autoprotect.json`, `qapi/qapi-schema.json`, `qapi/meson.build`
- **Test:** `make` deve compilare senza errori; i file `qapi-types-autoprotect.*`
  e `qapi-commands-autoprotect.*` devono essere generati
- **Criteri di accettazione:**
  - Il progetto compila
  - I tipi C vengono generati correttamente

#### Step 2.2 — Stub delle implementazioni C
- [x] Creare `include/migration/autoprotect.h`:
  ```c
  #ifndef QEMU_MIGRATION_AUTOPROTECT_H
  #define QEMU_MIGRATION_AUTOPROTECT_H

  #include "qapi/qapi-types-autoprotect.h"

  void autoprotect_init(void);
  void autoprotect_cleanup(void);

  #endif
  ```
- [x] Creare `migration/autoprotect.c` con stub:
  ```c
  void qmp_autoprotect_enable(AutoProtectConfig *config, Error **errp)
  {
      error_setg(errp, "AutoProtect not yet implemented (Phase 2 stub)");
  }

  void qmp_autoprotect_disable(Error **errp)
  {
      error_setg(errp, "AutoProtect not yet implemented (Phase 2 stub)");
  }

  AutoProtectInfo *qmp_autoprotect_status(Error **errp)
  {
      AutoProtectInfo *info = g_new0(AutoProtectInfo, 1);
      info->enabled = false;
      return info;
  }
  ```
- [x] Aggiungere `autoprotect.c` a `migration/meson.build`
- [x] Verificare compilazione e linking
- **File:** `include/migration/autoprotect.h`, `migration/autoprotect.c`, `migration/meson.build`
- **Criteri di accettazione:**
  - `ninja -C build qemu-system-x86_64` compila e linka senza errori
  - Da QMP: `{ "execute": "autoprotect-status" }` ritorna `{ "enabled": false }`
  - Da QMP: `autoprotect-enable` e `autoprotect-disable` rispondono con messaggio di stub

**Deliverable Fase 2:** Schema QAPI + stub C compilabili. Comandi QMP rispondono.
**Sforzo stimato:** 1-2 giorni.

---

#### FASE 3 — Modulo Interno QEMU: Logica Timer + Snapshot (Strategia B, parte 2)
**Obiettivo:** Implementare il timer periodico e la logica di snapshot/prune.
**Stato:** ✅ Completata
**Prerequisiti:** Fase 2 completata

#### Step 3.1 — Struttura stato e timer
- [x] Definire in `migration/autoprotect.c` la struttura stato:
  ```c
  typedef struct AutoProtectState {
      bool enabled;
      int64_t interval_ms;
      int64_t retention_ms;        /* retention_hours * 3600 * 1000 */
      char *vmstate_node;
      bool has_devices;
      strList *devices;
      char *name_prefix;
      QEMUTimer *timer;
      uint64_t snapshot_counter;
      uint64_t snapshots_taken;
      uint64_t snapshots_pruned;
      char *last_snapshot_tag;
      int64_t next_snapshot_time_ms;
      bool snapshot_in_progress;
  } AutoProtectState;

  static AutoProtectState autoprotect_state;
  ```
- [x] Implementare `qmp_autoprotect_enable()`:
  1. Validare parametri (interval > 0, retention > 0, devices/vmstate)
  2. Verificare `bdrv_all_can_snapshot()` sui dispositivi indicati
  3. Popolare `autoprotect_state`
  4. Creare timer: `timer_new_ms(QEMU_CLOCK_REALTIME, autoprotect_timer_cb, &autoprotect_state)`
  5. Armare timer: `timer_mod(timer, qemu_clock_get_ms(...) + interval_ms)`
- [x] Implementare `qmp_autoprotect_disable()`:
  1. `timer_del(timer)` + `timer_free(timer)`
  2. Reset stato
- [x] Implementare `qmp_autoprotect_status()`:
  1. Popolare e ritornare `AutoProtectInfo`
- **File:** `migration/autoprotect.c`
- **Test:** Abilitare via QMP, verificare che `autoprotect-status` riporti stato corretto.
- **Criteri di accettazione:**
  - `autoprotect-enable` con parametri validi non ritorna errore
  - `autoprotect-status` riporta `enabled: true` e configurazione
  - `autoprotect-disable` resetta lo stato

#### Step 3.2 — Timer callback: creazione snapshot
- [x] Implementare `autoprotect_timer_cb()`:
  - Verifica se la VM è in stato running (`runstate_is_running()`)
  - Gestione snapshot in corso con retry dopo 5 secondi
  - Generazione automatica tag con timestamp: `<prefix>YYYYMMDD-HHMMSS`
  - Invocazione di `save_snapshot()` sincrona (RAM + dischi)
  - Notifica tramite `info_report()`
  - Re-arm automatico del timer periodico
- **Criteri di accettazione:**
  - Dopo aver abilitato AutoProtect, ad ogni intervallo viene creato uno snapshot
  - Gli snapshot hanno nomi sequenziali basati su timestamp
  - `autoprotect-status` mostra `snapshots-taken` incrementale

#### Step 3.3 — Pruning automatico degli snapshot vecchi
- [x] Dopo ogni snapshot riuscito, invocare `autoprotect_prune()`:
  - Recupero lista snapshot tramite `bdrv_snapshot_list()` dal nodo vmstate
  - Filtraggio per prefisso configurato (default `autoprotect-`)
  - Calcolo dell'età: `now - date_sec`
  - Eliminazione degli snapshot scaduti tramite `delete_snapshot()`
  - Salvaguardia totale di tutti gli snapshot manuali dell'utente
- **Criteri di accettazione:**
  - Gli snapshot più vecchi della retention vengono eliminati
  - Solo gli snapshot con prefisso AutoProtect vengono eliminati
  - Gli snapshot manuali dell'utente non vengono toccati

#### Step 3.4 — Comandi HMP
- [x] Aggiungere comandi HMP in `migration/migration-hmp-cmds.c`:
  - `autoprotect on [interval-sec] [retention-hours] [prefix] [vmstate]`
  - `autoprotect off`
  - `info autoprotect`
- [x] Dichiarare in `include/monitor/hmp.h`
- [x] Registrare in `hmp-commands.hx` e `hmp-commands-info.hx`
- **Criteri di accettazione:**
  - Dal monitor HMP si può abilitare/disabilitare/controllare AutoProtect

**Deliverable Fase 3:** Modulo AutoProtect funzionante con snapshot periodici e pruning.
**Sforzo stimato:** 1-2 settimane.
**Limitazione nota:** La VM si blocca durante ogni snapshot (stessa limitazione di `savevm`).

---

### FASE 4 — Snapshot Non-Blocking (Strategia C)
**Obiettivo:** Eliminare il blocco della VM usando background-snapshot + external overlay.
**Stato:** ✅ Completata
**Prerequisiti:** Fase 3 completata, kernel Linux ≥ 5.7

> ⚠️ Questa è la fase più complessa. Richiede coordinamento tra 3 sottosistemi.

#### Step 4.1 — Snapshot disco live (external overlay)
- [x] Nel callback del timer, gestione duale:
  1. Generare nome overlay: `<storage-dir>/<tag>-disk-<name>.qcow2`
  2. Per ogni disco rilevato (o specificato in `devices`/`vmstate`):
     ```c
     qmp_blockdev_snapshot_sync(device, node_name, overlay, NULL,
                                "qcow2", false, 0, &err);
     ```
  3. Crea un overlay COW istantaneo (~ms) senza pause per la VM
- [x] Gestire il naming e la directory degli overlay tramite `storage-dir`
- **Criteri di accettazione:**
  - L'overlay viene creato in ~ms
  - La VM non si blocca
  - I dati precedenti al momento dello snapshot sono preservati nel backing file

#### Step 4.2 — Salvataggio RAM in background
- [x] Salvataggio della RAM via migrazione a file con background snapshot:
  1. Abilitare capability: `ms->capabilities[MIGRATION_CAPABILITY_BACKGROUND_SNAPSHOT] = true`
  2. Avviare migrazione asincrona a file: `qmp_migrate("file:<dir>/<tag>-ram.state", ...)`
  3. La VM subisce solo un micro-stun (tempo di attivare UFFD-WP), poi continua senza blocco
  4. La memoria RAM viene scritta in background su file
- [x] Coordinamento con overlay disco (prima overlay COW istantaneo, poi background snapshot RAM)
- **Criteri di accettazione:**
  - La combinazione overlay + bg-migrate cattura stato completo
  - La VM non si blocca mai per più di pochi millisecondi
  - I file di stato RAM vengono scritti correttamente

#### Step 4.3 — Consolidamento e tracciamento overlay
- [x] Tracciamento degli snapshot live attivi in memoria (`AutoProtectLiveEntry`)
- [x] Registrazione del percorso file RAM e degli overlay creati
- **Criteri di accettazione:**
  - Tutti i file collegati allo snapshot sono tracciati con timestamp
  - Possibilità di gestire la retention granulare

#### Step 4.4 — Pruning file e snapshot state
- [x] Implementare pulizia dei file RAM/overlay scaduti (`autoprotect_prune_live`):
  - Verifica della retention time impostata
  - Unlink dei file di stato RAM scaduti
  - Deallocazione delle strutture di tracciamento
- [x] Notifica informativa tramite `info_report()`
- **Criteri di accettazione:**
  - I file vecchi vengono eliminati dopo la retention
  - `snapshots_pruned` viene aggiornato in `autoprotect-status`

#### Step 4.5 — Integrazione e modalità ibrida
- [x] Aggiunto tipo `AutoProtectMode` (`auto`, `internal`, `live`) allo schema QAPI:
  ```json
  { 'enum': 'AutoProtectMode',
    'data': [ 'auto', 'internal', 'live' ] }
  ```
- [x] `internal`: snapshot qcow2 sincrono (compatibile ovunque)
- [x] `live`: snapshot non-blocking (richiede kernel UFFD-WP)
- [x] `auto`: fallback intelligente — seleziona `live` se `ram_write_tracking_available()` è true, altrimenti `internal`
- [x] Errore esplicito se l'utente richiede `live` su kernel senza supporto UFFD-WP
- [x] Aggiornati comandi HMP `autoprotect` e `info autoprotect` con argomenti `mode` e `dir`
- **Criteri di accettazione:**
  - L'utente può scegliere la modalità preferita
  - Se UFFD non è disponibile e si richiede `live`, ritorna errore chiaro
  - In `auto`, seleziona la modalità ottimale automaticamente

**Deliverable Fase 4:** AutoProtect non-blocking completo con fallback automatico e tracciamento retention.
**Sforzo completato:** Fase completata e verificata.

---

### FASE 5 — Hardening, Test e Documentazione
**Obiettivo:** Rendere il modulo robusto e ben documentato.
**Stato:** ✅ Completata

#### Step 5.1 — Test automatizzati
- [x] Test QMP via framework test QEMU (`tests/qtest/autoprotect-test.c`)
- [x] Registrazione in `tests/qtest/meson.build` (`qtests_generic`)
- [x] Test di validazione parametri non validi (intervallo o retention negativi o nulli)
- [x] Test ciclo di vita completo (abilitazione, verifica configurazione attiva, disabilitazione)
- [x] Test comandi monitor HMP (`autoprotect on/off`, `info autoprotect`)
- [x] Test avvio con parametro da riga di comando (`-autoprotect`)
- **Criteri di accettazione:**
  - Tutti i 5 test eseguiti e superati al 100% via TAP test runner

#### Step 5.2 — Documentazione
- [x] Creazione di `docs/interop/autoprotect.rst` conforme agli standard Sphinx di QEMU
- [x] Registrazione nel toctree di `docs/interop/index.rst`
- [x] Documentazione dettagliata di comandi QMP (`autoprotect-enable`, `autoprotect-disable`, `autoprotect-status`)
- [x] Documentazione di comandi HMP (`autoprotect`, `info autoprotect`)
- [x] Documentazione opzione CLI `-autoprotect`
- [x] Sezione Troubleshooting e specifiche tecniche (kernel UFFD-WP >= 5.7, compatibilità formati)
- **Criteri di accettazione:**
  - `ninja -C build docs/docs.stamp` genera la documentazione HTML senza errori né warning

#### Step 5.3 — Opzione CLI e Avvio VM pre-configurata
- [x] Aggiunta opzione `-autoprotect interval=SEC,retention=HOURS[,mode=auto|internal|live][,prefix=PREFIX][,dir=DIR]`
- [x] Registrazione in `qemu-options.hx` con manuale rST
- [x] Parsing keyval in `migration/autoprotect.c` (`autoprotect_parse_cmdline`) con supporto alias facili (`interval`, `retention`, `dir`, `prefix`)
- [x] Avvio automatico post-creazione macchina in `system/vl.c` (`autoprotect_start_cmdline`)
- [x] Creati script `autoprotect_start.sh` (avvio VM con 3GB RAM, snapshot ogni 60s, retention 1h) e `autoprotect_stop.sh` (arresto graceful tramite PID)
- [x] `autoprotect_start.sh` vincolato tassativamente al binario compilato localmente (`./build/qemu-system-x86_64`), senza alcun fallback alla versione di sistema
- **Criteri di accettazione:**
  - La VM può essere avviata specificando frequenza e retention direttamente da CLI o tramite script helper
  - `autoprotect_start.sh` accetta il file qcow2 e avvia la VM con 3GB RAM e snapshot al minuto con retention di 1h
  - Il binario QEMU eseguito è esclusivamente quello compilato nel workspace locale (`build/qemu-system-x86_64`)

**Deliverable Fase 5:** Modulo production-ready completo di test automatici, documentazione ufficiale, supporto CLI e script di gestione.
**Sforzo completato:** Fase completata e verificata.

---

### FASE 6 — Live Delta Non-Blocking, Night Prune, Ripristino e Bridge eth0 ✅ COMPLETATA
**Obiettivo:** Eliminare completamente qualsiasi percezione di blocco della VM durante lo snapshot periodico, salvare i delta nella cartella del qcow2, schedulare il pruning solo di notte, fornire uno script per listing/ripristino snapshot e collegare la VM alla LAN fisica via bridge su `eth0`.
**Stato:** ✅ Completata

#### Step 6.1 — Delta Storage e RAM nella cartella del qcow2 (senza blocco guest)
- [x] Auto-rilevamento directory di base (`autoprotect_detect_base_dir` con `g_canonicalize_filename`) per collocare overlay disco e dump RAM direttamente a fianco del file qcow2 specificato.
- [x] Salvataggio storage live: creazione overlay delta copy-on-write tramite `qmp_blockdev_snapshot_sync` a runtime senza fermare la VM.
- [x] Salvataggio RAM asincrono: micro-pausa (<3ms) per catturare i registri hardware/device state (`qmp_xen_save_devices_state`), applicazione di `MADV_DOFORK` sui RAMBlocks migrabili, `fork()` istantaneo di un processo figlio per il dump asincrono su file `.state` a blocchi da 4MB, ripristino immediato della VM nel processo genitore con `vm_start()` e ripristino del flag di sicurezza `MADV_DONTFORK`. La VM riprende in pochi millisecondi senza blocco percettibile.

#### Step 6.2 — Scheduling cancellazione notturna (`night-prune`)
- [x] Aggiunto parametro `night-prune` nello schema QAPI (`qapi/autoprotect.json`), CLI (`-autoprotect night-prune=on`), e monitor HMP.
- [x] Funzione `autoprotect_is_night_time()` che controlla l'orario locale (ore 23:00 - 06:00).
- [x] Durante le ore diurne (06:00 - 22:59), la cancellazione degli snapshot scaduti viene posticipata per evitare contese I/O; allo scoccare delle ore notturne, il timer periodico effettua la pulizia massiva di tutti gli snapshot oltre la retention.

#### Step 6.3 — Script di supporto per elenco e ripristino snapshot (`autoprotect_restore.sh`)
- [x] Script interattivo e a riga di comando `autoprotect_restore.sh <file.qcow2> [--list] [--snapshot <tag|num>]`.
- [x] Rilevamento automatico sia di snapshot live delta esterni (`*-disk-*.qcow2`, `*-ram.state`) sia di snapshot interni qcow2 (`qemu-img snapshot -l`).
- [x] Tabella formattata con numero progressivo, tag, tipologia, data/ora e dimensione RAM/overlay.
- [x] Selezione ed esecuzione dello snapshot scelto:
  - Per snapshot live delta: avvio della VM tramite `build/qemu-system-x86_64` con opzione di overlay di sicurezza per non alterare lo snapshot storico.
  - Per snapshot interni: avvio con `-loadvm <tag>` (ripristino memoria e CPU) o ripristino del disco con `qemu-img snapshot -a <tag>`.

#### Step 6.4 — Connessione di rete in bridge su `eth0`
- [x] Creato script helper `setup_bridge.sh` per configurare rapidamente `macvtap0` su `eth0` in modalità bridge (o Linux bridge `br0`) con permessi appropriati per utente non-root.
- [x] Aggiornato `autoprotect_start.sh` con supporto a rete bridged (`macvtap0` su `eth0` o bridge Linux `br0`), MAC address personalizzato o persistente, supporto `--night-prune` e fallback trasparente a user mode se il bridge non è ancora presente.
- [x] La VM ottiene un indirizzo IP indipendente direttamente dal server DHCP della rete LAN fisica.

---

### Vincolo Risoluzione Binari e Tool QEMU ✅
Per garantire che vengano impiegate esclusivamente le versioni compilate nel workspace o installate in `/opt/qemu` (e mai le versioni di sistema `/usr/bin/qemu*` o `/usr/lib/qemu/*`), tutti gli script adottano la seguente catena di risoluzione:
1. **Tree Locale Compilato**: cerca i binari in `./build/` (es. `./build/qemu-system-x86_64`, `./build/qemu-img`, `./build/qemu-bridge-helper`);
2. **Installazione locale `/opt/qemu`**: se non presenti nel tree di build, cerca in `/opt/qemu/bin/` e `/opt/qemu/libexec/`;
3. **Nessun fallback su `/usr/`**: se il binario non è presente in nessuna delle due sedi, lo script termina con errore esplicito e indicazioni di compilazione.

- Script aggiornati con la logica di fallback locale -> `/opt/qemu`:
  - `autoprotect_start.sh`: binario QEMU (`build/qemu-system-x86_64` o `/opt/qemu/bin/qemu-system-x86_64`) e helper bridge (`build/qemu-bridge-helper` o `/opt/qemu/libexec/qemu-bridge-helper`).
  - `autoprotect_restore.sh`: `get_qemu_bin()`, `get_qemu_img()`, `get_bridge_helper()`.
  - `setup_bridge.sh`: target SUID configurati su `build/qemu-bridge-helper` e `/opt/qemu/libexec/qemu-bridge-helper`.
  - `qemu_env.sh`: script sourceable (`source qemu_env.sh`) che esporta `PATH` prioritizzando `./build` e `/opt/qemu/bin`.

---

### Garanzia di Boot dall'Ultimo Snapshot / Scrittura ✅

#### Il Principio di Funzionamento della Catena Qcow2
Durante l'esecuzione con AutoProtect (`mode=live`), ogni minuto viene creato un nuovo file overlay delta:
```
Base (Win10.qcow2)
       ▲
       └── autoprotect-01-disk.qcow2 (backing: Win10.qcow2)
                 ▲
                 └── autoprotect-02-disk.qcow2 (backing: autoprotect-01-disk.qcow2)
                           ▲
                           └── autoprotect-N-disk.qcow2 [FOGLIA ATTIVA / SCRITTURE IN CORSO]
```
1. Tutte le scritture eseguite dal guest (NTFS, registro, file creati) vengono scritte esclusivamente nella **foglia attiva** (`autoprotect-N`).
2. I file sottostanti della catena diventano `backing file` in sola lettura.
3. Se al riavvio venisse passato a QEMU il file base `Win10.qcow2`, la VM partirebbe dallo stato storico iniziale, perdendo la visibilità delle modifiche.
4. Se al riavvio viene invece passato il file della **foglia attiva** (`autoprotect-N`), QEMU legge i cluster risalendo l'intera catena di backing: **il guest vede il 100% delle modifiche fino all'ultimo secondo prima dello shutdown!**
5. Al primo snapshot del nuovo avvio, AutoProtect crea un nuovo overlay `autoprotect-N+1` con backing impostato su `autoprotect-N`, proseguendo la catena in modo continuo e naturale.

#### Componenti Implementati:
- **`autoprotect_find_leaf.py`**:
  - Scansiona la directory del disco target;
  - Tramite `qemu-img info --output=json` analizza i collegamenti `backing-filename`;
  - Ricostruisce il DAG e individua la foglia attiva (overlay non referenziato come backing da nessun altro file, con `mtime` più recente);
  - Supporta output JSON completo (`--json`), forzatura base (`--base`) e selezione snapshot specifico (`--snapshot <tag>`).
- **`autoprotect_start.sh`**:
  - Di default risolve la foglia attiva e avvia QEMU con `-drive file=${boot_disk},format=qcow2,if=virtio`;
  - Fornisce output diagnostico che certifica all'utente l'avvio dall'ultimo stato/scrittura con il conteggio degli snapshot nella catena;
  - Flag `--base`: forza il boot dal file base ignorando gli snapshot delta;
  - Flag `--snapshot <tag>`: avvia da uno snapshot intermedio specificato;
  - Flag `--dry-run`: mostra il comando QEMU e i parametri senza avviare il processo.
- **`autoprotect_restore.sh`**:
  - Rileva la foglia attiva tramite `autoprotect_find_leaf.py` e la evidenzia chiaramente con il marker `[ATTIVO]` nella tabella degli snapshot disponibili.

---

### Connettività Bridge LAN e Rete di Gestione Host SSH ✅

#### 1. Causa della Connessione "Giù" su Macvtap e Risoluzione MAC Mismatch
- **Problema identificato:** Quando `setup_bridge.sh` crea l'interfaccia `macvtap0` su `eth0`, il kernel Linux le assegna un indirizzo MAC hardware (es. `fe:7e:97:7f:d6:ed`). Se QEMU avvia la scheda `virtio-net-pci` con un MAC diverso (es. il predefinito `52:54:00:12:34:56`), il driver kernel macvlan/macvtap applica un filtro hardware Layer 2 e scarta silenziosamente tutti i pacchetti unicast in arrivo (comprese le risposte DHCP Offer/Ack del router fisico). Di conseguenza la scheda nel guest non ottiene l'indirizzo IP e rimane nello stato down / no carrier.
- **Risoluzione:** `autoprotect_start.sh` e `autoprotect_restore.sh` leggono dinamicamente l'indirizzo MAC effettivo da `/sys/class/net/macvtap0/address` e lo assegnano alla scheda `virtio-net-pci` di QEMU. Il router fisico vede il MAC corretto, rilascia la lease DHCP (es. `172.16.5.142/23`) e la connettività LAN/Internet è pienamente operativa.

#### 2. Isolamento Host-to-Guest di Macvtap e Soluzione SSH Management
- **Architettura Macvtap:** Per design di sicurezza del kernel Linux, il sistema host non può comunicare direttamente con le proprie interfacce macvlan/macvtap residenti sulla stessa scheda fisica (`eth0`). Pertanto l'host non può raggiungere direttamente l'IP LAN del guest o eseguire port forwarding sulla scheda macvtap.
- **Scheda di Gestione Integrata (`net_mgmt`):** Per consentire l'accesso SSH istantaneo dall'host (`ssh -p 10022 gelma@localhost`), `autoprotect_start.sh` include automaticamente una seconda interfaccia virtio:
  ```bash
  -netdev user,id=net_mgmt,restrict=on,hostfwd=tcp::10022-:22 -device virtio-net-pci,netdev=net_mgmt
  ```
  - `hostfwd=tcp::10022-:22`: mappa la porta 10022 di `127.0.0.1` sulla porta 22 (SSH) della VM;
  - `restrict=on`: isola la scheda utente dal traffico internet esterno, garantendo che tutto il traffico LAN/Internet della VM continui a fluire prioritariamente attraverso il bridge fisico `eth0` (default route su gateway `172.16.4.1`).
- Opzioni disponibili:
  - `--ssh [porta]`: personalizza la porta (default: 10022);
  - `--no-ssh`: disabilita la scheda di gestione se non necessaria.

---

### Guida Operativa Rapida ed Esempi di Utilizzo ✅

#### 1. Configurazione Iniziale Rete Bridge (Una Tantum)
Per collegare la VM direttamente alla LAN fisica su `eth0` come dispositivo autonomo (con proprio IP assegnato via DHCP dal router):

```bash
# Configura macvtap0 su eth0 e imposta i permessi corretti per utente non-root
sudo ./setup_bridge.sh macvtap eth0

# Verifica dello stato delle interfacce e del dispositivo /dev/tapX
./setup_bridge.sh status eth0
```

---

#### 2. Avvio della Macchina Virtuale con AutoProtect (`autoprotect_start.sh`)

##### A) Avvio Standard (Predefinito con Garanzia Ultimo Stato/Scrittura)
Avvia la VM con 3GB di RAM, abilitando snapshot live non-blocking ogni 60 secondi con retention di 1 ora:
```bash
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2
```
- **Garanzia automatica:** Rileva in autonomia l'overlay foglia (`autoprotect-N-disk-virtio0.qcow2`) e riparte dall'ultimo secondo in cui la macchina ha scritto;
- **Rete LAN:** Connessa direttamente al router tramite `macvtap0` su `eth0` con MAC sincronizzato;
- **Rete Gestione Host:** Porta SSH `127.0.0.1:10022` aperta e pronta all'uso.

##### B) Avvio con Cancellazione Notturna Differita (`--night-prune`)
Posticipa il pruning (eliminazione file snapshot scaduti oltre l'ora) alla fascia notturna (23:00 - 06:00), per azzerare qualsiasi carico di I/O disco durante il giorno:
```bash
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --night-prune
```

##### C) Verifica del Comando senza Avviare la VM (`--dry-run`)
Mostra a terminale l'ispezione della catena, la foglia rilevata e l'esatto comando QEMU generato:
```bash
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --dry-run
```

##### D) Avvio Forzato dal Disco Base Originale (`--base`)
Se desideri ripartire pulito dal disco base originale ignorando tutti gli snapshot delta accumulati:
```bash
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --base
```

##### E) Avvio Diretto da uno Snapshot Storico Specifico (`--snapshot`)
Per avviare la VM da un punto temporale precedente nella catena di delta:
```bash
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --snapshot autoprotect-20261006-171013
```

##### F) Personalizzazione Porta SSH Host o Disabilitazione
```bash
# Cambia la porta SSH locale (es. 2222)
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --ssh 2222

# Disabilita l'interfaccia di gestione locale (solo connessione bridged fisica LAN)
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --no-ssh
```

---

#### 3. Accesso alla VM Guest dall'Host

##### Accesso tramite SSH (Porta 10022)
```bash
# Connessione immediata tramite la porta di gestione locale
ssh -p 10022 gelma@localhost
# Password predefinita utente guest: p
```

##### Accesso Diretto tramite IP Fisico LAN
La VM ottiene un indirizzo IP indipendente sulla stessa sottorete dell'host (es. `172.16.5.142`):
```bash
ssh gelma@172.16.5.142
```

##### Accesso Grafico (GUI)
La finestra display QEMU si apre automaticamente sul desktop grafico dell'host (`DISPLAY=:0.0`).

---

#### 4. Gestione, Elenco e Selezione Snapshot (`autoprotect_restore.sh`)

##### A) Visualizzare l'Elenco degli Snapshot Disponibili
Mostra una tabella riassuntiva con data, ora, dimensione RAM e l'indicatore `[ATTIVO]` sulla foglia corrente:
```bash
./autoprotect_restore.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --list
```
*Esempio output:*
```
==========================================================================================
NUM  | TAG SNAPSHOT                 | TIPO                | DATA E ORA          | STATO RAM 
-----+------------------------------+---------------------+---------------------+------------
1    | autoprotect-20261006-170113  | Live Delta          | 2026-10-06 19:02:11 | 3.02 GB   
...
32   | autoprotect-20261006-171714  | Live Delta [ATTIVO] | 2026-10-06 19:17:34 | 3.02 GB   
==========================================================================================
```

##### B) Ripristino Interattivo Guidato
Eseguendo lo script senza parametri opzionali, viene mostrata la lista e richiesto il numero o tag da ripristinare:
```bash
./autoprotect_restore.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2
```
- Consente di creare un overlay di sicurezza di sessione per non alterare lo snapshot storico durante i test.

##### C) Ripristino Diretto a Riga di Comando
```bash
# Per numero progressivo:
./autoprotect_restore.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --snapshot 15

# Per tag temporale:
./autoprotect_restore.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --snapshot autoprotect-20261006-171013
```

---

#### 5. Arresto Pulito della VM (`autoprotect_stop.sh`)
Arresta la macchina virtuale in modo pulito inviando `SIGTERM` tramite il file PID registrato, eseguendo il flush completo di tutti i buffer disco qcow2:
```bash
./autoprotect_stop.sh
```

---

#### 6. Consolidamento Scritture nel Disco Base ed Eliminazione Snapshot (`autoprotect_consolidate.sh` / `autoprotect_commit.sh`)

Consolida permanentemente tutte le modifiche e scritture accumulate negli snapshot delta (`autoprotect-*-disk-virtio0.qcow2`) all'interno dell'immagine originaria di base (es. `disk0.qcow2`), portando il disco di partenza allo stato identico dell'ultima scrittura e rimuovendo in sicurezza tutti i file overlay e gli stati RAM/dispositivi per liberare spazio su disco.

##### Caratteristiche e Garanzie:
- **Zero perdite:** Esegue il commit dell'intera catena di delta a ritroso fino al disco base specificato (`qemu-img commit -b <base_image> -p <active_leaf>`);
- **Sicurezza:** Verifica che la VM QEMU non sia attiva (controllo PID e lock qemu) prima di procedere, impedendo qualsiasi corruzione;
- **Pulizia completa:** Rimuove tutti i file delta `.qcow2`, dump RAM `.state` e registri device `.state` associati agli snapshot, liberando decine di GB di spazio;
- **Interscambiabile:** Utilizzabile tramite `./autoprotect_consolidate.sh`, tramite il symlink `./autoprotect_commit.sh`, tramite opzione `./autoprotect_restore.sh --consolidate`, oppure premendo `c` dal menu interattivo di ripristino.

##### Esempi d'Uso:

```bash
# 1. Simulazione a vuoto (Dry-Run): elenca i file e stima lo spazio liberabile senza toccare nulla
./autoprotect_consolidate.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --dry-run

# 2. Consolidamento interattivo (chiede conferma esplicita prima di committare ed eliminare)
./autoprotect_consolidate.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2

# 3. Consolidamento automatico senza prompt (per script o cron notturni)
./autoprotect_consolidate.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 -y

# 4. Consolidamento mantenendo i file delta di backup (senza cancellarli)
./autoprotect_consolidate.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --keep-snapshots

# 5. Esecuzione tramite script di ripristino
./autoprotect_restore.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --consolidate
```

##### Esempio di Output a Terminale (Dry-Run):
```text
==========================================================================
           CONSOLIDAMENTO SNAPSHOT AUTOPROTECT NEL DISCO BASE
==========================================================================
Disco base di destinazione:  /mnt/bidone-sda8/super_protezione/disk0.qcow2
Foglia attiva (ultimi dati): autoprotect-20261006-171714-disk-virtio0.qcow2
Numero di snapshot nella catena: 32 (profondità: 32)

Dettaglio file da eliminare dopo il commit:
  - File delta qcow2:        32 file (111.06 MB)
  - File di stato RAM/dev:   64 file (96.53 GB)
Spazio disco stimato liberabile: 96.64 GB
==========================================================================

[DRY RUN] Comando che verrebbe eseguito per il commit:
  /opt/qemu/bin/qemu-img commit -b "/mnt/bidone-sda8/super_protezione/disk0.qcow2" -p "/mnt/bidone-sda8/super_protezione/autoprotect-20261006-171714-disk-virtio0.qcow2"

[DRY RUN] File che verrebbero rimossi:
  - /mnt/bidone-sda8/super_protezione/autoprotect-20261006-164531-disk-virtio0.qcow2
  ... (32 file delta qcow2)
  - /mnt/bidone-sda8/super_protezione/autoprotect-20261006-164531-ram.state
  ... (64 file di stato)

[DRY RUN] Simulazione completata. Nessuna modifica apportata ai file.
```

##### Esempio di Output a Terminale (Consolidamento Effettivo):
```text
==========================================================================
           CONSOLIDAMENTO SNAPSHOT AUTOPROTECT NEL DISCO BASE
==========================================================================
Disco base di destinazione:  /mnt/bidone-sda8/super_protezione/disk0.qcow2
Foglia attiva (ultimi dati): autoprotect-20261006-171714-disk-virtio0.qcow2
Numero di snapshot nella catena: 32 (profondità: 32)

Dettaglio file da eliminare dopo il commit:
  - File delta qcow2:        32 file (111.06 MB)
  - File di stato RAM/dev:   64 file (96.53 GB)
Spazio disco stimato liberabile: 96.64 GB
==========================================================================

ATTENZIONE: Questa operazione scriverà permanentemente tutte le modifiche
della catena nel file '/mnt/bidone-sda8/super_protezione/disk0.qcow2' e cancellerà tutti gli snapshot intermedi.
Procedere con il consolidamento? [s/N]: s

[1/3] Consolidamento scritture in corso con qemu-img commit...
Image committed.
[2/3] Rimozione file delta qcow2 (32 file)...
[3/3] Rimozione file di stato RAM/dispositivi (64 file)...

==========================================================================
CONSOLIDAMENTO COMPLETATO CON SUCCESSO!
- Tutte le scritture fino all'ultimo stato sono ora salvate in:
  /mnt/bidone-sda8/super_protezione/disk0.qcow2
- Gli snapshot delta sono stati rimossi e lo spazio su disco è stato liberato.
- Il file base può ora essere riavviato normalmente come disco unico.
==========================================================================
```

##### Workflow Operativo Tipico:
```bash
# Passo 1: Spegnere la VM (obbligatorio prima del consolidamento per evitare scritture concorrenti)
./autoprotect_stop.sh

# Passo 2: Verificare in sicurezza i file e lo spazio disco stimato da recuperare
./autoprotect_consolidate.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2 --dry-run

# Passo 3: Eseguire il consolidamento delle scritture ed eliminare gli snapshot
./autoprotect_consolidate.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2

# Passo 4: Riavviare la VM dal disco base consolidato (ripartirà un nuovo ciclo di autoprotect pulito)
./autoprotect_start.sh /mnt/bidone-sda8/super_protezione/disk0.qcow2
```

---

## Riepilogo Progressione

```
FASE 0 ✅   FASE 1 ✅   FASE 2 ✅   FASE 3 ✅   FASE 4 ✅   FASE 5 ✅   FASE 6 ✅   FASE 7 ✅
Analisi     Script      QAPI +      Timer +     Live       Hardening & Live Delta, Consolidamento
            esterno     Stub C      Snapshot    (non-block) Test, Docs, Night-Prune, & Commit Disco
            QMP                     + Prune                 CLI Option  Restore & Bridge (Zero Snapshot)
            ────────────────────────────────────────────────────────────────────────────────────────►
            Zero                    Media                  Alta         Non-blocking Libera Spazio
            invasività              invasività             invasività   Zero freeze  100% all'ultimo
            VM blocca               VM blocca              VM NON blocca VM LAN Bridge stato base
```

## Note Importanti
- La policy QEMU (`AGENTS.md`, `docs/devel/code-provenance.rst`) vieta codice AI
  in contributi upstream. Tutto il codice generato è per uso locale/sperimentale.
- `background-snapshot` è una capability sperimentale (`x-background-snapshot`).
- Prima di ogni sessione futura: **rileggere questo file** per riprendere dal punto giusto.
- I numeri di riga possono cambiare se il codebase viene aggiornato (`git pull`).
  In tal caso, cercare per nome funzione.
- Formattazione schema QAPI: i titoli di sezione nei commenti liberi devono usare intestazioni
  di livello 2 con asterischi (`*` sopra e sotto), poiché il livello 1 (`=`) è riservato
  al titolo principale del manuale Sphinx (`docs/devel/qapi-code-gen.rst`).
