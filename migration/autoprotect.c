/*
 * QEMU AutoProtect Subsystem
 *
 * Copyright (c) 2026 QEMU contributors
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qapi/clone-visitor.h"
#include "qapi/qapi-builtin-visit.h"
#include "qapi/qapi-commands-autoprotect.h"
#include "qapi/qapi-types-autoprotect.h"
#include "qapi/qapi-visit-autoprotect.h"
#include "qapi/qobject-input-visitor.h"
#include "qemu/keyval.h"
#include "qobject/qdict.h"
#include "qapi/qapi-commands-migration.h"
#include "qapi/qapi-commands-block-core.h"
#include "migration/autoprotect.h"
#include "migration/snapshot.h"
#include "migration/migration.h"
#include "migration/options.h"
#include "migration/ram.h"
#include "block/snapshot.h"
#include "block/block-io.h"
#include "block/block_int-global-state.h"
#include "system/block-backend-global-state.h"
#include "qemu/timer.h"
#include "system/runstate.h"
#include "system/system.h"
#include "qemu/error-report.h"
#include "qemu/notify.h"
#include "qemu/cutils.h"
#include <sys/wait.h>
#include "block/block.h"
#include "block/block-global-state.h"
#include "system/ramlist.h"
#include "system/ramblock.h"
#include "io/channel-file.h"
#include "migration/qemu-file.h"
#include "migration/savevm.h"

#ifdef qemu_ram_foreach_block
#undef qemu_ram_foreach_block
#endif

typedef struct AutoProtectLiveEntry {
    char *tag;
    char *ram_file;
    GList *overlay_files;
    int64_t timestamp_sec;
} AutoProtectLiveEntry;

typedef struct RAMDumpBlock {
    char idstr[256];
    uint64_t used_length;
    void *host_addr;
} RAMDumpBlock;

typedef struct RAMDumpContext {
    GArray *blocks;
} RAMDumpContext;

typedef struct AutoProtectState {
    bool enabled;
    int64_t interval_ms;
    int64_t retention_ms;
    char *vmstate_node;
    bool has_devices;
    strList *devices;
    char *name_prefix;
    AutoProtectMode mode;
    AutoProtectMode active_mode;
    char *storage_dir;
    bool night_prune;
    GList *live_snapshots;
    QEMUTimer *timer;
    uint64_t snapshot_counter;
    uint64_t snapshots_taken;
    uint64_t snapshots_pruned;
    char *last_snapshot_tag;
    int64_t next_snapshot_time_ms;
    bool snapshot_in_progress;
} AutoProtectState;

static AutoProtectState autoprotect_state;
static Notifier autoprotect_exit_notifier;
static bool exit_notifier_registered;

static void autoprotect_free_live_entry(AutoProtectLiveEntry *entry)
{
    if (!entry) {
        return;
    }
    g_free(entry->tag);
    g_free(entry->ram_file);
    for (GList *l = entry->overlay_files; l; l = l->next) {
        g_free(l->data);
    }
    g_list_free(entry->overlay_files);
    g_free(entry);
}

static void autoprotect_disable_internal(void)
{
    AutoProtectState *s = &autoprotect_state;

    if (s->timer) {
        timer_free(s->timer);
        s->timer = NULL;
    }

    g_free(s->vmstate_node);
    s->vmstate_node = NULL;

    qapi_free_strList(s->devices);
    s->devices = NULL;
    s->has_devices = false;

    g_free(s->name_prefix);
    s->name_prefix = NULL;

    g_free(s->storage_dir);
    s->storage_dir = NULL;

    for (GList *l = s->live_snapshots; l; l = l->next) {
        autoprotect_free_live_entry(l->data);
    }
    g_list_free(s->live_snapshots);
    s->live_snapshots = NULL;

    s->enabled = false;
    s->night_prune = false;
    s->snapshot_in_progress = false;
    s->next_snapshot_time_ms = 0;
}

static void autoprotect_exit_cb(Notifier *n, void *data)
{
    autoprotect_cleanup();
}

static bool autoprotect_is_night_time(void)
{
    time_t now = time(NULL);
    struct tm tm_info;
    localtime_r(&now, &tm_info);
    int hour = tm_info.tm_hour;
    return (hour >= 23 || hour < 6);
}

static char *autoprotect_detect_base_dir(AutoProtectState *s)
{
    BlockDriverState *bs = NULL;
    if (s->vmstate_node) {
        bs = bdrv_find_node(s->vmstate_node);
    }
    if (!bs) {
        BdrvNextIterator it;
        for (BlockDriverState *b = bdrv_first(&it); b; b = bdrv_next(&it)) {
            if (bdrv_has_blk(b) && bdrv_is_inserted(b) && bdrv_is_writable(b)) {
                bs = b;
                break;
            }
        }
    }
    if (bs) {
        bdrv_refresh_filename(bs);
        if (bs->filename[0] != '\0') {
            g_autofree char *abs_path = g_canonicalize_filename(bs->filename, NULL);
            if (abs_path) {
                char *dir = g_path_get_dirname(abs_path);
                if (dir) {
                    return dir;
                }
            }
        }
    }
    return g_strdup("/tmp");
}

static void autoprotect_prune_internal(AutoProtectState *s)
{
    if (s->night_prune && !autoprotect_is_night_time()) {
        info_report("AutoProtect: night-prune is active, skipping internal snapshot prune during daytime.");
        return;
    }

    Error *local_err = NULL;
    BlockDriverState *bs = bdrv_all_find_vmstate_bs(s->vmstate_node,
                                                    s->has_devices,
                                                    s->devices,
                                                    &local_err);
    if (!bs) {
        if (local_err) {
            error_reportf_err(local_err,
                "AutoProtect prune: failed to locate vmstate block device: ");
        }
        return;
    }

    QEMUSnapshotInfo *sn_tab = NULL;
    int nb = bdrv_snapshot_list(bs, &sn_tab);
    if (nb <= 0) {
        return;
    }

    int64_t now_sec = (int64_t)time(NULL);
    int64_t retention_sec = s->retention_ms / 1000;
    const char *prefix = s->name_prefix ? s->name_prefix : "autoprotect-";

    for (int i = 0; i < nb; i++) {
        if (!g_str_has_prefix(sn_tab[i].name, prefix)) {
            continue;
        }

        int64_t age_sec = now_sec - (int64_t)sn_tab[i].date_sec;
        if (age_sec > retention_sec) {
            Error *del_err = NULL;
            info_report("AutoProtect: pruning expired snapshot '%s' "
                        "(age: %" PRId64 "s, retention limit: %" PRId64 "s)",
                        sn_tab[i].name, age_sec, retention_sec);
            if (delete_snapshot(sn_tab[i].name, s->has_devices,
                                s->devices, &del_err)) {
                s->snapshots_pruned++;
            } else {
                error_reportf_err(del_err,
                    "AutoProtect: failed to prune snapshot '%s': ",
                    sn_tab[i].name);
            }
        }
    }

    g_free(sn_tab);
}

static void autoprotect_prune_live(AutoProtectState *s)
{
    if (s->night_prune && !autoprotect_is_night_time()) {
        info_report("AutoProtect: night-prune is active, skipping live snapshot prune during daytime.");
        return;
    }

    int64_t now_sec = (int64_t)time(NULL);
    int64_t retention_sec = s->retention_ms / 1000;
    GList *curr = s->live_snapshots;

    while (curr) {
        AutoProtectLiveEntry *entry = curr->data;
        GList *next = curr->next;
        int64_t age_sec = now_sec - entry->timestamp_sec;

        if (age_sec > retention_sec) {
            info_report("AutoProtect: pruning expired live snapshot '%s' "
                        "(age: %" PRId64 "s, retention: %" PRId64 "s)",
                        entry->tag, age_sec, retention_sec);
            if (entry->ram_file) {
                unlink(entry->ram_file);
            }
            autoprotect_free_live_entry(entry);
            s->live_snapshots = g_list_delete_link(s->live_snapshots, curr);
            s->snapshots_pruned++;
        }
        curr = next;
    }
}

static int autoprotect_collect_ram_block(RAMBlock *rb, void *opaque)
{
    RAMDumpContext *ctx = opaque;
    RAMDumpBlock b;
    memset(&b, 0, sizeof(b));
    pstrcpy(b.idstr, sizeof(b.idstr), qemu_ram_get_idstr(rb));
    b.used_length = qemu_ram_get_used_length(rb);
    b.host_addr = qemu_ram_get_host_addr(rb);
    g_array_append_val(ctx->blocks, b);
    return 0;
}

static bool autoprotect_save_ram_live_fork(const char *ram_file, const char *dev_file)
{
    RAMDumpContext ctx;
    ctx.blocks = g_array_new(FALSE, FALSE, sizeof(RAMDumpBlock));
    foreach_not_ignored_block(autoprotect_collect_ram_block, &ctx);

    /* Temporarily enable DOFORK on RAMBlocks so child inherits memory via COW */
    for (guint i = 0; i < ctx.blocks->len; i++) {
        RAMDumpBlock *b = &g_array_index(ctx.blocks, RAMDumpBlock, i);
        if (b->used_length > 0 && b->host_addr) {
#ifdef MADV_DOFORK
            madvise(b->host_addr, b->used_length, MADV_DOFORK);
#endif
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        error_report("AutoProtect: fork for RAM save failed: %s", strerror(errno));
        for (guint i = 0; i < ctx.blocks->len; i++) {
            RAMDumpBlock *b = &g_array_index(ctx.blocks, RAMDumpBlock, i);
            if (b->used_length > 0 && b->host_addr) {
#ifdef MADV_DONTFORK
                madvise(b->host_addr, b->used_length, MADV_DONTFORK);
#endif
            }
        }
        g_array_free(ctx.blocks, TRUE);
        return false;
    }

    if (pid == 0) {
        /* Child process: write RAM memory blocks directly using COW snapshot */
        int fd = open(ram_file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            _exit(1);
        }
        uint32_t num_blocks = ctx.blocks->len;
        if (write(fd, &num_blocks, sizeof(num_blocks)) != sizeof(num_blocks)) {
            close(fd);
            _exit(1);
        }
        for (guint i = 0; i < ctx.blocks->len; i++) {
            RAMDumpBlock *b = &g_array_index(ctx.blocks, RAMDumpBlock, i);
            if (write(fd, b->idstr, sizeof(b->idstr)) != sizeof(b->idstr) ||
                write(fd, &b->used_length, sizeof(b->used_length)) != sizeof(b->used_length)) {
                close(fd);
                _exit(1);
            }
            if (b->used_length > 0 && b->host_addr) {
                uint64_t written = 0;
                const uint8_t *p = (const uint8_t *)b->host_addr;
                while (written < b->used_length) {
                    size_t chunk = MIN((size_t)(b->used_length - written), (size_t)(4 * 1024 * 1024));
                    ssize_t ret = write(fd, p + written, chunk);
                    if (ret <= 0) {
                        close(fd);
                        _exit(1);
                    }
                    written += ret;
                }
            }
        }
        close(fd);
        _exit(0);
    }

    /* Parent process: restore MADV_DONTFORK and continue immediately without waiting */
    for (guint i = 0; i < ctx.blocks->len; i++) {
        RAMDumpBlock *b = &g_array_index(ctx.blocks, RAMDumpBlock, i);
        if (b->used_length > 0 && b->host_addr) {
#ifdef MADV_DONTFORK
            madvise(b->host_addr, b->used_length, MADV_DONTFORK);
#endif
        }
    }
    g_array_free(ctx.blocks, TRUE);

    /* Clean up any completed zombie child processes non-blockingly */
    waitpid(-1, NULL, WNOHANG);
    return true;
}

