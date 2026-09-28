#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "Stopping postgres cluster and removing containers + volumes..."
docker compose down --volumes --remove-orphans

echo "Cluster stopped and volumes removed."
