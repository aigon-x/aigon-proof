# Przebieg 2026-10-17 (AIGON-X runtime): dowody i czasy

Wszystko poniżej zmierzone w jednej sesji, na `<workspace>`, runtime Rust + Docker.

## 1. Zmiana w bibliotece → binarka (dwuetapowy build)

```
cargo check -p aigon-runtime --lib                     41 s   (rc=0 — łapie błędy przed 26-min buildem)
cargo build --release -p aigon-runtime-bin --bin aigon-runtime -j2   26m34s (pierwszy)
                                                                      28m05s (drugi, z drobną poprawką)
```

Czasy mtime (dowód, że biblioteka NAPRAWDĘ się przebudowała — bez tego binarka może
linkować stary rlib):

```
runtime/crates/aigon-runtime/src/api.rs            13:50
runtime/target/release/deps/libaigon_runtime-*.rlib 14:01   (fingerprint 13:53)
runtime/target/release/aigon-runtime                14:19   (md5 8f045fd8d0ade3ae1f9368f4dd8161b7)
```

## 2. Łańcuch tożsamości artefaktu

```bash
cd <workspace>/runtime
docker build -f Dockerfile.local -t 127.0.0.1:55000/aigon-core-runtime:production .
# kontekst build = katalog runtime/ (NIE repo) — inaczej COPY target/... nie znajdzie pliku
md5sum target/release/aigon-runtime                                                    # 8f045...
docker run --rm --entrypoint md5sum <image> /usr/local/bin/aigon-runtime               # 8f045...
docker compose -p aigon-green up -d --force-recreate --no-deps runtime
docker exec aigon-core-runtime md5sum /usr/local/bin/aigon-runtime                     # 8f045...
```
Trzy identyczne hashe = proces naprawdę uruchomił tę binarkę.

## 3. `strings` = 0 przy kodzie, który JEST w binarce

```bash
strings runtime/target/release/aigon-runtime | grep -c instrumentation   # 0  (!)
grep -a -c instrumentation runtime/target/release/aigon-runtime          # 0  (!)
# a runtime po wdrożeniu:
curl -sk -H "X-API-Key: $S" https://localhost:7000/api/v1/self/components \
 | python3 -c "import sys,json;d=json.load(sys.stdin);e=[c for c in d['components'] if c.get('provenance')!='kernel'];print(len(e), sum(1 for c in e if c.get('instrumentation')=='none'))"
# 46 46   <- zmiana JEST; wniosek ze strings był fałszywy
```

## 4. `theory_dir`: konfiguracja, nie binarka

```
log: [TheoryRegistry] load failed from "<workspace>/theory/v1.0/solon_registry.json":
     Failed to load SOLON registry: Not a directory (os error 20)
```
Przyczyna: `api.rs` wołał `load_from_path(dir.join("solon_registry.json"))`, a
`load_from_path` deleguje do `load_from_theory_dir(dir)`, które samo dokleja nazwy plików.
Poprawka: `TheoryRegistry::load_from_theory_dir(dir)`.
Po wdrożeniu: `GET /api/v1/registry/entries` = **200, count=392**,
log: `[TheoryRegistry] loaded 392 entries from "<workspace>/theory/v1.0"`.

## 5. Okno bootu

```
proba 1..11: HTTP=503 (runtime_boot_in_progress)   ~110 s
proba 12:    HTTP=200
```
W całym oknie `docker ps` = `Up (healthy)` i `/health` = 200 z `boot_phase: running`.

## 6. Kolejność weryfikacji po wdrożeniu (skrót)

```bash
# 1 tożsamość
md5sum target/release/<bin>; docker exec <c> md5sum /usr/local/bin/<bin>
# 2 gotowość API (nie /health)
until [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' -H "X-API-Key: $S" https://localhost:7000/api/v1/kernels)" = 200 ]; do sleep 10; done
# 3 SKUTEK
curl -sk -H "X-API-Key: $S" https://localhost:7000/health | python3 -m json.tool | head -20
# 4 brak regresji na ścieżce, którą zmieniałeś
```
