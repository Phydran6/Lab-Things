#!/usr/bin/env bash
#
# Portainer CE via Docker – distro-unabhängiges Setup
# Annahme: Aufruf als normaler User MIT sudo-Rechten (root nicht nötig).
#
set -euo pipefail

# ----------------------------- Konfiguration --------------------------------
SERVICE_DIR="/opt/docker/portainer"      # Config / persistente Daten
UI_PORT="9443"                           # HTTPS-UI (selbstsigniertes Zert.)
IMAGE="portainer/portainer-ce:latest"
# ----------------------------------------------------------------------------

COMPOSE_FILE="${SERVICE_DIR}/docker-compose.yml"
log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# 1) Rechte / Ziel-User bestimmen --------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  TARGET_USER="${SUDO_USER:-root}"
else
  command -v sudo >/dev/null 2>&1 || { echo "sudo fehlt – bitte installieren."; exit 1; }
  SUDO="sudo"
  TARGET_USER="$(id -un)"
fi
PUID="$(id -u "$TARGET_USER")"
PGID="$(id -g "$TARGET_USER")"
log "Ziel-User: ${TARGET_USER} (UID ${PUID} / GID ${PGID})"

# 2) Voraussetzungen je nach Paketmanager ------------------------------------
log "Voraussetzungen installieren..."
if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -y && $SUDO apt-get install -y curl ca-certificates
elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y curl ca-certificates
elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y curl ca-certificates
elif command -v zypper  >/dev/null 2>&1; then $SUDO zypper -n install curl ca-certificates
elif command -v pacman  >/dev/null 2>&1; then $SUDO pacman -Sy --noconfirm curl ca-certificates
elif command -v apk     >/dev/null 2>&1; then $SUDO apk add --no-cache curl ca-certificates
else echo "Kein unterstützter Paketmanager gefunden."; exit 1
fi

# 3) Docker installieren (offizielles distro-übergreifendes Script) ----------
if command -v docker >/dev/null 2>&1; then
  log "Docker bereits vorhanden: $(docker --version)"
else
  log "Docker installieren..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

# 4) Docker-Dienst starten / aktivieren --------------------------------------
log "Docker-Dienst aktivieren..."
if   command -v systemctl >/dev/null 2>&1; then $SUDO systemctl enable --now docker
elif command -v rc-update >/dev/null 2>&1; then $SUDO rc-update add docker default || true; $SUDO rc-service docker start || true
else $SUDO service docker start || true
fi

# 5) User der docker-Gruppe hinzufügen ---------------------------------------
if [ "$TARGET_USER" != "root" ]; then
  log "User '${TARGET_USER}' zur docker-Gruppe hinzufügen..."
  $SUDO groupadd -f docker
  $SUDO usermod -aG docker "$TARGET_USER"
fi

# 6) SELinux? (Fedora/RHEL/Rocky) -> Bind-Mounts brauchen :z -----------------
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  MNT_OPT=":z"; log "SELinux enforcing erkannt – Mounts werden mit ':z' gelabelt."
else
  MNT_OPT=""
fi

# 7) Verzeichnisse + docker-compose.yml --------------------------------------
log "Verzeichnisse und docker-compose.yml anlegen..."
$SUDO mkdir -p "${SERVICE_DIR}/data"
$SUDO chown -R "${PUID}:${PGID}" "$SERVICE_DIR"

cat <<EOF | $SUDO tee "$COMPOSE_FILE" >/dev/null
services:
  portainer:
    image: ${IMAGE}
    container_name: portainer
    command: -H unix:///var/run/docker.sock
    ports:
      - ${UI_PORT}:9443
    # Edge-Agent-Tunnel (nur falls du Edge-Agents nutzt) einkommentieren:
    #  - 8000:8000
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock${MNT_OPT}
      - ${SERVICE_DIR}/data:/data${MNT_OPT}
    restart: unless-stopped
EOF
$SUDO chown "${PUID}:${PGID}" "$COMPOSE_FILE"

# 8) Auf Daemon warten + Compose-Befehl ermitteln ----------------------------
for _ in $(seq 1 15); do $SUDO docker info >/dev/null 2>&1 && break; sleep 1; done
if   docker compose version >/dev/null 2>&1;     then COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1;  then COMPOSE="docker-compose"
else echo "docker compose nicht gefunden."; exit 1
fi

# 9) Container starten – ohne Re-Login dank 'sg docker' ----------------------
log "Portainer starten (docker compose up -d)..."
if [ "$TARGET_USER" != "root" ]; then
  # 'sg docker' startet eine Sub-Shell mit aktiver docker-Gruppe ->
  # spart das Aus-/Einloggen (nicht-interaktives Pendant zu 'newgrp docker').
  sg docker -c "${COMPOSE} -f '${COMPOSE_FILE}' up -d"
else
  ${COMPOSE} -f "${COMPOSE_FILE}" up -d
fi

# Fertig ---------------------------------------------------------------------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -z "$HOST_IP" ] && HOST_IP="<server-ip>"
log "Fertig! Portainer erreichbar unter: https://${HOST_IP}:${UI_PORT}"
echo "   (selbstsigniertes Zertifikat -> Browser-Warnung ist normal)"
echo "   Daten:  ${SERVICE_DIR}/data"
echo
echo "WICHTIG: Admin-Account direkt nach dem Start anlegen – sonst sperrt sich"
echo "Portainer aus Sicherheitsgründen und der Container muss neu gestartet werden."
echo
echo "Hinweis: docker-Gruppe in DIESER Shell erst nach Neuanmeldung aktiv –"
echo "sofort ohne Re-Login nutzbar mit:  newgrp docker"
