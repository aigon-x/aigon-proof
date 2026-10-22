#!/usr/bin/env bash
# Read-only recon for containerized worker security audit.
# Usage: container-worker-recon.sh [project-dir] ["port1 port2 ..."]
# Env: SECRET_PATHS="path1 path2" (optional; default common AIGON paths)
# Does NOT run docker/curl and does NOT read secret file contents.

set -euo pipefail

PROJECT="${1:-.}"
PORTS="${2:-39100 6379}"
SECRET_PATHS="${SECRET_PATHS:-/srv/aigon/.env /srv/aigon/runtime/.secrets/runtime-master.env /srv/aigon/voice/.env}"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required" >&2
  exit 1
fi

cd "$PROJECT"

echo "== READ-ONLY container worker recon =="
echo "project: $(pwd)"
echo

echo "== files =="
FILES="$(rg --files -g 'Dockerfile*' -g 'docker-compose*.yml' -g 'compose*.yml' 2>/dev/null || true)"
if [ -n "$FILES" ]; then
  printf '%s\n' "$FILES"
else
  echo "(no Dockerfile/compose found)"
fi
echo

echo "== container hardening / exposure =="
rg -n --no-heading \
  -e '^\s*(user|read_only|privileged|network_mode|pids_limit|mem_limit|cpus|ports|volumes|tmpfs):' \
  -e 'cap_drop|cap_add|no-new-privileges|docker\.sock|requirepass|ACLfile' \
  Dockerfile* docker-compose*.yml compose*.yml 2>/dev/null || true
echo

echo "== HTTP endpoints / auth / limits =="
rg -n --no-heading \
  -e 'HandleFunc|ListenAndServe|Authorization|Bearer|API[_-]?KEY' \
  -e 'MaxBytesReader|ReadHeaderTimeout|ReadTimeout|WriteTimeout|RateLimit|rate_limit' \
  -e 'os\.Environ|process\.env|os\.environ' \
  --glob '!**/vendor/**' --glob '!**/node_modules/**' . 2>/dev/null || true
echo

echo "== secret paths: mode / numeric owner / readable by container? =="
printf '%-60s %-6s %-10s %s\n' "path" "mode" "uid:gid" "note"
for p in $SECRET_PATHS; do
  if [ -e "$p" ]; then
    # shellcheck disable=SC2012
    stat -c '%n %a %u:%g' "$p" 2>/dev/null | while read -r path mode ug; do
      case "$mode" in
        600) note="NO (owner-only)" ;;
        640) note="check numeric gid vs container gid" ;;
        644|664) note="YES (other read)" ;;
        *) note="inspect manually" ;;
      esac
      printf '%-60s %-6s %-10s %s\n' "$path" "$mode" "$ug" "$note"
    done
  else
    printf '%-60s %-6s %-10s %s\n' "$p" "missing" "-" "-"
  fi
done
echo

echo "== listeners =="
for port in $PORTS; do
  ss -ltnp 2>/dev/null | rg "[:.]${port}\b" || echo "port ${port}: no listener (stack down or not bound)"
done
echo

echo "== notes =="
echo "- 664/644 are readable by a container UID outside owner/group (other r)."
echo "- 640 is readable only if container numeric gid == file gid; do not assume names."
echo "- :ro mount still allows reads. Read-only audit: do not change perms here."
