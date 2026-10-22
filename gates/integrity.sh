#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# git/integrity.sh — Universal Project Template — Repository Certification Engine
# Moduł: GIT INTEGRITY
# Sprawdza integralność repozytorium git.
#
# Checki:
#   GIT-001  Git initialized
#   GIT-002  main branch exists
#   GIT-003  Working tree clean (informational)
#   GIT-004  No nested git repositories
#   GIT-005  No submodules (informational)
#   GIT-006  Not detached HEAD
#   GIT-007  No orphan branches (informational)
#   GIT-008  No untracked files (informational)
#   GIT-009  No accidental executable bits (informational)
#   GIT-010  No symlinks (informational)
#   GIT-011  No case collisions
#   GIT-012  Git attributes present
#   GIT-013  Git config sanity
#   GIT-014  Hooks integrity
#   GIT-015  No branch divergence (informational)
#   GIT-016  Remote mismatch (informational)
#   GIT-017  Tag immutability (informational)
#   GIT-018  Protected branches
#   GIT-019  No force-push policy violation (informational)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GIT INTEGRITY ==="

# GIT-001 Git initialized
# Uwaga: w git worktree `.git` jest plikiem (gitdir: ...), nie katalogiem.
# Używamy `git rev-parse --git-dir`, które działa w obu przypadkach.
if git rev-parse --git-dir >/dev/null 2>&1; then
  pass "GIT-001 Git initialized"
else
  fail "GIT-001 Git initialized" BLOCKING "Brak repozytorium git — repo nie jest zainicjalizowane."
fi

# GIT-002 main branch exists
if git rev-parse --verify main >/dev/null 2>&1; then
  pass "GIT-002 main branch exists"
else
  fail "GIT-002 main branch exists" BLOCKING "Brak gałęzi main — kanoniczna linia projektu nie istnieje."
fi

# GIT-003 Working tree clean (informational)
if [ -z "$(git status --porcelain)" ]; then
  pass "GIT-003 Working tree clean"
else
  info "GIT-003 Working tree clean" "Working tree ma niezacommitowane zmiany."
fi

# GIT-004 No nested git repositories
# Wykluczamy .qwen/ (artefakty robocze agenta — worktree, nie zagnieżdżone repo)
# oraz .git/ (główny katalog git).
#
# NAPRAWA 2026-09-28 (defekt bramki — fałszywy defekt): poprzednia wersja
# używała GOŁEGO `find . -name .git`, który NIE RESPEKTUJE `.gitignore`.
# Skutek zmierzony: bramka zgłaszała jako błąd BLOCKING osiem katalogów,
# z których pięć jest ŚWIADOMIE ignorowanych przez repo:
#   - CI runner checkouty (products/*-runner/_work/... — tak działa GHA
#     self-hosted, to nie zagnieżdżone repo produktu),
#   - klony produktów i bench (products/drony, products/akceleratory,
#     bench/environments/ — własne remote, ignorowane celowo).
# Bramka mierzyła więc obecność KATALOGU, a nie faktyczny problem.
# Poprawna reguła: zgłaszamy tylko to, co git REALNIE widzi (nie jest
# ignorowane), bo tylko takie drzewo trafia do indeksu i psuje repo.
#
# ROZSZERZENIE 2026-09-28 (decyzja Suwerena: „full-sigil i runtime-platform
# to sa projekty. musza byc"): PRAWDZIWE podmoduły (wpis w `.gitmodules`)
# to NIE „zagnieżdżone repo" — to legalna, zamierzona konstrukcja gita.
# Zgłaszanie ich jako defektu było fałszywym alarmem. Wykluczamy ścieżki
# zarejestrowane w .gitmodules; GIT-005 nadal je raportuje jako INFO
# („sprawdź czy zamierzone"), więc widoczność zamysłu nie ginie.
SUBMODULES=""
if [ -f ".gitmodules" ]; then
  SUBMODULES="$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')"
