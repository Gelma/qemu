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
**Stato:** ⬜ Da fare
**Prerequisiti:** Fase 1 completata (per avere esperienza operativa sul flusso)

#### Step 2.1 — Definizione schema QAPI
- [ ] Creare `qapi/autoprotect.json` con:
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
    'data': 'AutoProtectConfig' }

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
- [ ] Aggiungere include in `qapi/qapi-schema.json`:
  ```json
  { 'include': 'autoprotect.json' }
  ```
- [ ] Verificare che `meson.build` generi i file QAPI
- **File:** `qapi/autoprotect.json`, `qapi/qapi-schema.json`
- **Test:** `make` deve compilare senza errori; i file `qapi-types-autoprotect.*`
  e `qapi-commands-autoprotect.*` devono essere generati
- **Criteri di accettazione:**
  - Il progetto compila
  - I tipi C vengono generati correttamente

#### Step 2.2 — Stub delle implementazioni C
- [ ] Creare `migration/autoprotect.h`:
  ```c
  #ifndef QEMU_AUTOPROTECT_H
  #define QEMU_AUTOPROTECT_H

  #include "qapi/qapi-types-autoprotect.h"

  void autoprotect_init(void);
  void autoprotect_cleanup(void);

  #endif
  ```
- [ ] Creare `migration/autoprotect.c` con stub:
  ```c
  void qmp_autoprotect_enable(AutoProtectConfig *config, Error **errp)
  {
      error_setg(errp, "AutoProtect not yet implemented");
  }

  void qmp_autoprotect_disable(Error **errp)
  {
      error_setg(errp, "AutoProtect not yet implemented");
  }

  AutoProtectInfo *qmp_autoprotect_status(Error **errp)
  {
      AutoProtectInfo *info = g_new0(AutoProtectInfo, 1);
      info->enabled = false;
      return info;
  }
  ```
- [ ] Aggiungere `autoprotect.c` a `migration/meson.build`
- [ ] Verificare compilazione e linking
- **File:** `migration/autoprotect.h`, `migration/autoprotect.c`, `migration/meson.build`
- **Criteri di accettazione:**
  - `make` compila senza errori
  - Da QMP: `{ "execute": "autoprotect-status" }` ritorna `{ "enabled": false }`

**Deliverable Fase 2:** Schema QAPI + stub C compilabili. Comandi QMP rispondono.
**Sforzo stimato:** 1-2 giorni.

---

### FASE 3 — Modulo Interno QEMU: Logica Timer + Snapshot (Strategia B, parte 2)
**Obiettivo:** Implementare il timer periodico e la logica di snapshot/prune.
**Stato:** ⬜ Da fare
**Prerequisiti:** Fase 2 completata

#### Step 3.1 — Struttura stato e timer
- [ ] Definire in `autoprotect.c` la struttura stato:
  ```c
  typedef struct AutoProtectState {
      bool enabled;
      int64_t interval_ms;
      int64_t retention_ms;        /* retention_hours * 3600 * 1000 */
      char *vmstate_node;
      strList *devices;
      char *name_prefix;
      QEMUTimer *timer;
      uint64_t snapshot_counter;
      uint64_t snapshots_taken;
      uint64_t snapshots_pruned;
      char *last_snapshot_tag;
      bool snapshot_in_progress;
  } AutoProtectState;

  static AutoProtectState autoprotect_state;
  ```
- [ ] Implementare `qmp_autoprotect_enable()`:
  1. Validare parametri (interval > 0, retention > 0, devices non vuota)
  2. Verificare `bdrv_all_can_snapshot()` sui dispositivi indicati
  3. Popolare `autoprotect_state`
  4. Creare timer: `timer_new_ms(QEMU_CLOCK_REALTIME, autoprotect_timer_cb, &autoprotect_state)`
     — NOTA: uso `QEMU_CLOCK_REALTIME` e non `VIRTUAL` perché `VIRTUAL` si ferma
     quando la VM è in pausa e il callback del timer chiama `vm_stop()` che
     fermerebbe il clock stesso. Alternativa: `QEMU_CLOCK_REALTIME` con check
     `runstate_is_running()` nel callback.
  5. Armare timer: `timer_mod(timer, qemu_clock_get_ms(...) + interval_ms)`