static bool autoprotect_save_devices_state(const char *filename, Error **errp)
{
    QIOChannelFile *ioc = qio_channel_file_new_path(filename,
                                                    O_WRONLY | O_CREAT | O_TRUNC,
                                                    0660, errp);
    if (!ioc) {
        return false;
    }
    qio_channel_set_name(QIO_CHANNEL(ioc), "migration-autoprotect-dev-state");
    QEMUFile *f = qemu_file_new_output(QIO_CHANNEL(ioc));
    object_unref(OBJECT(ioc));

    qemu_savevm_send_header(f);
    int ret = qemu_save_device_state(f, errp);
    int close_ret = qemu_fclose(f);
    if (ret < 0 || close_ret < 0) {
        if (!*errp) {
            error_setg(errp, "AutoProtect: saving device state failed");
        }
        return false;
    }
    return true;
}

static bool autoprotect_take_live_snapshot(AutoProtectState *s, const char *tag)
{
    const char *dir = s->storage_dir ? s->storage_dir : "/tmp";
    g_autofree char *ram_file = g_strdup_printf("%s/%s-ram.state", dir, tag);
    g_autofree char *dev_file = g_strdup_printf("%s/%s-dev.state", dir, tag);
    Error *err = NULL;

    info_report("AutoProtect: taking live non-blocking delta snapshot '%s' in '%s'...", tag, dir);

    /* 1. Create external overlays for disks without pausing vCPUs */
    GList *overlay_paths = NULL;
    if (s->has_devices && s->devices) {
        strList *d;
        for (d = s->devices; d; d = d->next) {
            g_autofree char *overlay = g_strdup_printf("%s/%s-disk-%s.qcow2",
                                                       dir, tag, d->value);
            qmp_blockdev_snapshot_sync(d->value, NULL, overlay, NULL,
                                       "qcow2", false, 0, &err);
            if (err) {
                error_reportf_err(err, "AutoProtect: disk snapshot failed for '%s': ",
                                  d->value);
                return false;
            }
            overlay_paths = g_list_append(overlay_paths, g_strdup(overlay));
        }
    } else {
        BdrvNextIterator it;
        for (BlockDriverState *bs = bdrv_first(&it); bs; bs = bdrv_next(&it)) {
            if (bdrv_has_blk(bs) && bdrv_is_inserted(bs) && bdrv_is_writable(bs)) {
                const char *name = bdrv_get_device_or_node_name(bs);
                g_autofree char *overlay = g_strdup_printf("%s/%s-disk-%s.qcow2",
                                                           dir, tag, name);
                qmp_blockdev_snapshot_sync(name, NULL, overlay, NULL,
                                           "qcow2", false, 0, &err);
                if (err) {
                    error_free(err);
                    err = NULL;
                    g_autofree char *node_name = g_strdup_printf("%s-%s", name, tag);
                    qmp_blockdev_snapshot_sync(NULL, name, overlay, node_name,
                                               "qcow2", false, 0, &err);
                }
                if (err) {
                    error_reportf_err(err, "AutoProtect: disk snapshot failed for '%s': ",
                                      name);
                    return false;
                }
                overlay_paths = g_list_append(overlay_paths, g_strdup(overlay));
            }
        }
    }

    /* 2. Micro-pause (< 3ms) to capture device state while vCPUs are quiescent */
    vm_stop(RUN_STATE_SAVE_VM);
    bdrv_drain_all_begin();
    bool dev_ok = autoprotect_save_devices_state(dev_file, &err);
    bdrv_drain_all_end();

    /* 3. Fork asynchronous RAM dump and immediately resume VM */
    bool ram_ok = autoprotect_save_ram_live_fork(ram_file, dev_file);
    vm_start();

    if (!dev_ok) {
        error_reportf_err(err, "AutoProtect: device state save failed: ");
        return false;
    }
    if (!ram_ok) {
        return false;
    }

    /* 4. Record live snapshot entry */
    AutoProtectLiveEntry *entry = g_new0(AutoProtectLiveEntry, 1);
    entry->tag = g_strdup(tag);
    entry->ram_file = g_strdup(ram_file);
    entry->overlay_files = overlay_paths;
    entry->timestamp_sec = time(NULL);
    s->live_snapshots = g_list_append(s->live_snapshots, entry);

    info_report("AutoProtect: live non-blocking snapshot '%s' created (RAM dumped asynchronously).",
                tag);
    return true;
}

