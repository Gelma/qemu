.. _autoprotect:

==================================================
AutoProtect: Automated Periodic Snapshot Subsystem
==================================================

Overview
========

The AutoProtect subsystem provides VMware Workstation-like automated
periodic snapshot capabilities for virtual machines running under QEMU.

It periodically captures full virtual machine state (guest RAM and virtual
disks) at user-configured time intervals, retains snapshots for a specified
period, and automatically prunes expired snapshots once their age exceeds
the retention limit.

Key Features
------------

- **Configurable Interval**: Set snapshot frequency in seconds (or hours).
- **Automated Retention Pruning**: Specify retention period in hours; older
  snapshots matching the configured prefix are automatically deleted.
- **User Snapshot Protection**: Manual user snapshots (created via ``savevm``
  or QMP ``snapshot-save``) are never touched or deleted by AutoProtect.
- **Multiple Operational Modes**:

  - ``auto`` (default): Dynamically selects ``live`` non-blocking mode with
    instantaneous COW overlays and asynchronous RAM dump.
  - ``internal``: Synchronous internal qcow2 snapshots (RAM + disk saved into
    qcow2 image).
  - ``live``: Non-blocking live delta snapshots using instantaneous COW overlays
    (``blockdev-snapshot-sync``) and asynchronous COW RAM dump with zero perceptible
    vCPU pause.
- **Delta Storage Location**: Delta files (storage overlays and RAM dumps) are
  placed by default in the same directory as the base qcow2 disk image.
- **Night Pruning**: Optional deferred bulk pruning (``night-prune=on``) that
  restricts snapshot deletion to nighttime hours (23:00 - 06:00), preventing any
  disk compaction freeze during working hours.
- **Startup CLI Option**: Start the VM with AutoProtect pre-configured via
  the ``-autoprotect`` command-line option.
- **Runtime Management**: Dynamically enable, disable, and monitor via both
  QMP (JSON RPC) and HMP (human monitor).

Command-Line Usage
==================

AutoProtect can be enabled directly when launching QEMU:

.. code-block:: shell

   qemu-system-x86_64 -m 3G -drive file=/disks/myvm.qcow2,format=qcow2 \
       -autoprotect interval=60,retention=1,mode=live,night-prune=on

Parameters:

- ``interval`` (or ``interval-seconds``): Snapshot interval in seconds (mandatory).
- ``retention`` (or ``retention-hours``): Retention window in hours (mandatory).
- ``mode``: Snapshot mode: ``auto``, ``internal``, or ``live`` (default: ``auto``).
- ``prefix`` (or ``name-prefix``): Prefix for generated snapshot names (default: ``autoprotect-``).
- ``dir`` (or ``storage-dir``): Target directory for delta overlays and RAM files (default: base disk directory).
- ``night-prune``: Boolean (``on``/``off``) to defer snapshot deletions to nighttime (23:00 - 06:00).

QMP Management Interface
========================

autoprotect-enable
------------------

Enables automated periodic snapshots with the given configuration:

.. code-block:: json

   { "execute": "autoprotect-enable",
     "arguments": {
       "interval-seconds": 1800,
       "retention-hours": 24,
       "mode": "auto",
       "name-prefix": "autoprotect-",
       "storage-dir": "/var/lib/qemu/snapshots"
     }
   }

Response:

.. code-block:: json

   { "return": {} }

autoprotect-disable
-------------------

Disables periodic snapshots and cancels the active timer:

.. code-block:: json

   { "execute": "autoprotect-disable" }

Response:

.. code-block:: json

   { "return": {} }

autoprotect-status
------------------

Queries the current status and statistics:

.. code-block:: json

   { "execute": "autoprotect-status" }

Response:

.. code-block:: json

   { "return": {
       "enabled": true,
       "active-mode": "live",
       "storage-dir": "/var/lib/qemu/snapshots",
       "next-snapshot-seconds": 1420,
       "last-snapshot-tag": "autoprotect-20261001-160000",
       "snapshots-taken": 5,
       "snapshots-pruned": 2,
       "config": {
         "interval-seconds": 1800,
         "retention-hours": 24,
         "mode": "auto",
         "name-prefix": "autoprotect-",
         "storage-dir": "/var/lib/qemu/snapshots"
       }
     }
   }

HMP Monitor Commands
====================

AutoProtect can also be managed interactively from the Human Monitor:

.. code-block:: text

   (qemu) autoprotect on 1800 24 auto autoprotect-
   info: AutoProtect enabled: mode=auto (active=internal), interval=1800s, retention=24h, prefix='autoprotect-', storage-dir='/tmp'

   (qemu) info autoprotect
   AutoProtect: enabled
     Active Mode:   internal
     Interval:      1800 seconds
     Retention:     24 hours
     Prefix:        autoprotect-
     Storage Dir:   /tmp
     Next Snapshot: in 1795 seconds
     Total Taken:   0
     Total Pruned:  0

   (qemu) autoprotect off
   info: AutoProtect disabled.

Retention and Pruning Policy
============================

When an interval timer triggers:

1. A timestamp-based tag is generated: ``<prefix>YYYYMMDD-HHMMSS``.
2. The snapshot is saved (internally or via external overlay + RAM dump).
3. The retention manager scans existing snapshots:

   - For internal mode: queries ``bdrv_snapshot_list()``, matches snapshots
     starting with ``<prefix>``, computes age from creation timestamp, and
     deletes any snapshot where ``age > retention_hours * 3600``.
   - For live mode: tracks active snapshot metadata, unlinks expired RAM state
     files, and records pruned counts.
   - Any snapshot without the configured AutoProtect prefix is left intact.

External Standalone Daemon
==========================

In addition to the built-in subsystem, an external standalone Python daemon is
available in ``tools/autoprotect/autoprotect.py``. It connects to QEMU via QMP
socket and performs periodic snapshots without requiring custom QEMU binaries.
Systemd service and timer unit templates are provided in ``tools/autoprotect/``.

Troubleshooting
===============

Live mode rejected on startup:
   Live mode requires Linux kernel >= 5.7 with userfaultfd write-protection
   (``CONFIG_USERFAULTFD``). If the host lacks this capability, use ``auto``
   mode (which falls back automatically to internal snapshots) or ``internal``.

Snapshot fails due to disk format:
   Internal snapshots require qcow2 images with read-write access. If a raw or
   unsupported format drive is attached, snapshotting is safely blocked.
