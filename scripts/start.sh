#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "Starting postgres cluster (pg1 primary + pg2/pg3 standbys)..."
docker compose up -d --build

echo "Waiting for all nodes to be healthy..."
docker compose ps
