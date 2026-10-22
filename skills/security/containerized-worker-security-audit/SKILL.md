---
name: containerized-worker-security-audit
description: >-
  Read-only audit of a containerized worker/service attack surface from
  Dockerfile + compose + entrypoint + code: unauthenticated HTTP endpoints,
  secrets passed via env or bind-mount, host secrets readable by the container
  UID, Redis without ACL, egress policy, and container hardening. Produces
  severity-ranked findings (KRYTYCZNE/WYSOKIE/ŚREDNIE) with file:line evidence
  and a minimal fix. Use for "audyt bezpieczeństwa kontenera/workera",
  "wyciek sekretów do agenta", "nieuwierzytelnione endpointy",
  "montowanie <workspace>", "ACL Redis", "egress".
---


# Containerized Worker Security Audit (read-only)

Audyt **konfiguracji i kodu** kontenera/workera, nie security testing żywej usługi.
Wynik: 5 najważniejszych ryzyk + 3 rzeczy działających dobrze, każde z
`plik:linia` i dowodem. Zero zmian w kodzie, compose, sekretach i usługach.

## Kiedy używać
- „Audyt bezpieczeństwa kontenera/workera”, „powierzchnia ataku workera”.
- „Wyciek sekretów do agenta”, „agent widzi za dużo”, „env z tokenami”.
- „Nieuwierzytelnione endpointy”, „/run bez auth”, „kto może wywołać task”.
- „Montowanie <workspace>”, „bind-mount całego repo do kontenera”.
- „ACL Redis”, „Redis bez hasła”, „kolejka przyjmuje zadania”.
- „Egress”, „czy worker może wyjść do internetu”, „SSRF przez repo”.
- Audyt przed wdrożeniem lub po dodaniu agenta/queue/nowego portu.

## Zasady
1. **READ-ONLY.** Nie zmieniaj kodu, compose, uprawnień, firewall'a ani sekretów.
2. **Sekrety:** NIGDY nie wypisuj wartości ani nie `cat` pliku sekretów.
   Raportuj wyłącznie `ścieżka + tryb + właściciel + czytelny dla UID: tak/nie`.
3. **Dowód:** każde znalezisko ma `plik:linia` + fragment konfiguracji/kodu.
   Deklaracja w docs nie jest dowodem implementacji.
4. **Live vs config:** jeśli stack nie działa (`ss` nie widzi portu), napisz
   wprost „ocena konfiguracji, bez testu live”. Nie twierdź „potwierdzony weakness”.
5. **Język:** polski, gdy zlecenie jest po polsku. Odpowiedź ≤30 linii; plik
   raportu może być dłuższy.

## Faza 0 — recon (5 minut)
```bash
cd <project>
bash <skill-dir>/skills/shared/containerized-worker-security-audit/scripts/container-worker-recon.sh . "39100 6379"
rg --files | rg '(^|/)(Dockerfile|docker-compose.*\.ya?ml|compose\.ya?ml)$'
rg -n 'ports:|volumes:|user:|read_only|cap_drop|privileged|network_mode|requirepass|ACL' \
  Dockerfile docker-compose*.yml 2>/dev/null
rg -n 'HandleFunc|ListenAndServe|Authorization|Bearer|MaxBytesReader|ReadHeaderTimeout|os\.Environ|process\.env' .
ss -ltnp 2>/dev/null | rg ':(<port1>|<port2>)\b' || echo 'stack not listening'
```
Nie uruchamiaj `docker`/`curl`/`nmap`, jeśli zlecenie mówi „read-only” albo
stack nie działa. `ss` wystarcza do stwierdzenia „brak live”.

## Faza 1 — kontener i hardening
Sprawdź w compose/Dockerfile:
- `user:` — non-root? Jaki **numeryczny** UID:GID?
- `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges:true`.
- `privileged`, `cap_add`, `network_mode: host`, `/var/run/docker.sock`.
- `pids_limit`, `mem_limit`, `cpus` — czy jest limit DoS.
- `ports:` — czy publikuje na `0.0.0.0` (domyślnie tak), czy `127.0.0.1`.
- `tmpfs` — czy `/tmp` ma `noexec,nosuid` (opcjonalnie).
- Entrypoint: czy bootstrap kopiuje sekrety do `$HOME`/workspace.

Dobre praktyki (potwierdź, nie zakładaj): non-root, read-only rootfs,
`cap_drop: ALL`, `no-new-privileges`, limity, brak docker.sock.

## Faza 2 — endpointy (najczęstszy P0)
Dla każdego handlera HTTP:
- Czy jest jakikolwiek middleware auth (Bearer/mTLS/HMAC/API key)?
- Czy endpoint przyjmuje `prompt`, `command`, `repo`, `task`, `agent`?
- Czy wynik wraca w response (kanał exfiltracji)?
- Czy jest `MaxBytesReader` / limit body, `ReadHeaderTimeout`, `ReadTimeout`,
  `WriteTimeout`, rate-limit, limit współbieżności?
- Czy `/health` i `/metrics` są bez auth? To zwykle ŚREDNIE (info disclosure),
  ale nie P0.

**Reguła:** endpoint typu `POST /run`, który uruchamia agenta/komendę bez auth,
to KRYTYCZNE. Jeśli agent ma `--yolo` / `--dangerously-skip-permissions` /
`exec` i dziedziczy env, to RCE + kradzież sekretów w jednym requestcie.

## Faza 3 — sekrety w kontenerze (env + mount)
Dwa niezależne kanały:

