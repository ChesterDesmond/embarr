#!/bin/bash
# Runs set-temp.py in its own venv (created on first run).
cd "$(dirname "$0")"
[ -x venv/bin/python ] || { python3 -m venv venv && venv/bin/pip -q install bleak; }
exec venv/bin/python set-temp.py "$@"
