#!/usr/bin/env bash
#
# Wazuh (Single-Node) via Docker – distro-unabhängiges Setup
# Nutzt das OFFIZIELLE wazuh/wazuh-docker Repo (Manager + Indexer + Dashboard).
# Annahme: Aufruf als normaler User MIT sudo-Rechten (root nicht nötig).
#
set -euo pipefail

# ----------------------------- Konfiguration --------------------------------
SERVICE_DIR="/opt/docker/wazuh"          # hierhin wird das Repo geklont
WAZUH_VERSION=""                         # leer = neueste Release automatisch; sonst z.B. v4.14.5
FALLBACK_VERSION="v4.14.5"               # falls Auto-Ermittlung fehlschlägt
REPO="https://github.com/wazuh/wazuh-docker.git"
# ----------------------------------------------------------------------------

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# Befehl in der docker-Gruppe ausführen – ohne Re-Login (Pendant zu 'newgrp docker')
drun() { if [ "$TARGET_USER" != "root" ]; then sg docker -c "$1"; else bash -c "$1"; fi; }

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

# 2) Voraussetzungen je nach Paketmanager (inkl. git!) -----------------------
log "Voraussetzungen installieren..."
if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -y && $SUDO apt-get install -y curl ca-certificates git
elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y curl ca-certificates git
elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y curl ca-certificates git
elif command -v zypper  >/dev/null 2>&1; then $SUDO zypper -n install curl ca-certificates git
elif command -v pacman  >/dev/null 2>&1; then $SUDO pacman -Sy --noconfirm curl ca-certificates git
elif command -v apk     >/dev/null 2>&1; then $SUDO apk add --no-cache curl ca-certificates git
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

# 6) RAM-Check (Wazuh-Indexer ist hungrig) -----------------------------------
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${MEM_KB:-0}" -lt 4000000 ]; then
  log "ACHTUNG: nur ~$((MEM_KB/1024/1024)) GB RAM erkannt – Wazuh-Indexer braucht realistisch >=4 GB, sonst crasht der Stack. Mache trotzdem weiter."
fi

# 7) Kernel-Parameter für den Indexer (OpenSearch) ---------------------------
log "vm.max_map_count=262144 setzen (persistent)..."
echo 'vm.max_map_count=262144' | $SUDO tee /etc/sysctl.d/99-wazuh.conf >/dev/null
$SUDO sysctl -p /etc/sysctl.d/99-wazuh.conf >/dev/null

# 8) Neueste Wazuh-Version ermitteln -----------------------------------------
if [ -z "$WAZUH_VERSION" ]; then
  log "Neueste Wazuh-Version ermitteln..."
  WAZUH_VERSION="$(git ls-remote --tags --refs "$REPO" 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1)"
  [ -z "$WAZUH_VERSION" ] && WAZUH_VERSION="$FALLBACK_VERSION"
fi
log "Version: ${WAZUH_VERSION}"

# 9) Repo klonen / auschecken ------------------------------------------------
$SUDO mkdir -p "$SERVICE_DIR"
$SUDO chown "${PUID}:${PGID}" "$SERVICE_DIR"
if [ -d "${SERVICE_DIR}/.git" ]; then
  log "Repo vorhanden – wechsle auf ${WAZUH_VERSION}..."
  git -C "$SERVICE_DIR" fetch --tags -q || true
  git -C "$SERVICE_DIR" checkout -q "$WAZUH_VERSION"
else
  log "wazuh-docker klonen..."
  git clone --depth 1 -b "$WAZUH_VERSION" "$REPO" "$SERVICE_DIR"
fi
$SUDO chown -R "${PUID}:${PGID}" "$SERVICE_DIR"
WORKDIR="${SERVICE_DIR}/single-node"

# 10) Auf Daemon warten + Compose-Befehl ermitteln ---------------------------
for _ in $(seq 1 15); do $SUDO docker info >/dev/null 2>&1 && break; sleep 1; done
if   docker compose version >/dev/null 2>&1;     then COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1;  then COMPOSE="docker-compose"
else echo "docker compose nicht gefunden."; exit 1
fi

# 11) Zertifikate generieren (idempotent) ------------------------------------
if [ -f "${WORKDIR}/config/wazuh_indexer_ssl_certs/root-ca.pem" ]; then
  log "Zertifikate vorhanden – Generierung übersprungen."
else
  log "Zertifikate generieren..."
  drun "cd '${WORKDIR}' && ${COMPOSE} -f generate-indexer-certs.yml run --rm generator"
fi

# 12) Stack starten – ohne Re-Login dank 'sg docker' -------------------------
log "Wazuh-Stack starten (docker compose up -d)..."
drun "cd '${WORKDIR}' && ${COMPOSE} up -d"

# Fertig ---------------------------------------------------------------------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -z "$HOST_IP" ] && HOST_IP="<server-ip>"
log "Fertig! Wazuh-Dashboard: https://${HOST_IP}"
echo "   (Port 443, selbstsigniert -> Browser-Warnung normal; Hochfahren dauert 1-2 Min.)"
echo "   Default-Login:  admin / SecretPassword   <-- SOFORT ändern! (steht in docker-compose.yml)"
echo "   Stack:  ${WORKDIR}"
echo
echo "Status:  cd ${WORKDIR} && ${COMPOSE} ps"
echo "Hinweis 1: Port 443 belegt (z.B. durch NPM auf gleichem Host)? -> Dashboard-Port in"
echo "           ${WORKDIR}/docker-compose.yml anpassen."
echo "Hinweis 2: docker-Gruppe in dieser Shell erst nach Re-Login aktiv -> sonst: newgrp docker"
