# Makefile for QEMU AutoProtect Tool

PYTHON ?= python3
SCRIPT = autoprotect.py
SOCKET ?= /tmp/qemu-qmp.sock
PIDFILE ?= /tmp/qemu-autoprotect.pid

.PHONY: all check test lint start stop status list prune clean help

all: check

help:
	@echo "QEMU AutoProtect Management Targets:"
	@echo "  make check      - Verify Python syntax of the tool"
	@echo "  make test       - Run unit/mock tests"
	@echo "  make start      - Launch AutoProtect daemon via start.sh"
	@echo "  make stop       - Stop AutoProtect daemon via stop.sh"
	@echo "  make status     - Check if daemon process is currently running"
	@echo "  make list       - List snapshots from active QEMU instance"
	@echo "  make prune      - Prune expired snapshots on active QEMU instance"
	@echo "  make clean      - Clean temporary files and logs"

check:
	$(PYTHON) -m py_compile $(SCRIPT)
	@echo "Syntax check OK."

test:
	$(PYTHON) -m unittest discover -s . -p "test_*.py" -v

start:
	./start.sh

stop:
	./stop.sh

status:
	@if [ -f $(PIDFILE) ]; then \
		pid=$$(cat $(PIDFILE) 2>/dev/null); \
		if kill -0 "$$pid" 2>/dev/null; then \
			echo "AutoProtect is running with PID: $$pid"; \
		else \
			echo "AutoProtect is stopped (stale PID file $$pid present)"; \
		fi; \
	else \
		echo "AutoProtect is not running"; \
	fi

list:
	./$(SCRIPT) --socket $(SOCKET) --mode list

prune:
	./$(SCRIPT) --socket $(SOCKET) --mode prune

clean:
	rm -rf __pycache__ *.pyc /tmp/qemu-autoprotect.pid /tmp/qemu-autoprotect.log