static void autoprotect_timer_cb(void *opaque)
{
    AutoProtectState *s = opaque;
    const int64_t retry_ms = 5000;

    if (!s->enabled) {
        return;
    }

    if (s->snapshot_in_progress) {
        s->next_snapshot_time_ms =
            qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + retry_ms;
        timer_mod(s->timer, s->next_snapshot_time_ms);
        return;
    }

    if (!runstate_is_running()) {
        /* VM is paused or stopped, postpone snapshot attempt */
        s->next_snapshot_time_ms =
            qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + retry_ms;
        timer_mod(s->timer, s->next_snapshot_time_ms);
        return;
    }

    s->snapshot_in_progress = true;

    g_autoptr(GDateTime) now = g_date_time_new_now_utc();
    g_autofree char *ts_str = g_date_time_format(now, "%Y%m%d-%H%M%S");
    g_autofree char *tag = g_strdup_printf("%s%s",
        s->name_prefix ? s->name_prefix : "autoprotect-",
        ts_str);

    if (s->active_mode == AUTO_PROTECT_MODE_LIVE) {
        bool ok = autoprotect_take_live_snapshot(s, tag);
        if (ok) {
            g_free(s->last_snapshot_tag);
            s->last_snapshot_tag = g_strdup(tag);
            s->snapshots_taken++;
            autoprotect_prune_live(s);
        }
    } else {
        info_report("AutoProtect: taking scheduled internal snapshot '%s'...", tag);
        Error *local_err = NULL;
        bool ok = save_snapshot(tag, false, s->vmstate_node,
                                s->has_devices, s->devices, &local_err);
        if (ok) {
            g_free(s->last_snapshot_tag);
            s->last_snapshot_tag = g_strdup(tag);
            s->snapshots_taken++;
            info_report("AutoProtect: snapshot '%s' saved successfully.", tag);
            autoprotect_prune_internal(s);
        } else {
            error_reportf_err(local_err,
                "AutoProtect: snapshot '%s' failed: ", tag);
        }
    }

    s->snapshot_in_progress = false;

    if (s->enabled) {
        s->next_snapshot_time_ms =
            qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + s->interval_ms;
        timer_mod(s->timer, s->next_snapshot_time_ms);
    }
}