fi
NESTED=""
while IFS= read -r kandydat; do
  [ -z "$kandydat" ] && continue
  # `git check-ignore -q` = 0, gdy ścieżka jest ignorowana → pomijamy.
  if git check-ignore -q "$kandydat" 2>/dev/null; then
    continue
  fi
  # Podmoduł z .gitmodules = zamierzony → pomijamy (GIT-005 go raportuje).
  katalog="$(dirname "$kandydat" | sed 's#^\./##')"
  pomin=0
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    if [ "$katalog" = "$sub" ]; then
      pomin=1
      break
    fi
  done <<< "$SUBMODULES"
  [ "$pomin" = 1 ] && continue
  NESTED="${NESTED}${kandydat}
"
done < <(find . -name .git -not -path "./.git" -not -path "./.git/*" -not -path "./.qwen/*" -not -path "./.codex/*" -not -path "./.claude/*" -not -path "./.grok/*" -not -path "./.dsh/*" -not -path "./.worktrees/*" -not -path "./worktree-*/*" 2>/dev/null)
NESTED="$(printf '%s' "$NESTED" | sed '/^$/d')"
if [ -n "$NESTED" ]; then
  fail "GIT-004 No nested git repositories" BLOCKING "Znaleziono zagnieżdżone repo (nieignorowane przez git, spoza .gitmodules): $NESTED"
else
  pass "GIT-004 No nested git repositories"
fi

# GIT-005 No submodules (informational)
if [ -f ".gitmodules" ]; then
  info "GIT-005 No submodules" "Repo używa submodułów — sprawdź czy to zamierzone."
else
  pass "GIT-005 No submodules"
fi

# GIT-006 Not detached HEAD
if git symbolic-ref -q HEAD >/dev/null 2>&1; then
  pass "GIT-006 Not detached HEAD"
else
  fail "GIT-006 Not detached HEAD" BLOCKING "HEAD jest w stanie detached — nie można commitować na detached HEAD."
fi

# GIT-007 No orphan branches (informational)
ORPHAN=$(git branch --no-color 2>/dev/null | grep -v '^\*' | while read -r b; do
  git merge-base --is-ancestor main "$b" 2>/dev/null || echo "$b"
done)
if [ -n "$ORPHAN" ]; then
  info "GIT-007 No orphan branches" "Gałęzie niebędące potomkami main: $ORPHAN"
else
  pass "GIT-007 No orphan branches"
fi

# GIT-008 No untracked files (informational)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
if [ -n "$UNTRACKED" ]; then
  info "GIT-008 No untracked files" "Nieśledzone pliki: $(echo "$UNTRACKED" | wc -l)"
else
  pass "GIT-008 No untracked files"
fi

# GIT-009 No accidental executable bits (informational)
# Sprawdzamy czy pliki, które nie są skryptami, nie mają bitu exec.
NONEXEC_EXEC=$(git ls-files -s 2>/dev/null | awk '$1 ~ /^100755/ {print $4}' | grep -vE '\.(sh|py|pl|rb)$' | head -5)
if [ -n "$NONEXEC_EXEC" ]; then
  info "GIT-009 No accidental executable bits" "Pliki z bitem exec (nie-skrypty): $NONEXEC_EXEC"
else
  pass "GIT-009 No accidental executable bits"
fi

# GIT-010 No symlinks (informational)
# Wykluczamy .qwen/ (artefakty robocze agenta — nie wchodzą do repo).
SYMLINKS=$(find . -type l -not -path "./.git/*" -not -path "./.qwen/*" -not -path "./.codex/*" -not -path "./.claude/*" -not -path "./.grok/*" -not -path "./.dsh/*" -not -path "./.worktrees/*" -not -path "./worktree-*/*" 2>/dev/null | head -5)
if [ -n "$SYMLINKS" ]; then
  info "GIT-010 No symlinks" "Symlinki: $SYMLINKS"
else
  pass "GIT-010 No symlinks"
fi

