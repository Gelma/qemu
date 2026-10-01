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
#include "qapi/qapi-commands-migration.h"
#include "qapi/qapi-commands-block-core.h"
#include "migration/autoprotect.h"
#include "migration/snapshot.h"
#include "migration/migration.h"
#include "migration/options.h"
#include "migration/ram.h"
#include "block/snapshot.h"
#include "block/block-io.h"
#include "qemu/timer.h"
#include "system/runstate.h"
#include "system/system.h"
#include "qemu/error-report.h"
#include "qemu/notify.h"

typedef struct AutoProtectLiveEntry {
    char *tag;
    char *ram_file;
    GList *overlay_files;
    int64_t timestamp_sec;
} AutoProtectLiveEntry;

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
    s->snapshot_in_progress = false;
    s->next_snapshot_time_ms = 0;
}

static void autoprotect_exit_cb(Notifier *n, void *data)
{
    autoprotect_cleanup();
}

static void autoprotect_prune_internal(AutoProtectState *s)
{
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

static bool autoprotect_take_live_snapshot(AutoProtectState *s, const char *tag)
{
    const char *dir = s->storage_dir ? s->storage_dir : "/tmp";
    g_autofree char *ram_file = g_strdup_printf("%s/%s-ram.state", dir, tag);
    Error *err = NULL;

    info_report("AutoProtect: taking live non-blocking snapshot '%s'...", tag);

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
        BlockDriverState *bs = bdrv_all_find_vmstate_bs(s->vmstate_node, false, NULL, &err);
        if (bs) {
            const char *name = bdrv_get_device_or_node_name(bs);
            g_autofree char *overlay = g_strdup_printf("%s/%s-disk-%s.qcow2",
                                                       dir, tag, name);
            qmp_blockdev_snapshot_sync(name, NULL, overlay, NULL,
                                       "qcow2", false, 0, &err);
            if (err) {
                error_free(err);
                err = NULL;
                qmp_blockdev_snapshot_sync(NULL, name, overlay, NULL,
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

    /* 2. Save RAM via background snapshot (UFFD-WP) */
    MigrationState *ms = migrate_get_current();
    ms->capabilities[MIGRATION_CAPABILITY_BACKGROUND_SNAPSHOT] = true;

    g_autofree char *uri = g_strdup_printf("file:%s", ram_file);
    qmp_migrate(uri, false, NULL, false, false, &err);
    if (err) {
        error_reportf_err(err, "AutoProtect: background RAM save failed: ");
        return false;
    }

    /* 3. Record live snapshot entry */
    AutoProtectLiveEntry *entry = g_new0(AutoProtectLiveEntry, 1);
    entry->tag = g_strdup(tag);
    entry->ram_file = g_strdup(ram_file);
    entry->overlay_files = overlay_paths;
    entry->timestamp_sec = time(NULL);
    s->live_snapshots = g_list_append(s->live_snapshots, entry);

    info_report("AutoProtect: live snapshot '%s' initiated (RAM written asynchronously).",
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

    bool uffd_available = ram_write_tracking_available();
    if (mode == AUTO_PROTECT_MODE_LIVE) {
        if (!uffd_available) {
            error_setg(errp,
                "AutoProtect live mode requested, but host kernel lacks UFFD-WP "
                "(userfaultfd write-protection >= 5.7 required)");
            return;
        }
        active_mode = AUTO_PROTECT_MODE_LIVE;
    } else if (mode == AUTO_PROTECT_MODE_INTERNAL) {
        active_mode = AUTO_PROTECT_MODE_INTERNAL;
    } else {
        /* AUTO: prefer LIVE when kernel supports write tracking */
        active_mode = uffd_available ? AUTO_PROTECT_MODE_LIVE : AUTO_PROTECT_MODE_INTERNAL;
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

    if (config->storage_dir) {
        s->storage_dir = g_strdup(config->storage_dir);
    } else {
        s->storage_dir = g_strdup("/tmp");
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
                "retention=%" PRId64 "h, prefix='%s', storage-dir='%s'",
                AutoProtectMode_str(s->mode),
                AutoProtectMode_str(s->active_mode),
                config->interval_seconds,
                (int64_t)config->retention_hours,
                s->name_prefix,
                s->storage_dir);
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

void autoprotect_init(void)
{
}

void autoprotect_cleanup(void)
{
    autoprotect_disable_internal();
    g_free(autoprotect_state.last_snapshot_tag);
    autoprotect_state.last_snapshot_tag = NULL;
}
