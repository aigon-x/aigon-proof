#!/usr/bin/env bash
# Fail-closed explicit entry gate; not a claim that every agent harness is intercepted.
set -euo pipefail
for name in AIGON_CONTEXT_RECORD AIGON_CONTEXT_TASK AIGON_CONTEXT_PROJECT_ROOT AIGON_CONTEXT_SCOPE; do
  if [[ -z "${!name:-}" ]]; then
    printf 'project-context: FAIL (missing %s)\n' "$name" >&2
    exit 1
  fi
done
gate_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
args=(check --project "$AIGON_CONTEXT_PROJECT_ROOT" --task "$AIGON_CONTEXT_TASK" --record "$AIGON_CONTEXT_RECORD")
# Scope is newline-delimited so paths containing spaces are not split.
while IFS= read -r scope || [[ -n "$scope" ]]; do
  [[ -n "$scope" ]] || { echo 'project-context: FAIL (empty scope)' >&2; exit 1; }
  args+=(--scope "$scope")
done <<< "$AIGON_CONTEXT_SCOPE"
[[ -z "${AIGON_CONTEXT_POLICY:-}" ]] || args+=(--policy "$AIGON_CONTEXT_POLICY")
exec python3 "$gate_root/scripts/project-context.py" "${args[@]}"
