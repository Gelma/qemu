#!/usr/bin/env python3
"""
QEMU AutoProtect Daemon & Tool
==============================
Provides automated periodic snapshots (RAM + disk) and retention policy management
for QEMU virtual machines via the QEMU Machine Protocol (QMP).

Features:
- Configurable snapshot interval and retention period.
- Automated discovery of qcow2 storage nodes and vmstate targets.
- Graceful handling of VM states (checks if VM is running, waits for ongoing jobs).
- Clean retention cleanup based on timestamp metadata without touching manual snapshots.
- Modes: daemon (background continuous loop), oneshot, list, and prune.
- Zero external dependencies: works out-of-the-box with standard Python 3.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import select
import signal
import socket
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("autoprotect")


class QMPError(Exception):
    """Base exception for QMP protocol errors."""


class QMPConnectionError(QMPError):
    """Raised when unable to connect to or communicate with QMP socket."""


class QMPCommandError(QMPError):
    """Raised when QMP returns an error response."""

    def __init__(self, message: str, error_class: str = "GenericError"):
        super().__init__(f"{error_class}: {message}")
        self.error_class = error_class
        self.message = message


class QMPClient:
    """Lightweight, standalone QMP client using standard library sockets."""

    def __init__(self, address: str, timeout: float = 30.0):
        self.address = address
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self._file: Optional[Any] = None
        self.events: List[Dict[str, Any]] = []

    def connect(self) -> Dict[str, Any]:
        """Connect to QMP socket, perform greeting, and negotiate capabilities."""
        if self.sock is not None:
            self.close()

        try:
            if ":" in self.address and not self.address.startswith("/"):
                host, port_str = self.address.split(":", 1)
                self.sock = socket.create_connection((host, int(port_str)), timeout=self.timeout)
            else:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.settimeout(self.timeout)
                self.sock.connect(self.address)

            self._file = self.sock.makefile("r", encoding="utf-8")
        except OSError as e:
            raise QMPConnectionError(f"Cannot connect to QMP address '{self.address}': {e}") from e

        # 1. Read QMP greeting
        greeting = self._read_message()
        if not greeting or "QMP" not in greeting:
            self.close()
            raise QMPConnectionError(f"Invalid QMP greeting received: {greeting}")

        # 2. Negotiate capabilities
        res = self.execute("qmp_capabilities")
        logger.debug("QMP capabilities negotiated successfully: %s", res)
        return greeting

    def close(self) -> None:
        """Close connection cleanly."""
        if self._file:
            try:
                self._file.close()
            except Exception:
                pass
            self._file = None
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def _read_message(self) -> Optional[Dict[str, Any]]:
        """Read a single JSON message line from QMP."""
        if not self._file:
            return None
        line = self._file.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError as e:
            raise QMPError(f"Failed to decode QMP JSON payload: {line}") from e

    def execute(
        self,
        command: str,
        arguments: Optional[Dict[str, Any]] = None,
        timeout: Optional[float] = None,
    ) -> Any:
        """Send a QMP command and wait for its return/error response, queueing events."""
        if not self.sock or not self._file:
            raise QMPConnectionError("QMP socket is not connected.")

        req: Dict[str, Any] = {"execute": command}
        if arguments:
            req["arguments"] = arguments

        payload = json.dumps(req) + "\r\n"
        try:
            self.sock.sendall(payload.encode("utf-8"))
        except OSError as e:
            raise QMPConnectionError(f"Failed to send QMP command '{command}': {e}") from e

        effective_timeout = timeout if timeout is not None else self.timeout
        start_time = time.monotonic()

        while True:
            elapsed = time.monotonic() - start_time
            remaining = effective_timeout - elapsed
            if remaining <= 0:
                raise QMPError(f"Timed out waiting for response to command '{command}'")

            # Check if socket has data ready
            r, _, _ = select.select([self.sock], [], [], remaining)
            if not r:
                raise QMPError(f"Timed out waiting for response to command '{command}'")

            msg = self._read_message()
            if msg is None:
                raise QMPConnectionError("QMP connection closed by remote peer.")

            if "return" in msg:
                return msg["return"]
            if "error" in msg:
                err_dict = msg["error"]
                raise QMPCommandError(
                    message=err_dict.get("desc", "Unknown error"),
                    error_class=err_dict.get("class", "GenericError"),
                )
            if "event" in msg:
                self.events.append(msg)
                logger.debug("Received QMP event: %s", msg.get("event"))

    def wait_for_job(self, job_id: str, timeout: float = 300.0, poll_interval: float = 0.5) -> None:
        """Wait for a QEMU asynchronous Job to conclude, then dismiss it."""
        start_time = time.monotonic()
        while time.monotonic() - start_time < timeout:
            jobs = self.execute("query-jobs")
            target_job = None
            for j in jobs:
                if j.get("id") == job_id:
                    target_job = j
                    break

            if not target_job:
                # Job might have already concluded and been auto-dismissed
                return

            status = target_job.get("status")
            logger.debug("Job '%s' status: %s", job_id, status)

            if status == "concluded":
                error_msg = target_job.get("error")
                # Dismiss job
                try:
                    self.execute("job-dismiss", {"id": job_id})
                except Exception as e:
                    logger.debug("job-dismiss '%s' returned: %s", job_id, e)

                if error_msg:
                    raise QMPCommandError(f"Job '{job_id}' concluded with error: {error_msg}")
                return

            if status in ("aborting", "null"):
                error_msg = target_job.get("error", "Job aborted")
                try:
                    self.execute("job-dismiss", {"id": job_id})
                except Exception:
                    pass
                raise QMPCommandError(f"Job '{job_id}' entered aborting state: {error_msg}")

            time.sleep(poll_interval)

        raise QMPError(f"Timed out waiting for job '{job_id}' after {timeout} seconds.")


class AutoProtectManager:
    """Manages AutoProtect snapshot cycles and retention enforcement."""

    def __init__(
        self,
        qmp: QMPClient,
        interval_seconds: int,
        retention_seconds: int,
        prefix: str = "autoprotect-",
        vmstate_node: Optional[str] = None,
        devices: Optional[List[str]] = None,
    ):
        self.qmp = qmp
        self.interval_seconds = interval_seconds
        self.retention_seconds = retention_seconds
        self.prefix = prefix
        self.vmstate_node = vmstate_node
        self.devices = devices or []
        self._shutdown_requested = False

    def request_shutdown(self) -> None:
        self._shutdown_requested = True

    def discover_devices(self) -> Tuple[str, List[str]]:
        """Auto-discover candidate vmstate target and writable snapshot-capable devices."""
        if self.vmstate_node and self.devices:
            return self.vmstate_node, self.devices

        nodes = self.qmp.execute("query-named-block-nodes")
        candidate_devices: List[str] = []
        candidate_vmstate: Optional[str] = self.vmstate_node

        for node in nodes:
            node_name = node.get("node-name")
            drv = node.get("drv")
            ro = node.get("ro", True)
            if not node_name or ro:
                continue

            # Only qcow2 or snapshot-capable drivers
            if drv == "qcow2":
                candidate_devices.append(node_name)
                if not candidate_vmstate:
                    candidate_vmstate = node_name

        if not candidate_devices:
            raise QMPError(
                "No writable qcow2 block nodes found in QEMU. "
                "Ensure disks use qcow2 format and are not read-only."
            )

        final_vmstate = candidate_vmstate or candidate_devices[0]
        final_devices = self.devices if self.devices else candidate_devices
        logger.info(
            "Auto-discovered block layout -> vmstate target: '%s', snapshot devices: %s",
            final_vmstate,
            final_devices,
        )
        return final_vmstate, final_devices

    def is_vm_running(self) -> bool:
        """Check if VM runstate is currently 'running'."""
        try:
            status = self.qmp.execute("query-status")
            run_state = status.get("status")
            return run_state == "running"
        except Exception as e:
            logger.warning("Failed to query VM runstate: %s", e)
            return False

    def has_active_jobs(self) -> bool:
        """Check if any background jobs are currently running."""
        try:
            jobs = self.qmp.execute("query-jobs")
            for j in jobs:
                if j.get("status") in ("running", "created", "waiting", "pending"):
                    return True
            return False
        except Exception as e:
            logger.warning("Failed to query jobs: %s", e)
            return False

    def list_snapshots(self) -> List[Dict[str, Any]]:
        """List all internal snapshots across block nodes."""
        vmstate, _ = self.discover_devices()
        nodes = self.qmp.execute("query-named-block-nodes")
        snapshots: List[Dict[str, Any]] = []

        for node in nodes:
            if node.get("node-name") == vmstate:
                image_info = node.get("image", {})
                raw_snaps = image_info.get("snapshots", [])
                for s in raw_snaps:
                    date_sec = s.get("date-sec", 0)
                    snapshots.append(
                        {
                            "id": s.get("id"),
                            "name": s.get("name"),
                            "date_sec": date_sec,
                            "date_iso": datetime.fromtimestamp(date_sec, tz=timezone.utc).isoformat()
                            if date_sec
                            else "unknown",
                            "vm_state_size": s.get("vm-state-size", 0),
                            "is_autoprotect": s.get("name", "").startswith(self.prefix),
                        }
                    )
                break

        return snapshots

    def take_snapshot(self) -> str:
        """Create a new AutoProtect snapshot (RAM + disks)."""
        vmstate, devices = self.discover_devices()

        timestamp_str = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        tag = f"{self.prefix}{timestamp_str}"
        job_id = f"autoprotect-save-{int(time.time())}"

        logger.info("Initiating snapshot save: tag='%s' (job-id='%s')...", tag, job_id)
        start_ts = time.monotonic()

        self.qmp.execute(
            "snapshot-save",
            {
                "job-id": job_id,
                "tag": tag,
                "vmstate": vmstate,
                "devices": devices,
            },
        )

        self.qmp.wait_for_job(job_id=job_id, timeout=300.0)
        elapsed = time.monotonic() - start_ts
        logger.info("Snapshot '%s' successfully completed in %.2f seconds.", tag, elapsed)
        return tag

    def prune_snapshots(self) -> int:
        """Delete snapshots matching prefix that exceed retention period."""
        _, devices = self.discover_devices()
        snapshots = self.list_snapshots()
        now_ts = int(time.time())
        pruned_count = 0

        for s in snapshots:
            name = s.get("name", "")
            if not s.get("is_autoprotect"):
                continue

            date_sec = s.get("date_sec", 0)
            age_seconds = now_ts - date_sec

            if age_seconds > self.retention_seconds:
                job_id = f"autoprotect-del-{int(time.time())}-{s.get('id')}"
                logger.info(
                    "Pruning expired snapshot '%s' (age: %.1f hours, retention limit: %.1f hours)...",
                    name,
                    age_seconds / 3600.0,
                    self.retention_seconds / 3600.0,
                )
                try:
                    self.qmp.execute(
                        "snapshot-delete",
                        {
                            "job-id": job_id,
                            "tag": name,
                            "devices": devices,
                        },
                    )
                    self.qmp.wait_for_job(job_id=job_id, timeout=180.0)
                    pruned_count += 1
                    logger.info("Snapshot '%s' successfully deleted.", name)
                except Exception as e:
                    logger.error("Failed to delete expired snapshot '%s': %s", name, e)

        return pruned_count

    def run_cycle(self) -> bool:
        """Execute one complete AutoProtect cycle (check state -> snapshot -> prune)."""
        if not self.is_vm_running():
            logger.info("VM is not currently in 'running' state. Skipping snapshot cycle.")
            return False

        if self.has_active_jobs():
            logger.warning("Another background job is active in QEMU. Postponing snapshot.")
            return False

        try:
            self.take_snapshot()
        except Exception as e:
            logger.error("AutoProtect snapshot failed: %s", e)
            return False

        try:
            pruned = self.prune_snapshots()
            logger.info("Retention check finished: %d snapshot(s) pruned.", pruned)
        except Exception as e:
            logger.warning("Retention pruning encountered an error: %s", e)

        return True

    def run_daemon(self) -> None:
        """Main daemon loop."""
        logger.info(
            "AutoProtect daemon started. Interval: %ds, Retention: %ds, Prefix: '%s'",
            self.interval_seconds,
            self.retention_seconds,
            self.prefix,
        )

        while not self._shutdown_requested:
            cycle_start = time.monotonic()
            try:
                self.run_cycle()
            except Exception as e:
                logger.error("Unexpected error during AutoProtect cycle: %s", e)

            # Sleep in small slices to respond promptly to termination signals
            elapsed = time.monotonic() - cycle_start
            sleep_duration = max(1.0, self.interval_seconds - elapsed)
            logger.debug("Sleeping for %.1f seconds until next cycle...", sleep_duration)

            sleep_end = time.monotonic() + sleep_duration
            while time.monotonic() < sleep_end and not self._shutdown_requested:
                time.sleep(0.5)

        logger.info("AutoProtect daemon stopped gracefully.")


def acquire_pidfile(pidfile: str) -> None:
    """Ensure no other daemon instance is running and record current PID."""
    pid_path = Path(pidfile)
    if pid_path.exists():
        try:
            old_pid = int(pid_path.read_text().strip())
            # Check if process is still alive
            os.kill(old_pid, 0)
            logger.error("Another daemon process with PID %d is already active.", old_pid)
            sys.exit(1)
        except (ValueError, OSError):
            # Stale PID file
            pid_path.unlink(missing_ok=True)

    pid_path.write_text(str(os.getpid()))


def release_pidfile(pidfile: str) -> None:
    """Remove PID file upon exit."""
    try:
        Path(pidfile).unlink(missing_ok=True)
    except Exception:
        pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="QEMU AutoProtect: Periodic RAM + Storage Snapshot and Retention Manager"
    )
    parser.add_argument(
        "--socket",
        "-s",
        default="/tmp/qemu-qmp.sock",
        help="Path to QMP UNIX socket or host:port (default: /tmp/qemu-qmp.sock)",
    )
    parser.add_argument(
        "--interval-minutes",
        type=int,
        default=30,
        help="Snapshot interval in minutes (default: 30)",
    )
    parser.add_argument(
        "--interval-seconds",
        type=int,
        default=None,
        help="Snapshot interval in seconds (overrides --interval-minutes)",
    )
    parser.add_argument(
        "--retention-hours",
        type=float,
        default=24.0,
        help="Snapshot retention time in hours (default: 24.0)",
    )
    parser.add_argument(
        "--retention-minutes",
        type=float,
        default=None,
        help="Snapshot retention time in minutes (overrides --retention-hours)",
    )
    parser.add_argument(
        "--prefix",
        default="autoprotect-",
        help="Prefix tag for AutoProtect snapshots (default: 'autoprotect-')",
    )
    parser.add_argument(
        "--vmstate",
        default=None,
        help="Block node to store VM RAM state (default: auto-discover)",
    )
    parser.add_argument(
        "--devices",
        nargs="+",
        default=None,
        help="Block nodes to include in snapshot (default: auto-discover all writable qcow2 nodes)",
    )
    parser.add_argument(
        "--mode",
        choices=["daemon", "oneshot", "list", "prune"],
        default="daemon",
        help="Operating mode: daemon (default), oneshot, list, prune",
    )
    parser.add_argument(
        "--pidfile",
        default="/tmp/qemu-autoprotect.pid",
        help="PID file path for daemon mode (default: /tmp/qemu-autoprotect.pid)",
    )
    parser.add_argument(
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        default="INFO",
        help="Logging verbosity (default: INFO)",
    )
    parser.add_argument(
        "--log-file",
        default=None,
        help="Log file path (default: stdout)",
    )
    return parser.parse_args()


def setup_logging(log_level: str, log_file: Optional[str]) -> None:
    handlers: List[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_file:
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))

    logging.basicConfig(
        level=getattr(logging, log_level.upper()),
        format="%(asctime)s [%(levelname)s] [autoprotect] %(message)s",
        handlers=handlers,
    )


def main() -> int:
    args = parse_args()
    setup_logging(args.log_level, args.log_file)

    interval_sec = args.interval_seconds if args.interval_seconds is not None else args.interval_minutes * 60
    if args.retention_minutes is not None:
        retention_sec = int(args.retention_minutes * 60)
    else:
        retention_sec = int(args.retention_hours * 3600)

    qmp = QMPClient(args.socket)
    try:
        qmp.connect()
    except QMPConnectionError as e:
        logger.error("Failed to connect to QEMU monitor: %s", e)
        return 1

    manager = AutoProtectManager(
        qmp=qmp,
        interval_seconds=interval_sec,
        retention_seconds=retention_sec,
        prefix=args.prefix,
        vmstate_node=args.vmstate,
        devices=args.devices,
    )

    if args.mode == "list":
        try:
            snaps = manager.list_snapshots()
            print("\n{:<6} {:<32} {:<24} {:<12} {:<10}".format(
                "ID", "TAG / NAME", "DATE (UTC)", "RAM SIZE", "AUTOPROTECT"
            ))
            print("-" * 88)
            for s in snaps:
                ram_mb = s["vm_state_size"] / (1024 * 1024)
                print("{:<6} {:<32} {:<24} {:<12.2f} MB {:<10}".format(
                    s["id"],
                    s["name"],
                    s["date_iso"],
                    ram_mb,
                    "YES" if s["is_autoprotect"] else "NO",
                ))
            print(f"\nTotal snapshots: {len(snaps)}\n")
            return 0
        except Exception as e:
            logger.error("Failed to list snapshots: %s", e)
            return 1
        finally:
            qmp.close()

    if args.mode == "prune":
        try:
            pruned = manager.prune_snapshots()
            logger.info("Pruned %d expired snapshot(s).", pruned)
            return 0
        except Exception as e:
            logger.error("Prune operation failed: %s", e)
            return 1
        finally:
            qmp.close()

    if args.mode == "oneshot":
        try:
            success = manager.run_cycle()
            return 0 if success else 1
        finally:
            qmp.close()

    # Daemon mode
    acquire_pidfile(args.pidfile)

    def signal_handler(signum: int, frame: Any) -> None:
        logger.info("Termination signal (%d) received. Shutting down daemon...", signum)
        manager.request_shutdown()

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    try:
        manager.run_daemon()
    finally:
        release_pidfile(args.pidfile)
        qmp.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
