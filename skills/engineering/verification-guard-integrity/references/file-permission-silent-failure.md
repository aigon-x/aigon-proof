# Uprawnienia pliku jako cichy fałszywy zielony (zmierzone 2026-09-30)

Klasa: strażnik/guard/generator METRYKI zapisuje plik, ale **cicho nie ustawia
właściciela/praw** — więc konsument (node_exporter, Prometheus, inny proces)
go nie odczyta. Objaw: guard raportuje sukces, metryki „są", a w rzeczywistości
nie ma ich w systemie albo stan zależy od tego, KTO uruchomił skrypt.

## Trzy warstwy tej samej pułapki

Wszystkie zmierzone w jednym pliku (`scripts/ollama-model-guard.sh`), każda
wygląda na „naprawiłem", a nie naprawia:

```bash
# uruchomione jako sniegul, plik docelowy był root-owned:
mv ${OUT}.tmp $OUT              # → 664 sniegul:sniegul  (mv zachowuje właściciela tmp)
sudo -n chown root:root $OUT    # → 664 root:root        (właściciel OK, prawa NIE)
chmod 644 $OUT || true          # → NADAL 664!  rc≠0, połknięte przez || true
```

**Kluczowe:** `chmod` wykonany jako nie-root na pliku root-owned **ZAWSZE zawodzi**.
Jeśli wołasz go przez `|| true` (a tak robi większość skryptów typu `... || true`),
dostajesz cichą porażkę — `chown` przez sudo zmienił właściciela, ale prawa
zostały stare.

## Reguła

Jeśli JEDNA operacja wymaga uprawnień roota, DRUGA (zależna od niej) też.
Nie mieszaj `sudo chown` z gołym `chmod`.

```bash
if [ "$(id -u)" = "0" ]; then
  chown root:root "$OUT" 2>/dev/null || true
  chmod 644 "$OUT"       2>/dev/null || true
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n chown root:root "$OUT" 2>/dev/null || true
  sudo -n chmod 644 "$OUT"       2>/dev/null || true   # OBA przez sudo
else
  chmod 644 "$OUT" 2>/dev/null || true                 # brak roota: co umask dał
fi
```

`sudo -n true` w warunku jest istotne — bez `-n` sudo może zawisnąć na promptcie
hasła i zablokować skrypt w cronie.

## Sygnatura rozpoznawcza

| objaw | znaczenie |
|---|---|
| plik `644 sniegul:sniegul` mimo `chown root:root` w kodzie | gałąź `id -u = 0` nie zaszła (uruchomione jako user) |
| plik `664 root:root` (dobry właściciel, złe prawa) | `chown` przez sudo zadziałał, `chmod` NIE |
| `664` zamiast `644` w ogóle | umask grupy (np. `aigon` = `0002`) — potrzeba jawnego `chmod` |
| stan pliku zależy od tego, kto uruchomił | brak rozwidlenia root/nie-root |

## Dlaczego to jest fałszywy zielony

Plik `644` jest czytelny dla `o+r`, więc node_exporter działający jako `nobody`
**i tak go odczyta** — metryki działają. Ale:
- stan właściciela jest nieprzewidywalny między uruchomieniami,
- test pilnujący właściciela (słusznie) FAIL-uje przy ręcznym uruchomieniu,
- przy `640`/`600` (gdyby umask był ostrzejszy) metryka **zniknęłaby** bez śladu.

Reguła ogólna: guard, który **raportuje sukces**, a nie sprawdza, czy jego
artefakt jest FAKTYCZNIE czytelny dla konsumenta, daje fałszywe poczucie
kontroli. Dorzuć do testu strażnika asercję na właściciela I prawa artefaktu.

## Powiązane pułapki zmierzone w tej samej sesji

- **`pgrep -f <wzorzec>` łapie WŁASNĄ komendę** — `pgrep -f thunderbird` zwrócił
  „żyje" dla zamkniętego Thunderbirda, bo złapał `bash -c ... pgrep -f thunderbird`.
  Używaj `ps -eo comm | grep -qx "<nazwa-binarki>"` (po NAZWIE procesu).
  Uwaga na nazwę binarki: snap Thunderbird = `thunderbird-bin`, nie `thunderbird`.
- **Ładowanie nieistniejącej biblioteki przez `[ -r "$TF" ] && . "$TF"`** —
  warunek jest fałszywy, test wpada we własny fallback, asercje drukują PASS,
  ale nie powstaje `test-results.json` → brama: `[ERROR] FALSE GATE`.
  Sprawdź ścieżkę źródłowania przeciw działającemu wzorcowi z tego samego katalogu.
- **Rozjazd budżetów czasu** — test daje `timeout 240`, a podległy skrypt ma
  wewnętrzne `timeout` sumujące się do ~330 s → skrypt ubijany w połowie →
  raz ERROR, raz PASS. Policz: `grep -nE 'timeout [0-9]+'` w obu plikach.
