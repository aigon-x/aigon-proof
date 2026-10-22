# Duża baza SQLite: obalone hipotezy i prawdziwe pomiary (2026-09-24)

Uzupełnienie do `database/sqlite-large-db-backup-and-vacuum`. Tamten SKILL.md ma
**niepełną diagnozę** sekcji „kopia" (oskarża SQLite o plik 0 B). Poniżej pomiary,
które to korygują. Czytaj razem.

## 1. `.backup` → 0 bajtów: sprawcą było I/O, nie SQLite

Fakt „`.backup` zostawia 0 B przy 11 GB" się potwierdził (**2×**). Wniosek „wina
SQLite" — **nie**. Skrypt backupu w repo opisuje to samo i słusznie używa
`VACUUM INTO` (`<workspace>/scripts/hermes-db-backup.sh:24-35` dokumentuje livelock
`.backup` przy aktywnym pisarzu).

Prawdziwy sprawca: **równoległy backup piszący przez autofs/NAS**, ~40 min I/O.
```
04:15:09  cron 15 4 * * *  →  hermes-db-backup.sh (nice -n 19, ionice -c2 -n7)
04:24:06  VACUUM INTO przez NAS      8 min 51 s
04:24:xx  PRAGMA quick_check przez autofs   7+ min (limit 1800 s)
        → SQLite: database is locked → COMPRESSION_FAILED → „context is too large"
```
Przy zajętym I/O **każda** metoda kopiowania jest niestabilna. Sprawdź sąsiada
PRZED obwinieniem metody → patrz `false-failure-triage`
`references/neighbour-process-io-contention.md`.

## 2. „Archiwum blokuje odczyt" — OBALONE pomiarem

```
odczyt 90 037 wierszy (pełny):    0,02 s
odczyt z active=1 (146 wierszy):  0,00 s
```
Indeksy są wzorowe, plan ich używa:
```
idx_messages_session          (session_id, timestamp)
idx_messages_session_active   (session_id, active, timestamp)
EXPLAIN QUERY PLAN → SEARCH messages USING INDEX idx_messages_session_active
```
**Jeśli `EXPLAIN` pokazuje użycie indeksu — problem nie jest w SQL.** Szukaj w I/O.

## 3. `compacted=1` = ARCHIWUM WYSZUKIWALNE (nie kasować!)

Byłem o krok od usunięcia **1 002 672 wierszy (95% bazy)** jako „skompresowanych śmieci".

Dowód (`hermes_state.py:4532-4533`):
```
DISCOVERABLE: they are marked compacted=1, and search_messages()
includes compacted=1 rows BY DEFAULT — so session_search still finds
```
`active=0` + `compacted=1` = **celowe archiwum trwałości** (`hermes_state.py:4473-4476`,
issue #38763). Usunięcie = **utrata pamięci wyszukiwania sesji**.

Sygnatura stanu:
```
messages:  1 055 527 razem | 1 002 672 compacted=1 | 52 855 active
sesja-potwór: 90 037       | 89 891 compacted     | 146 żywych
```
**146 żywych = model widzi mało.** Odczyt kontekstu filtruje `WHERE active = 1`
(`hermes_state.py:4554`) — archiwum **nie idzie do modelu** i nie uzasadnia
„kontekstu za dużego".

## 4. `compression_locks`: sieroty NIE blokują

34 wiersze, 29 wygasłych, PID-y martwe — ale to nie blokady. `hermes_state.py:2775-2778`:
```
Expired locks (expires_at < now) are reclaimed transparently:
the stale row is deleted and the new holder acquires it.
```
Nie „naprawiaj" ich ręcznym DELETE.

## 5. Limit długości sesji działa TYLKO w gateway

```
config.py:1473        "hygiene_hard_message_limit": 5000
gateway/run.py:12363  ← JEDYNE miejsce odczytu
```
**CLI (`run_agent.py`) nie ma odpowiednika.** Kompresuje po zapełnieniu kontekstu
modelu, nie po liczbie wiadomości → sesja CLI urosła do 90 037 wierszy.
`hermes config set` tego nie naprawi — to nie kwestia konfiguracji, to brak
mechanizmu w drugiej ścieżce. Ten sam wzorzec co „mechanizm istnieje dla gateway,
realna praca idzie CLI".

## 6. Pomiary, które warto powtórzyć

```bash
# Rozkład masy po miesiącach (kolumna to `timestamp` REAL, NIE created_at!)
sqlite3 <db> "SELECT substr(datetime(m.timestamp,'unixepoch'),1,7) mc,
  COUNT(DISTINCT m.session_id), COUNT(m.id), SUM(LENGTH(COALESCE(m.content,'')))
  FROM messages m GROUP BY mc ORDER BY mc DESC;"

# Ile żywych vs archiwum
sqlite3 <db> "SELECT COUNT(*), COUNT(CASE WHEN compacted=1 THEN 1 END),
  COUNT(CASE WHEN active=1 THEN 1 END) FROM messages;"

# Czy plan używa indeksu (rozstrzyga „optymalizuj czy nie")
sqlite3 <db> "EXPLAIN QUERY PLAN SELECT * FROM messages
  WHERE session_id='<id>' AND active=1;"

# Rozmiar per tabela (uwaga: dbstat bywa niedostępne — nie blokuj się)
sqlite3 <db> "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 10;"

# Po VACUUM — domknij WAL jawnie (oczekuj: 0|0|0)
sqlite3 <db> "PRAGMA wal_checkpoint(TRUNCATE);"
```

## 7. Wynik naprawy (dla porównania)

```
state.db   11,2 GB → 2,7 GB   (VACUUM, ~60 s, ZERO utraconych wiadomości)
WAL        1,1 GB → 0 B        (wal_checkpoint(TRUNCATE) → 0|0|0)
kopia      VACUUM INTO         4,91 GB, quick_check ok, 1 045 789 wiad.
```
`VACUUM` odzyskuje ~70% **bez usuwania danych** — to najbezpieczniejsza dźwignia
i powinna być pierwszą próbą, przed jakimkolwiek DELETE.
