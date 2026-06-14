# Lab-Things

Eine Sammlung kleiner, eigenständiger Skripte und Snippets fürs Homelab –
gedacht für Dinge, die kein eigenes Projekt rechtfertigen. Jede Datei ist
in sich abgeschlossen und kann unabhängig verwendet werden.

## Inhalt

| Skript | Beschreibung | Zielsystem |
| ------ | ------------ | ---------- |
| [`plex-docker-compose.sh`](plex-docker-compose.sh) | Plex Media Server via Docker Compose ausrollen (Docker-Installation, Verzeichnisse, Compose-Datei, Container-Start). | Ubuntu Server LTS (22.04 / 24.04) |
| [`setup-openwebui-ollama.sh`](setup-openwebui-ollama.sh) | Open WebUI + Ollama als CPU-only Docker-Stack aufsetzen (Ollama nur lokal, nur die Web-UI nach außen). | Debian 13 (CPU-only) |
| [`emby-docker-compose.sh`](emby-docker-compose.sh) | Emby Media Server via Docker Compose ausrollen (Docker-Installation, Verzeichnisse, Compose-Datei, Container-Start). | Distro Unabhängig
| [`portainer-docker.sh`](install-docker.sh) | Portainer Instanz via Docker Compose ausrollen (Docker-Installation, Verzeichnisse, Compose-Datei, Container-Start). | Distro Unabhängig


## Verwendung

Skripte sind in der Regel interaktiv und auf ein konkretes Zielsystem
ausgelegt. Vor dem Ausführen am besten kurz reinschauen, damit klar ist,
was passiert. Allgemeines Muster:

```bash
chmod +x <skript>.sh
./<skript>.sh
```

Die meisten Skripte benötigen einen User mit `sudo`-Rechten (nicht root)
und sind für Debian/Ubuntu-basierte Systeme gedacht.

## Konventionen

- Bash mit `set -euo pipefail`
- Kommentierter Header pro Skript: Zweck, Zielsystem, Voraussetzungen
- Farbiges Logging (`info` / `ok` / `warn` / `fail`)
- Persistente Daten unter `/opt/...`

## Beitragen

Neues Skript? Datei mit sprechendem Namen anlegen, Header-Kommentar
ergänzen, in der Tabelle oben eintragen und im [`CHANGELOG.md`](CHANGELOG.md)
vermerken.

## Lizenz

[MIT](LICENSE)
