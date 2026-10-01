/*
 * QEMU AutoProtect: Automated periodic snapshot management
 *
 * Copyright (c) 2026 QEMU contributors
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#ifndef QEMU_MIGRATION_AUTOPROTECT_H
#define QEMU_MIGRATION_AUTOPROTECT_H

#include "qapi/qapi-types-autoprotect.h"

void autoprotect_init(void);
void autoprotect_cleanup(void);

#endif /* QEMU_MIGRATION_AUTOPROTECT_H */