### 3a. Env
- `os.Environ()` / `process.env` przekazywane do procesu agenta = agent widzi
  **wszystkie** sekrety workera, nie tylko swoje.
- Sprawdź `environment:` w compose i `env_file:`.
- Sprawdź, czy task może wykonać `env`/`printenv` i odesłać wynik.

### 3b. Bind-mount
- Czy montowany jest cały `<workspace>` (lub inny duży root), czy tylko potrzebne
  podkatalogi? `:ro` blokuje **zapis**, nie **odczyt**.
- Ustal numeryczny UID/GID kontenera: `docker-compose.yml` → `user: "1001:1001"`.
  To ustawia primary GID; nie zakładaj, że container jest w hostowej grupie
  `aigon`. Porównaj **liczby**, nie nazwy:
  `stat -c '%a %u:%g %n' <plik>`.
- Decyzja o czytelności:

| tryb pliku | warunek | czytelny dla UID 1001? |
|---|---|---|
| `600` | owner != 1001 | NIE |
| `640` | owner != 1001 i gid != 1001 | NIE |
| `644` | other ma `r` | **TAK** |
| `664` | other ma `r` | **TAK** |
| `2775` katalog | other ma `r-x` | listuje/traversuje, pliki wg ich trybu |

- Nie zgłaszaj `640` jako wycieku tylko dlatego, że plik jest w mountcie.
  Sprawdź numeryczny gid. W AIGON hostowa grupa `aigon` ma zwykle inny gid
  niż kontenerowe `1001`.
- Katalog `2775` pozwala UID 1001 listować nazwy plików (info leak), ale nie
  czytać plików `640`.

## Faza 4 — Redis / kolejka
- `redis-server` bez `requirepass` i bez ACL?
- `ports: "6379:6379"` = publikacja na host (domyślnie 0.0.0.0).
- Worker łączy się `redis://` bez TLS?
- Czy kolejka jest źródłem tasków, które trafiają do tego samego `runTask`?
  Wtedy wstrzyknięcie taska = RCE/sekret, tak samo jak otwarty endpoint.
- `protected-mode` nie jest ACL — może blokować część połączeń, ale nie
  zastępuje auth. Nie twierdź „bezpieczne”, bo protected-mode jest on.

## Faza 5 — egress
- Czy compose ma `networks:` z `internal: true` dla Redis/DB?
- Czy worker ma domyślny bridge + NAT (może wyjść gdziekolwiek)?
- `extra_hosts` nie jest polityką egressu.
- Czy `repo`/`git clone` przyjmuje dowolny URL (SSRF, `file://`, `ssh://`)?
- Rekomendacja: Redis w sieci `internal`, egress tylko przez proxy/allowlistę
  do routera/gatewaya, deny reszty, blokada metadata/link-local.

## Faza 6 — raport
Format:
1. **Top 5 ryzyk** — każde: severity, wektor → skutek, dowód `plik:linia`,
   minimalna naprawa.
2. **3 rzeczy zrobione dobrze** — non-root, hardening, brak sekretów w obrazie.
3. **Wniosek** — najgroźniejsza kombinacja i kolejność napraw.
4. **Uwaga** — docs vs kod; config-level vs live.

Severity:
- **KRYTYCZNE** — bez auth RCE/odczyt sekretów, albo bezpośredni dostęp do
  produkcyjnych sekretów z kontenera.
- **WYSOKIE** — env inheritance, Redis bez ACL, brak egress policy, DoS.
- **ŚREDNIE** — info disclosure `/health`/`/metrics`, brak timeoutów bez
  bezpośredniego RCE.
- **NISKIE/INFO** — brak `noexec` na tmpfs, verbose wersje itp.

## Pułapki (wyuczone)
- **Stare numery linii.** Baseline/reporty mogą mieć inne linie niż aktualny
  plik. Zawsze `rg -n` po aktualnym pliku przed cytowaniem.
- **`git status` z podkatalogu monolitu** potrafi wypluć setki tysięcy linii.
  Użyj `git status --short -- .` albo `git -C <root> status --short -- <path>`.
- **`find <workspace>`** może sypać „Brak dostępu”. Nie zgłaszaj tego jako
  findings; użyj targeted `stat` na znanych ścieżkach.
- **`:ro` ≠ brak wycieku.** Read-only mount nadal pozwala czytać.
- **Docs deklarują auth-proxy/egress firewall** — sprawdź, czy kod i compose
  to mają. Rozjazd docs↔kod jest osobnym znaleziskiem.
- **`ports:` w compose** nie dowodzi publicznej ekspozycji — sprawdź firewall
  hosta; bez tego pisz „potencjalnie publiczne”.
- **Nie cytuj sekretów.** Nawet nazwy zmiennych są zbędne, jeśli wystarczy
  `docker-compose.yml:27-28`. W tabeli tylko ścieżka/tryb/właściciel/readable.
- **Nie mieszaj „config-level” z „live”.** Brak listenera = brak testu live.

## Pliki
- `skills/shared/containerized-worker-security-audit/references/freekery-2026-10-20.md` — pełny case: compose, Go worker,
  `POST /run`, mount `<workspace>`, światowo czytelne sekrety, Redis, egress.
- `skills/shared/containerized-worker-security-audit/scripts/container-worker-recon.sh` — read-only recon: compose/Dockerfile,
  endpointy, env, porty, `stat` sekretów (bez czytania zawartości).
