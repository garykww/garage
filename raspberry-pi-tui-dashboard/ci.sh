#!/usr/bin/env bash
set -euo pipefail

pip install -r requirements.txt --quiet
pytest test_dashboard.py -v