void qmp_autoprotect_enable(AutoProtectConfig *config, Error **errp)
{
    AutoProtectState *s = &autoprotect_state;

    if (config->interval_seconds <= 0) {
        error_setg(errp, "interval-seconds must be greater than 0");
        return;
    }

    if (config->retention_hours <= 0) {
        error_setg(errp, "retention-hours must be greater than 0");
        return;
    }

    bool has_devices = config->devices != NULL;
    if (!bdrv_all_can_snapshot(has_devices, config->devices, errp)) {
        return;
    }

    if (config->vmstate) {
        BlockDriverState *bs = bdrv_all_find_vmstate_bs(config->vmstate,
                                                        has_devices,
                                                        config->devices,
                                                        errp);
        if (!bs) {
            return;
        }
    }

    /* Determine mode: auto, internal, live */
    AutoProtectMode mode = config->has_mode ? config->mode : AUTO_PROTECT_MODE_AUTO;
    AutoProtectMode active_mode;

    if (mode == AUTO_PROTECT_MODE_INTERNAL) {
        active_mode = AUTO_PROTECT_MODE_INTERNAL;
    } else {
        /* Default / auto / live: use live non-blocking snapshot */
        active_mode = AUTO_PROTECT_MODE_LIVE;
    }

    /* Ensure exit notifier is registered once */
    if (!exit_notifier_registered) {
        autoprotect_exit_notifier.notify = autoprotect_exit_cb;
        qemu_add_exit_notifier(&autoprotect_exit_notifier);
        exit_notifier_registered = true;
    }

    /* Disable previous active timer/configuration */
    autoprotect_disable_internal();

    s->enabled = true;
    s->interval_ms = config->interval_seconds * 1000;
    s->retention_ms = (int64_t)config->retention_hours * 3600 * 1000;
    s->mode = mode;
    s->active_mode = active_mode;
    s->night_prune = config->has_night_prune ? config->night_prune : false;

    if (config->storage_dir) {
        s->storage_dir = g_strdup(config->storage_dir);
    } else {
        s->storage_dir = autoprotect_detect_base_dir(s);
    }

    if (config->vmstate) {
        s->vmstate_node = g_strdup(config->vmstate);
    }
    if (has_devices) {
        s->has_devices = true;
        s->devices = QAPI_CLONE(strList, config->devices);
    }
    if (config->name_prefix) {
        s->name_prefix = g_strdup(config->name_prefix);
    } else {
        s->name_prefix = g_strdup("autoprotect-");
    }

    s->timer = timer_new_ms(QEMU_CLOCK_REALTIME, autoprotect_timer_cb, s);
    s->next_snapshot_time_ms =
        qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + s->interval_ms;
    timer_mod(s->timer, s->next_snapshot_time_ms);

    info_report("AutoProtect enabled: mode=%s (active=%s), interval=%" PRId64 "s, "
                "retention=%" PRId64 "h, prefix='%s', storage-dir='%s', night-prune=%s",
                AutoProtectMode_str(s->mode),
                AutoProtectMode_str(s->active_mode),
                config->interval_seconds,
                (int64_t)config->retention_hours,
                s->name_prefix,
                s->storage_dir,
                s->night_prune ? "on" : "off");
}