- [ ] Implementare `qmp_autoprotect_disable()`:
  1. `timer_del(timer)` + `timer_free(timer)`
  2. Reset stato
- [ ] Implementare `qmp_autoprotect_status()`:
  1. Popolare e ritornare `AutoProtectInfo`
- **File:** `migration/autoprotect.c`
- **Test:** Abilitare via QMP, verificare che `autoprotect-status` riporti stato corretto.
  Il timer non fa ancora nulla (callback vuoto o log).
- **Criteri di accettazione:**
  - `autoprotect-enable` con parametri validi non ritorna errore
  - `autoprotect-status` riporta `enabled: true` e configurazione
  - `autoprotect-disable` resetta lo stato

#### Step 3.2 — Timer callback: creazione snapshot
- [ ] Implementare `autoprotect_timer_cb()`:
  ```c
  static void autoprotect_timer_cb(void *opaque)
  {
      AutoProtectState *s = opaque;

      if (s->snapshot_in_progress) {
          /* Snapshot precedente ancora in corso, rimanda */
          timer_mod(s->timer, qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + RETRY_MS);
          return;
      }

      if (!runstate_is_running()) {
          /* VM non attiva, rimanda */
          timer_mod(s->timer, qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + RETRY_MS);
          return;
      }

      s->snapshot_in_progress = true;
      char *tag = g_strdup_printf("%s-%lu",
          s->name_prefix ? s->name_prefix : "autoprotect",
          (unsigned long)s->snapshot_counter++);
      char *job_id = g_strdup_printf("autoprotect-save-%lu",
          (unsigned long)(s->snapshots_taken));

      Error *err = NULL;
      /* Usa lo stesso path di qmp_snapshot_save() */
      qmp_snapshot_save(job_id, tag, s->vmstate_node, s->devices, &err);
      if (err) {
          error_report_err(err);
          s->snapshot_in_progress = false;
      }
      /* Il completamento verrà gestito via job callback o polling */

      g_free(tag);
      g_free(job_id);

      /* Re-arm timer */
      timer_mod(s->timer, qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + s->interval_ms);
  }
  ```
- [ ] **Problema da risolvere:** `qmp_snapshot_save()` crea un Job asincrono, ma
  la callback del timer gira nel main loop. Bisogna intercettare il completamento
  del job per:
  - Settare `snapshot_in_progress = false`
  - Aggiornare `last_snapshot_tag` e `snapshots_taken`
  - Avviare la fase di pruning
  - **Opzioni:**
    - A) Usare `job_completed` callback (se il JobDriver lo supporta)
    - B) Registrare un notifier su `JOB_STATUS_CHANGE`
    - C) Chiamare direttamente `save_snapshot()` (sincrono, più semplice ma
         blocca il main loop durante tutto il dump — accettabile qui perché
         `save_snapshot()` fa `vm_stop()` comunque)
    - **Scelta raccomandata:** Opzione C per la Fase 3 (semplicità).
      Si ristruttura in Fase 4 per il path non-blocking.
- [ ] Con opzione C, il callback diventa:
  ```c
  static void autoprotect_timer_cb(void *opaque) {
      /* ... validazioni ... */
      Error *err = NULL;
      bool ok = save_snapshot(tag, false, s->vmstate_node,
                              true, s->devices, &err);
      if (ok) {
          g_free(s->last_snapshot_tag);
          s->last_snapshot_tag = g_strdup(tag);
          s->snapshots_taken++;
      } else {
          error_report_err(err);
      }
      s->snapshot_in_progress = false;
      /* Re-arm timer */
      timer_mod(s->timer, ...);
  }
  ```
- **Criteri di accettazione:**
  - Dopo aver abilitato con `interval-seconds: 60`, ogni 60s viene creato uno snapshot
  - Gli snapshot hanno nomi sequenziali `autoprotect-0`, `autoprotect-1`, ...
  - `autoprotect-status` mostra `snapshots-taken` incrementale

