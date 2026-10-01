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
- **Criteri di accettazione:**
  - La VM può essere avviata specificando frequenza e retention direttamente da CLI o tramite script helper
  - `autoprotect_start.sh` accetta il file qcow2 e avvia la VM con 3GB RAM e snapshot al minuto con retention di 1h

**Deliverable Fase 5:** Modulo production-ready completo di test automatici, documentazione ufficiale, supporto CLI e script di gestione.
**Sforzo completato:** Fase completata e verificata.

---

## Riepilogo Progressione

```
FASE 0 ✅   FASE 1 ✅   FASE 2 ✅   FASE 3 ✅   FASE 4 ✅   FASE 5 ✅
Analisi     Script      QAPI +      Timer +     Live       Hardening &
            esterno     Stub C      Snapshot    (non-block) Test, Docs,
            QMP                     + Prune                 CLI Option
            ────────────────────────────────────────────────────────►
            Zero                    Media                  Alta
            invasività              invasività             invasività
            VM blocca               VM blocca              VM NON blocca
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
