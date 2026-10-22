# Strażnik/remediacja wychodzi poza SWÓJ ZAKRES przez symlink (2026-10-01)

Podklasa autorstwa strażnika: **nie kłamie, ale niszczy — bo działa poza
obszarem, który miał pilnować.** Zmierzone na produkcji AIGON; szkoda była
OGÓLNOHOSTOWA, nie lokalna.

## Objaw (myli z „system się rozsypał")

```
RC=126  w całej flocie cronów   ← brak prawa wykonania
hook-runner: /home/operator/.local/bin/python3: Brak dostępu
```

`python3` przestał się uruchamiać — **także dla roota**: bez bitu `+x` `execve`
zwraca `EACCES` niezależnie od uid.

## Przyczyna (mechanizm, nie „jakaś awaria")

```
/usr/bin/python3.12            -rw-r--r-- aigon:aigon   ← BYŁO root:root 755
<workspace>/.venv-ytdlp/bin/python3 -> /usr/bin/python3   ← symlink w drzewie repo
```

Auto-remediacja bramki `file-permissions-check` (reaktor, cron) uruchamiała
`scripts/audit-fileperm.py --apply`, który chodził `os.walk` po repo i dla
każdego wpisu robił `chmod`/`chown`. `os.walk` widzi symlink jako **plik**,
a **`chmod`/`chown` na symlinku działa na CELU** → „naprawa uprawnień w repo"
przestawiła SYSTEMOWĄ binarkę.

Drugi, niezależny mechanizm robiący to samo (czysty `chown`, cron `*/20`):
`scripts/enforce-ownership-canon.sh` — `find … ! -uid CANON -gid CANON` testuje
własność DOWIĄZANIA (lstat), ale `chown` i tak idzie za nim.

## Pomiar przed/po (dowód, nie deklaracja)

```
PRZED: "naprawiono 6357 plików (chmod + chown aigon:aigon)"
PO:    "naprawiono 4 plików";  ctime /usr/bin/python3.12 NIETKNIĘTY
       stat -c '%a %U:%G' /usr/bin/python3.12  →  755 root:root (przed i po)
```

Spadek 6357 → 4 to nie kosmetyka: wcześniej „naprawa" w kółko dokładała ten sam
systemowy plik do listy naruszeń, bo jego CEL wracał na listę po każdej zmianie.

## Naprawa (KISS — jedno miejsce na klasę)

```python
# audit-fileperm.py — w walk()
if os.path.isfile(base) and not os.path.islink(base): yield base
dirnames[:] = [d for d in dirnames if … and not os.path.islink(os.path.join(dirpath, d))]
…
full = os.path.join(dirpath, fn)
if os.path.islink(full): continue          # ← sedno
yield full
```

```bash
# enforce-ownership-canon.sh — po stronie FIND, nie po stronie chown
find "$ROOT" … ! -type l ! -uid "$CANON_UID" -gid "$CANON_GID" -print0
```

## Bramka końcowa dla KAŻDEGO skryptu rekurencyjnego

- [ ] Czy przechodzi po PLIKACH czy po DOWIĄZANIACH? (`find` bez `-type l`,
      `os.walk` bez `islink`) — inaczej operacja wyjdzie poza swój korzeń.
- [ ] Czy korzeń jest ZAMKNIĘTY? (`ROOT=<workspace>` — sprawdź, czy coś nie
      prowadzi na zewnątrz).
- [ ] Czy istnieje niezależny strażnik CELÓW? (tu:
      `tools/gates/domains/system-bin-perms-guard.sh` — binarki `/usr/bin`
      i `/usr/local/bin` mają `+x` i właściciela root). **Sam strażnik musi być
      W CRONIE** — ten istniał, ale chodził tylko przy okazji verify/hooków,
      więc nie złapał. Strażnik nieautomatyczny = brak strażnika.
- [ ] Test negatywny: zasymuluj plik-przynętę i sprawdź, że skrypt go NIE rusza.

## Reguła klasowa

**Automatyczna naprawa bez zamkniętego zakresu jest groźniejsza niż brak
naprawy** — bo działa szybko, wszędzie i cicho. Ogranicz zakres po stronie
PRZEGLĄDANIA (walk/find), nie po stronie AKCJI (chmod/chown): wtedy nie ma
czego cofać.
