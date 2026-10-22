#!/usr/bin/env bash
# gate-docs-pdf.sh — adapter GATE-145 → scripts/gate-docs-pdf.sh
# Kontrakt hook-runner: bramki wołane jako tools/gates/<id>.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/scripts/gate-docs-pdf.sh" "$ROOT"
