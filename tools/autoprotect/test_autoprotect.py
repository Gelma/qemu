#!/usr/bin/env python3
"""
Unit and Mock Tests for QEMU AutoProtect
"""

import json
import os
import socket
import tempfile
import threading
import time
import unittest

from autoprotect import (
    AutoProtectManager,
    QMPClient,
    QMPCommandError,
    QMPConnectionError,
    acquire_pidfile,
    release_pidfile,
)


class MockQMPServer(threading.Thread):
    """Simple thread-based mock QMP server for testing protocol handling."""

    def __init__(self, sock_path):
        super().__init__(daemon=True)
        self.sock_path = sock_path
        self.server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_sock.bind(sock_path)
        self.server_sock.listen(1)
        self.running = True
        self.received_commands = []
        self.responses = {}

    def run(self):
        self.server_sock.settimeout(2.0)
        try:
            conn, _ = self.server_sock.accept()
        except socket.timeout:
            return

        with conn:
            # 1. Send QMP greeting
            greeting = {
                "QMP": {
                    "version": {"qemu": {"micro": 50, "minor": 1, "major": 11}},
                    "capabilities": [],
                }
            }
            conn.sendall((json.dumps(greeting) + "\r\n").encode("utf-8"))

            conn_file = conn.makefile("r", encoding="utf-8")
            while self.running:
                line = conn_file.readline()
                if not line:
                    break
                try:
                    req = json.loads(line)
                except Exception:
                    continue

                cmd = req.get("execute")
                self.received_commands.append(req)

                if cmd == "qmp_capabilities":
                    resp = {"return": {}}
                elif cmd in self.responses:
                    resp = self.responses[cmd]
                else:
                    resp = {"return": {}}

                conn.sendall((json.dumps(resp) + "\r\n").encode("utf-8"))

    def stop(self):
        self.running = False
        try:
            self.server_sock.close()
        except Exception:
            pass


class TestAutoProtect(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.sock_path = os.path.join(self.tmpdir.name, "mock-qmp.sock")
        self.mock_server = MockQMPServer(self.sock_path)
        self.mock_server.start()
        time.sleep(0.1)

    def tearDown(self):
        self.mock_server.stop()
        self.tmpdir.cleanup()

    def test_qmp_connect_and_handshake(self):
        client = QMPClient(self.sock_path)
        greeting = client.connect()
        self.assertIn("QMP", greeting)
        self.assertEqual(len(self.mock_server.received_commands), 1)
        self.assertEqual(self.mock_server.received_commands[0]["execute"], "qmp_capabilities")
        client.close()

    def test_qmp_command_execution(self):
        self.mock_server.responses["query-status"] = {
            "return": {"status": "running", "singlestep": False, "running": True}
        }
        client = QMPClient(self.sock_path)
        client.connect()
        res = client.execute("query-status")
        self.assertEqual(res["status"], "running")
        client.close()

    def test_qmp_command_error(self):
        self.mock_server.responses["fail-cmd"] = {
            "error": {"class": "DeviceNotFound", "desc": "Device not found"}
        }
        client = QMPClient(self.sock_path)
        client.connect()
        with self.assertRaises(QMPCommandError) as ctx:
            client.execute("fail-cmd")
        self.assertIn("DeviceNotFound", str(ctx.exception))
        client.close()

    def test_auto_discovery_and_pruning(self):
        now = int(time.time())
        # Mock block nodes
        self.mock_server.responses["query-named-block-nodes"] = {
            "return": [
                {
                    "node-name": "drive0",
                    "drv": "qcow2",
                    "ro": False,
                    "image": {
                        "snapshots": [
                            {
                                "id": "1",
                                "name": "manual-backup",
                                "date-sec": now - 3600 * 48,
                                "vm-state-size": 1000,
                            },
                            {
                                "id": "2",
                                "name": "autoprotect-old",
                                "date-sec": now - 3600 * 25,  # 25 hours old
                                "vm-state-size": 2000,
                            },
                            {
                                "id": "3",
                                "name": "autoprotect-fresh",
                                "date-sec": now - 3600 * 2,   # 2 hours old
                                "vm-state-size": 2000,
                            },
                        ]
                    },
                }
            ]
        }
        self.mock_server.responses["query-status"] = {"return": {"status": "running"}}
        self.mock_server.responses["query-jobs"] = {"return": []}

        client = QMPClient(self.sock_path)
        client.connect()

        manager = AutoProtectManager(
            qmp=client,
            interval_seconds=3600,
            retention_seconds=24 * 3600,  # 24 hours retention
            prefix="autoprotect-",
        )

        vmstate, devices = manager.discover_devices()
        self.assertEqual(vmstate, "drive0")
        self.assertEqual(devices, ["drive0"])

        snapshots = manager.list_snapshots()
        self.assertEqual(len(snapshots), 3)

        # Verify pruning deletes only autoprotect-old (>24h) and preserves manual-backup and autoprotect-fresh
        pruned = manager.prune_snapshots()
        self.assertEqual(pruned, 1)

        # Check commands sent
        del_cmds = [
            c for c in self.mock_server.received_commands
            if c.get("execute") == "snapshot-delete"
        ]
        self.assertEqual(len(del_cmds), 1)
        self.assertEqual(del_cmds[0]["arguments"]["tag"], "autoprotect-old")

        client.close()

    def test_pidfile_management(self):
        pidfile = os.path.join(self.tmpdir.name, "test.pid")
        acquire_pidfile(pidfile)
        self.assertTrue(os.path.exists(pidfile))
        release_pidfile(pidfile)
        self.assertFalse(os.path.exists(pidfile))


if __name__ == "__main__":
    unittest.main()