#### Step 3.3 — Pruning automatico degli snapshot vecchi
- [ ] Dopo ogni snapshot riuscito, invocare `autoprotect_prune()`:
  ```c
  static void autoprotect_prune(AutoProtectState *s)
  {
      /* 1. Ottenere la lista snapshot dal block device vmstate */
      BlockDriverState *bs = bdrv_all_find_vmstate_bs(s->vmstate_node,
                                                       true, s->devices, NULL);
      if (!bs) return;

      QEMUSnapshotInfo *sn_tab = NULL;
      int nb = bdrv_snapshot_list(bs, &sn_tab);
      if (nb <= 0) return;

      int64_t now_sec = time(NULL);   /* oppure g_get_real_time() / G_USEC_PER_SEC */
      int64_t retention_sec = s->retention_ms / 1000;

      for (int i = 0; i < nb; i++) {
          /* Filtra solo snapshot con il nostro prefisso */
          if (!g_str_has_prefix(sn_tab[i].name, s->name_prefix ?: "autoprotect")) {
              continue;
          }
          int64_t age_sec = now_sec - (int64_t)sn_tab[i].date_sec;
          if (age_sec > retention_sec) {
              Error *err = NULL;
              bdrv_all_delete_snapshot(sn_tab[i].name,
                                       true, s->devices, &err);
              if (err) {
                  error_report_err(err);
              } else {
                  s->snapshots_pruned++;
              }
          }
      }
      g_free(sn_tab);
  }
  ```
- [ ] Chiamare `autoprotect_prune(s)` nel callback dopo snapshot riuscito
- [ ] ATTENZIONE: `bdrv_all_delete_snapshot()` richiede `GRAPH_UNLOCKED`
  (vedi `include/block/snapshot.h:93-95`). Verificare che il contesto di
  esecuzione della callback del timer abbia i lock corretti.
- **Criteri di accettazione:**
  - Con `retention-hours: 1`, snapshot più vecchi di 1 ora vengono eliminati
  - Solo snapshot con prefisso `autoprotect-` vengono eliminati
  - Snapshot manuali non vengono toccati

#### Step 3.4 — Comandi HMP (opzionale)
- [ ] Aggiungere comandi HMP in `migration/migration-hmp-cmds.c`:
  - `autoprotect on <interval-sec> <retention-hours> [prefix]`
  - `autoprotect off`
  - `autoprotect status` / `info autoprotect`
- [ ] Registrare in `hmp-commands.hx`
- **Criteri di accettazione:**
  - Dal monitor HMP si può abilitare/disabilitare/controllare AutoProtect

**Deliverable Fase 3:** Modulo AutoProtect funzionante con snapshot periodici e pruning.
**Sforzo stimato:** 1-2 settimane.
**Limitazione nota:** La VM si blocca durante ogni snapshot (stessa limitazione di `savevm`).

---

### FASE 4 — Snapshot Non-Blocking (Strategia C)
**Obiettivo:** Eliminare il blocco della VM usando background-snapshot + external overlay.
**Stato:** ⬜ Da fare
**Prerequisiti:** Fase 3 completata, kernel Linux ≥ 5.7

> ⚠️ Questa è la fase più complessa. Richiede coordinamento tra 3 sottosistemi.

#### Step 4.1 — Snapshot disco live (external overlay)
- [ ] Nel callback del timer, sostituire `save_snapshot()` con:
  1. Generare nome overlay: `autoprotect-disk-<N>.qcow2`
  2. Per ogni device in `s->devices`:
     ```c
     qmp_blockdev_snapshot_sync(device, NULL, overlay_path,
                                 NULL, "qcow2", NULL, &err);
     ```
     (oppure usare `qmp_transaction()` per atomicità multi-disco)
  3. Questo crea un overlay COW istantaneo (~ms), la VM **non si ferma**
- [ ] Gestire il naming e la directory degli overlay
- **Criteri di accettazione:**
  - L'overlay viene creato in ~ms
  - La VM non si blocca
  - I dati precedenti al momento dello snapshot sono preservati nel backing file

#### Step 4.2 — Salvataggio RAM in background
- [ ] Dopo la creazione dell'overlay, avviare un background-snapshot per la RAM:
  1. Abilitare capability: `migrate-set-capabilities background-snapshot=true`
  2. Avviare migrazione a file: `migrate file:<path>/autoprotect-ram-<N>.state`
  3. La VM si ferma per ~ms (micro-stun), poi riparte
  4. Il thread `bg_migration_thread` salva la RAM in background
