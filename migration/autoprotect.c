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
#include "qapi/qapi-commands-autoprotect.h"
#include "qapi/qapi-types-autoprotect.h"
#include "migration/autoprotect.h"

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

void autoprotect_init(void)
{
}

void autoprotect_cleanup(void)
{
}