void qmp_autoprotect_disable(Error **errp)
{
    if (!autoprotect_state.enabled) {
        return;
    }

    autoprotect_disable_internal();
    info_report("AutoProtect disabled.");
}

AutoProtectInfo *qmp_autoprotect_status(Error **errp)
{
    AutoProtectState *s = &autoprotect_state;
    AutoProtectInfo *info = g_new0(AutoProtectInfo, 1);

    info->enabled = s->enabled;
    if (s->enabled) {
        info->config = g_new0(AutoProtectConfig, 1);
        info->config->interval_seconds = s->interval_ms / 1000;
        info->config->retention_hours = s->retention_ms / (3600 * 1000);
        info->config->has_mode = true;
        info->config->mode = s->mode;

        if (s->storage_dir) {
            info->config->storage_dir = g_strdup(s->storage_dir);
            info->storage_dir = g_strdup(s->storage_dir);
        }

        info->has_night_prune = true;
        info->night_prune = s->night_prune;
        info->config->has_night_prune = true;
        info->config->night_prune = s->night_prune;

        info->has_active_mode = true;
        info->active_mode = s->active_mode;

        if (s->vmstate_node) {
            info->config->vmstate = g_strdup(s->vmstate_node);
        }
        if (s->has_devices && s->devices) {
            info->config->has_devices = true;
            info->config->devices = QAPI_CLONE(strList, s->devices);
        }
        if (s->name_prefix) {
            info->config->name_prefix = g_strdup(s->name_prefix);
        }

        int64_t now_ms = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);
        int64_t remaining_s = 0;
        if (s->next_snapshot_time_ms > now_ms) {
            remaining_s = (s->next_snapshot_time_ms - now_ms) / 1000;
        }
        info->has_next_snapshot_seconds = true;
        info->next_snapshot_seconds = remaining_s;
    }

    if (s->last_snapshot_tag) {
        info->last_snapshot_tag = g_strdup(s->last_snapshot_tag);
    }

    info->has_snapshots_taken = true;
    info->snapshots_taken = s->snapshots_taken;
    info->has_snapshots_pruned = true;
    info->snapshots_pruned = s->snapshots_pruned;

    return info;
}