# GIT-011 No case collisions
# Wykrywamy pliki, które różnią się tylko wielkością liter (problem na case-insensitive FS).
COLLISIONS=$(git ls-files 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
if [ -n "$COLLISIONS" ]; then
  fail "GIT-011 No case collisions" BLOCKING "Kolizje wielkości liter: $COLLISIONS"
else
  pass "GIT-011 No case collisions"
fi

# GIT-012 Git attributes present
if [ -f ".gitattributes" ]; then
  pass "GIT-012 Git attributes present"
else
  fail "GIT-012 Git attributes present" BLOCKING "Brak .gitattributes — kontrola linii końca i binary nie jest zdefiniowana."
fi

# GIT-013 Git config sanity
# Sprawdzamy czy user.name i user.email są ustawione.
if [ -n "$(git config user.name)" ] && [ -n "$(git config user.email)" ]; then
  pass "GIT-013 Git config sanity"
else
  fail "GIT-013 Git config sanity" BLOCKING "Brak user.name lub user.email w konfiguracji git."
fi

# GIT-014 Hooks integrity
# Sprawdzamy czy core.hooksPath jest ustawiony i hooki istnieją.
HOOKSPATH="$(git config core.hooksPath || true)"
if [ -n "$HOOKSPATH" ] && [ -d "$HOOKSPATH" ]; then
  pass "GIT-014 Hooks integrity" "hooksPath=$HOOKSPATH"
else
  fail "GIT-014 Hooks integrity" BLOCKING "core.hooksPath nie jest ustawiony lub katalog hooków nie istnieje."
fi

# GIT-015 No branch divergence (informational)
# Sprawdzamy czy main nie rozjechał się z origin/main (jeśli remote istnieje).
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  AHEAD=$(git rev-list --count origin/main..main 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count main..origin/main 2>/dev/null || echo 0)
  if [ "$AHEAD" -gt 0 ] || [ "$BEHIND" -gt 0 ]; then
    info "GIT-015 No branch divergence" "main jest $AHEAD ahead / $BEHIND behind origin/main."
  else
    pass "GIT-015 No branch divergence"
  fi
else
  info "GIT-015 No branch divergence" "Brak origin/main — nie można porównać."
fi

# GIT-016 Remote mismatch (informational)
REMOTES=$(git remote -v 2>/dev/null | awk '{print $1}' | sort -u)
if [ -n "$REMOTES" ]; then
  info "GIT-016 Remote mismatch" "Skonfigurowane remote: $(echo "$REMOTES" | tr '\n' ' ')"
else
  info "GIT-016 Remote mismatch" "Brak skonfigurowanego remote."
fi

# GIT-017 Tag immutability (informational)
# Sprawdzamy czy tagi są annotated (nie lightweight) — annotated są immutable.
LIGHTWEIGHT=$(git tag -l 2>/dev/null | while read -r t; do
  git cat-file -t "$t" 2>/dev/null | grep -q '^commit$' && echo "$t"
done)
if [ -n "$LIGHTWEIGHT" ]; then
  info "GIT-017 Tag immutability" "Lightweight tagi (nieannotated): $LIGHTWEIGHT"
else
  pass "GIT-017 Tag immutability"
fi

# GIT-018 Protected branches
# Sprawdzamy czy main jest chroniony (nie można na niego pushować bezpośrednio).
# W lokalnym repo sprawdzamy przez pre-push hook.
if [ -f ".git-hooks/pre-push" ]; then
  pass "GIT-018 Protected branches" "pre-push hook chroni main."
else
  fail "GIT-018 Protected branches" BLOCKING "Brak pre-push hook — main nie jest chroniony."
fi

# GIT-019 No force-push policy violation (informational)
# Sprawdzamy czy nie ma skonfigurowanego receive.denyNonFastForwards (informational).
DENY=$(git config receive.denyNonFastForwards 2>/dev/null || echo "unset")
info "GIT-019 No force-push policy violation" "receive.denyNonFastForwards=$DENY (informational)."

verify_module_exit
