#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/sync-agents.sh — gate sync-agents (hook-runner, post-merge)
#
#  AUTOMAT: „po merge'u konfiguracje agentów są zsynchronizowane z SSOT".
#  Uruchamia REALNY sync-agent-models.py (post-merge = user ma prawo do
#  własnych ~/.qwen ~/.claude ~/.hermes ~/.grok; sync jest idempotentny,
#  robi backup przed zapisem). To domyka pętlę: zmiana SSOT w merge'u
#  od razu propaguje się na configi agentów (nie czeka na cron */15).
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS
#    exit 1 = FAIL (sync zwrócił błąd)
#    exit 2 = WARN (sync częściowo ostrzegał — nie blokuje)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT=$(cd "$ROOT" && python3 scripts/sync-agent-models.py 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  # FIX 2026-09-21: dopasowanie KOLUMNY STATUSU, nie slowa gdziekolwiek.
  # `grep -c 'CHG'` liczyl takze wystapienia "CHG" w TRESCI komunikatu
  # (np. detail "delegation.base_url usuniety" nie, ale kazdy przyszly
  # komunikat zawierajacy ten ciag juz tak) => bramka raportowalaby
  # "zmian=1" przy zerowym rozjezdzie SSOT<->config. To ten sam wzorzec
  # false-green co GATE-083 (RC=$? po pipe z tail).
  # Kontrakt reportu (Report.dump): "  <KIND><spacje> <agent>: <detail>"
  # gdzie KIND jest w kolumnie 3-6. Dopasowujemy wylacznie ten format.
  n_chg=$(printf '%s\n' "$OUT" | grep -cE '^  CHG ' || true)
  echo "PASS sync-agents (sync-agent-models.py exit=0, zmian=$n_chg)"
  exit 0
fi
if echo "$OUT" | grep -qiE 'warn'; then
  echo "WARN sync-agents ($(echo "$OUT" | grep -iE 'warn' | head -2 | tr '\n' ' '))"
  exit 2
fi
echo "FAIL sync-agents (exit=$RC: $(echo "$OUT" | tail -3 | tr '\n' ' '))"
exit 1
