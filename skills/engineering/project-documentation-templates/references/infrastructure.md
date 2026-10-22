# Szablon: Infrastruktura / runtime / mesh

## 1. Cel + topologia
- Co to za stack (mesh, docker compose, MCP, mail), nodu/wezly, źródło prawdy.

## 2. Usługi / komponenty
- Tabela: kontener, port, rola, profil, healthcheck, zależności.

## 3. Sieć / porty / tunele
- Porty (publiczne vs loopback), tunele (Cloudflare/Tailscale), routing, ingress.

## 4. Konfiguracja (SSOT)
- Gdzie leży config (config/cron.yaml, compose, .env), jak się propaguje (potok, nie kopie).

## 5. Sekrety
- Vault (ścieżki, jak czytać), co gdzie, rotacja.

## 6. Automatyzacja (cron/self-heal/backup)
- Crony (schedule + co robią), watchdogi, backupy (kiedy/gdzie), self-heal.

## 7. Monitoring / alerty
- Prometheus/Alertmanager (reguły, trasy), Grafana (dashboards), OTel/Tempo.

## 8. Deploy
- Jak wdrożyć (build + up -d, recreate), zero-downtime, rollback.

## 9. Runbook awarii
- Co robić gdy: kontener unhealthy, tunel padł, backup się nie zrobił, mail nie wychodzi.

## 10. Pułapki / kanon
- Co jest KANONICZNE (nie usuwać), znane defekty klas (np. symlinki w <workspace>, duplikaty definicji prawdy).