- [ ] **Problema critico:** `migrate` e `save_snapshot` sono mutuamente esclusivi
  (`migrate_can_snapshot()` ritorna `false` se una migrazione è attiva).
  Bisogna sequenzializzare: prima il background migrate (RAM), poi al suo
  completamento gli overlay disco, oppure viceversa.
  - **Ordine raccomandato:**
    1. `blockdev-snapshot-sync` per tutti i dischi (istantaneo, ~ms)
    2. Poi avviare `migrate` con `background-snapshot` per la RAM
    3. Questo cattura lo stato al momento del micro-stun — i dischi sono
       già "congelati" nell'overlay precedente
- [ ] Monitorare completamento della migrazione via evento `MIGRATION_STATUS_COMPLETED`
- **Criteri di accettazione:**
  - La combinazione overlay + bg-migrate cattura stato completo
  - La VM non si blocca mai per più di pochi millisecondi
  - I file di stato RAM vengono scritti correttamente

#### Step 4.3 — Consolidamento overlay (block-commit)
- [ ] Dopo la creazione di un nuovo overlay, consolidare quello precedente:
  ```c
  qmp_block_commit(device, false, NULL, false, NULL,
                    top_node, false, NULL, base_node,
                    false, 0, BLOCK_JOB_COMPLETION_MODE_GROUPED,
                    false, false, &err);
  ```
- [ ] Questo merge i dati dell'overlay vecchio nel backing file, in background
- [ ] Al completamento, l'overlay vecchio può essere eliminato
- [ ] Senza questo step, la catena di overlay cresce indefinitamente e degrada I/O
- **Criteri di accettazione:**
  - Dopo il commit, la catena di backing non supera mai profondità 2
  - Le performance I/O della VM non degradano nel tempo

#### Step 4.4 — Pruning file e snapshot state
- [ ] Implementare pulizia dei file RAM/overlay scaduti:
  - Elencare i file `autoprotect-ram-*.state` e `autoprotect-disk-*.qcow2`
  - Eliminare quelli con timestamp oltre la retention
- [ ] Gestire recovery da crash:
  - All'init di AutoProtect, verificare se ci sono file orfani da precedenti run
  - Pulire overlay non committati
- **Criteri di accettazione:**
  - I file vecchi vengono eliminati dopo la retention
  - Dopo un crash e restart, il sistema si auto-ripulisce

#### Step 4.5 — Integrazione e modalità ibrida
- [ ] Aggiungere campo `mode` allo schema QAPI:
  ```json
  { 'enum': 'AutoProtectMode',
    'data': ['internal', 'live'] }
  ```
- [ ] `internal` = Fase 3 (usa `save_snapshot()`, blocca VM)
- [ ] `live` = Fase 4 (usa overlay + bg-migrate, non blocca VM)
- [ ] Default: `live` se kernel supporta UFFD-WP, altrimenti fallback a `internal`
  (verificare con `ram_write_tracking_available()`)
- **Criteri di accettazione:**
  - L'utente può scegliere la modalità
  - Se UFFD non è disponibile e si richiede `live`, ritorna errore chiaro

**Deliverable Fase 4:** AutoProtect non-blocking completo.
**Sforzo stimato:** 3-5 settimane.

---

### FASE 5 — Hardening, Test e Documentazione
**Obiettivo:** Rendere il modulo robusto e ben documentato.
**Stato:** ⬜ Da fare

#### Step 5.1 — Test automatizzati
- [ ] Test QMP via framework test QEMU (`tests/qtest/`)
- [ ] Test di retention policy
- [ ] Test di recovery da crash
- [ ] Test con multiple disk images
- [ ] Test con disco raw (deve fallire gracefully)

#### Step 5.2 — Documentazione
- [ ] Creare `docs/interop/autoprotect.rst`
- [ ] Documentare tutti i comandi QMP con esempi
- [ ] Sezione troubleshooting

#### Step 5.3 — Persistenza configurazione (opzionale)
- [ ] Salvare la configurazione AutoProtect nel vmstate per ripristinarla dopo riavvio QEMU
- [ ] Oppure supportare un file di configurazione esterno

**Deliverable Fase 5:** Modulo production-ready.
**Sforzo stimato:** 1-2 settimane.

---

## Riepilogo Progressione

```
FASE 0 ✅   FASE 1 ⬜   FASE 2 ⬜   FASE 3 ⬜   FASE 4 ⬜   FASE 5 ⬜
Analisi     Script      QAPI +      Timer +     Live       Hardening
            esterno     Stub C      Snapshot    (non-block)
            QMP                     + Prune
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
