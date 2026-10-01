# QEMU AutoProtect Tool

Standalone automation tool for managing periodic full VM snapshots (RAM + disk) and retention policy for QEMU, mirroring VMware Workstation's AutoProtect feature.

---

## Features

- **Automated Periodic Snapshots**: Takes full VM snapshots (RAM + storage) at configurable intervals.
- **Configurable Retention Policy**: Automatically prunes snapshots older than a specified threshold (e.g. 24 hours), preserving manual user snapshots.
- **Auto-Discovery**: Automatically discovers writable `qcow2` block devices and designates the primary vmstate target.
- **Non-Invasive**: Communicates with QEMU via standard QMP (QEMU Machine Protocol) UNIX or TCP sockets. Requires zero patches to QEMU binaries.
- **Zero External Dependencies**: Pure Python 3 using standard library modules (`socket`, `json`, `argparse`, `time`, etc.).
- **Multiple Operational Modes**:
  - `daemon`: Continuous background runner with configurable sleep interval.
  - `oneshot`: Trigger a single snapshot + prune cycle (ideal for cron or systemd timer).
  - `list`: Formatted listing of all existing snapshots, ages, and AutoProtect status.
  - `prune`: Prune expired AutoProtect snapshots without taking a new snapshot.

---

## Quick Start

### 1. Launch QEMU with a QMP Socket

When starting QEMU, add the `-qmp` argument:

```bash
qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -drive file=/var/lib/images/vm.qcow2,format=qcow2,id=drive0,if=virtio \
    -qmp unix:/tmp/qemu-qmp.sock,server,nowait
```

### 2. Verify Connection and List Existing Snapshots

```bash
cd tools/autoprotect
./autoprotect.py --socket /tmp/qemu-qmp.sock --mode list
```

### 3. Launch Daemon via `start.sh`

```bash
# Snapshot every 30 minutes, retain for 24 hours:
INTERVAL_MINUTES=30 RETENTION_HOURS=24 ./start.sh
```

To stop the daemon:
```bash
./stop.sh
```

To check daemon status:
```bash
make status
```

---

## Command Line Reference

```
usage: autoprotect.py [-h] [--socket SOCKET]
                      [--interval-minutes INTERVAL_MINUTES]
                      [--interval-seconds INTERVAL_SECONDS]
                      [--retention-hours RETENTION_HOURS]
                      [--retention-minutes RETENTION_MINUTES]
                      [--prefix PREFIX] [--vmstate VMSTATE]
                      [--devices DEVICES [DEVICES ...]]
                      [--mode {daemon,oneshot,list,prune}] [--pidfile PIDFILE]
                      [--log-level {DEBUG,INFO,WARNING,ERROR}]
                      [--log-file LOG_FILE]

Options:
  --socket SOCKET, -s SOCKET
                        Path to QMP UNIX socket or host:port (default: /tmp/qemu-qmp.sock)
  --interval-minutes N  Snapshot interval in minutes (default: 30)
  --interval-seconds N  Snapshot interval in seconds (convenient for quick tests)
  --retention-hours H   Snapshot retention limit in hours (default: 24.0)
  --retention-minutes M Snapshot retention limit in minutes (convenient for quick tests)
  --prefix PREFIX       Prefix tag identifying AutoProtect snapshots (default: 'autoprotect-')
  --vmstate VMSTATE     Node name of block device storing RAM state (default: auto-discover)
  --devices DEV [DEV...]
                        Block device nodes to snapshot (default: all writable qcow2 nodes)
  --mode MODE           Operating mode: daemon, oneshot, list, prune (default: daemon)
  --pidfile PIDFILE     PID file location (default: /tmp/qemu-autoprotect.pid)
  --log-level LEVEL     Log level: DEBUG, INFO, WARNING, ERROR (default: INFO)
  --log-file FILE       File path for logging output (default: stdout)
```

---

## Systemd Integration

For unattended continuous execution:

1. Copy service and timer definitions:
   ```bash
   sudo cp autoprotect.service /etc/systemd/system/
   sudo cp autoprotect.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   ```

2. Enable and start the timer:
   ```bash
   sudo systemctl enable --now autoprotect.timer
   ```

---

## Testing

Run unit and mock protocol tests with:

```bash
make test
```
