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
#include "migration/autoprotect.h"
#include "migration/snapshot.h"
#include "block/snapshot.h"
#include "qemu/timer.h"
#include "system/runstate.h"
#include "system/system.h"
#include "qemu/error-report.h"
#include "qemu/notify.h"

typedef struct AutoProtectState {
    bool enabled;
    int64_t interval_ms;
    int64_t retention_ms;
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
static Notifier autoprotect_exit_notifier;
static bool exit_notifier_registered;

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

    s->enabled = false;
    s->snapshot_in_progress = false;
    s->next_snapshot_time_ms = 0;
}

static void autoprotect_exit_cb(Notifier *n, void *data)
{
    autoprotect_cleanup();
}

static void autoprotect_prune(AutoProtectState *s)
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

    info_report("AutoProtect: taking scheduled snapshot '%s'...", tag);

    Error *local_err = NULL;
    bool ok = save_snapshot(tag, false, s->vmstate_node,
                            s->has_devices, s->devices, &local_err);
    if (ok) {
        g_free(s->last_snapshot_tag);
        s->last_snapshot_tag = g_strdup(tag);
        s->snapshots_taken++;
        info_report("AutoProtect: snapshot '%s' saved successfully.", tag);

        /* Enforce retention policy on older snapshots */
        autoprotect_prune(s);
    } else {
        error_reportf_err(local_err,
            "AutoProtect: snapshot '%s' failed: ", tag);
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

    info_report("AutoProtect enabled: interval=%" PRId64 "s, "
                "retention=%" PRId64 "h, prefix='%s'",
                config->interval_seconds,
                (int64_t)config->retention_hours,
                s->name_prefix);
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