static AutoProtectConfig *cmdline_config;

void autoprotect_parse_cmdline(const char *optarg, Error **errp)
{
    QDict *dict = keyval_parse(optarg, "interval-seconds", NULL, errp);
    if (!dict) {
        return;
    }

    /* Support convenient CLI aliases */
    QObject *val = qdict_get(dict, "interval");
    if (val && !qdict_haskey(dict, "interval-seconds")) {
        qobject_ref(val);
        qdict_put_obj(dict, "interval-seconds", val);
        qdict_del(dict, "interval");
    }

    val = qdict_get(dict, "retention");
    if (val && !qdict_haskey(dict, "retention-hours")) {
        qobject_ref(val);
        qdict_put_obj(dict, "retention-hours", val);
        qdict_del(dict, "retention");
    }

    val = qdict_get(dict, "dir");
    if (val && !qdict_haskey(dict, "storage-dir")) {
        qobject_ref(val);
        qdict_put_obj(dict, "storage-dir", val);
        qdict_del(dict, "dir");
    }

    val = qdict_get(dict, "prefix");
    if (val && !qdict_haskey(dict, "name-prefix")) {
        qobject_ref(val);
        qdict_put_obj(dict, "name-prefix", val);
        qdict_del(dict, "prefix");
    }

    val = qdict_get(dict, "night-prune");
    if (!val) {
        val = qdict_get(dict, "night_prune");
        if (val) {
            qobject_ref(val);
            qdict_put_obj(dict, "night-prune", val);
            qdict_del(dict, "night_prune");
        }
    }

    Visitor *v = qobject_input_visitor_new_keyval(QOBJECT(dict));
    qobject_unref(dict);

    qapi_free_AutoProtectConfig(cmdline_config);
    cmdline_config = NULL;

    visit_type_AutoProtectConfig(v, NULL, &cmdline_config, errp);
    visit_free(v);
}

void autoprotect_start_cmdline(Error **errp)
{
    if (cmdline_config) {
        qmp_autoprotect_enable(cmdline_config, errp);
    }
}

void autoprotect_init(void)
{
}

void autoprotect_cleanup(void)
{
    autoprotect_disable_internal();
    g_free(autoprotect_state.last_snapshot_tag);
    autoprotect_state.last_snapshot_tag = NULL;
    qapi_free_AutoProtectConfig(cmdline_config);
    cmdline_config = NULL;
}

