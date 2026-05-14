#!/usr/bin/env bash
###############################################################################
# Plex Deployment via Docker Compose
# Ziel: Ubuntu Server LTS (22.04 / 24.04)
# Ausführen als User mit sudo-Rechten (NICHT root).
#
# Macht:
#   - System-Update
#   - Docker CE + Compose-Plugin (falls nicht vorhanden)
#   - cifs-utils (für spätere SMB-Mounts)
#   - /opt/docker/plex Struktur + docker-compose.yml
#   - Plex-Container starten (host networking, linuxserver-Image)
#
# Mount-Verwaltung (SMB/CIFS) NICHT enthalten - manuell via fstab oder
# Webmin/Cockpit nach Bedarf nachziehen. /mnt ist mit rslave-Propagation
# durchgereicht, später hinzugefügte Mounts werden im Container sichtbar.
###############################################################################

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -------- Farben / Logging --------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
info()  { echo -e "${B}[INFO]${N} $*"; }
ok()    { echo -e "${G}[OK]${N}   $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*"; }
fail()  { echo -e "${R}[FAIL]${N} $*" >&2; exit 1; }
step()  { echo; echo -e "${B}==> $*${N}"; }

# -------- Preflight --------
[[ -f /etc/os-release ]] || fail "/etc/os-release fehlt."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Skript ist für Ubuntu getestet (erkannt: ${ID:-unknown})."

# Ziel-User ermitteln: bei 'sudo bash ...' ist SUDO_USER der echte User.
# Bei direktem Root-Login fallen wir auf root zurück (mit Warnung).
if [[ $EUID -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        CURRENT_USER="$SUDO_USER"
    else
        warn "Skript läuft als echter root (kein SUDO_USER). Plex wird unter UID/GID 0 laufen."
        CURRENT_USER="root"
    fi
    SUDO=""   # bereits root, sudo unnötig
else
    sudo -v || fail "sudo-Rechte werden benötigt."
    CURRENT_USER="$(whoami)"
    SUDO="sudo"
    # Sudo-Session warmhalten
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill ${SUDO_KEEPALIVE_PID} 2>/dev/null || true' EXIT
fi

PUID="$(id -u "$CURRENT_USER")"
PGID="$(id -g "$CURRENT_USER")"
info "Ziel-User: ${CURRENT_USER} (UID=${PUID}, GID=${PGID})"

# -------- Interaktive Abfragen --------
echo
echo "======================================================================="
echo "  Plex Deployment - Konfiguration"
echo "======================================================================="
echo
read -rp "Zeitzone [Europe/Berlin]: " TZ_INPUT
TZ_VAL="${TZ_INPUT:-Europe/Berlin}"

echo
echo "Plex Claim Token (optional, holen unter https://www.plex.tv/claim - 4 Min gültig)"
echo "Leer lassen = Server später im LAN über Web-UI claimen."
read -rp "PLEX_CLAIM: " PLEX_CLAIM_TOKEN

echo
read -rp "Image-Tag [latest]: " IMAGE_TAG
IMAGE_TAG="${IMAGE_TAG:-latest}"

# -------- 1. System-Update --------
step "1/5  System-Update"
$SUDO apt-get update -qq
$SUDO apt-get -y upgrade
$SUDO apt-get install -y ca-certificates curl gnupg lsb-release cifs-utils
ok "System aktualisiert."

# -------- 2. Docker installieren (falls nicht vorhanden) --------
step "2/5  Docker + Compose-Plugin"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose bereits vorhanden ($(docker --version))."
else
    info "Installiere Docker CE..."
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io \
                            docker-buildx-plugin docker-compose-plugin
    $SUDO systemctl enable --now docker
    ok "Docker installiert."
fi

# User in docker-Gruppe (nur sinnvoll, wenn nicht root)
NEEDS_RELOGIN=false
if [[ "$CURRENT_USER" != "root" ]] && ! id -nG "$CURRENT_USER" | grep -qw docker; then
    $SUDO usermod -aG docker "$CURRENT_USER"
    NEEDS_RELOGIN=true
    info "User ${CURRENT_USER} zur docker-Gruppe hinzugefügt."
fi

# docker compose Aufruf-Wrapper:
# - root: direkt
# - non-root, bereits in docker-Gruppe (vor Skriptstart): direkt
# - non-root, gerade erst hinzugefügt: via 'sg docker -c "..."' (Gruppe in Subshell aktivieren)
dc() {
    if [[ "$CURRENT_USER" == "root" ]] || { id -nG "$CURRENT_USER" | grep -qw docker && ! $NEEDS_RELOGIN; }; then
        docker compose "$@"
    else
        sg docker -c "docker compose $*"
    fi
}

# -------- 3. Verzeichnisse --------
step "3/5  Verzeichnisse anlegen"
$SUDO mkdir -p /opt/docker
$SUDO chown "$CURRENT_USER:$CURRENT_USER" /opt/docker
$SUDO mkdir -p /opt/docker/plex/config /opt/docker/plex/transcode
$SUDO chown -R "$CURRENT_USER:$CURRENT_USER" /opt/docker/plex
$SUDO mkdir -p /mnt/media
$SUDO chown "$CURRENT_USER:$CURRENT_USER" /mnt/media || true
ok "Verzeichnisse unter /opt/docker/plex und /mnt/media bereit."

# -------- 4. docker-compose.yml generieren --------
step "4/5  docker-compose.yml schreiben"
$SUDO tee /opt/docker/plex/docker-compose.yml >/dev/null <<EOF
services:
  plex:
    image: lscr.io/linuxserver/plex:${IMAGE_TAG}
    container_name: plex
    network_mode: host
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ_VAL}
      - VERSION=docker
$([ -n "$PLEX_CLAIM_TOKEN" ] && echo "      - PLEX_CLAIM=${PLEX_CLAIM_TOKEN}")
    volumes:
      - ./config:/config
      - ./transcode:/transcode
      # rslave: SMB-Mounts, die später auf dem Host unter /mnt/... eingehängt
      # werden, sind dadurch automatisch auch im Container sichtbar.
      - /mnt:/mnt:rslave
EOF
$SUDO chown "$CURRENT_USER:$CURRENT_USER" /opt/docker/plex/docker-compose.yml
ok "/opt/docker/plex/docker-compose.yml erstellt."

# -------- 5. Container starten --------
step "5/5  Plex-Container pullen + starten"
cd /opt/docker/plex
dc pull
dc up -d
ok "Plex läuft."

# -------- Zusammenfassung --------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$HOST_IP" ]] && HOST_IP="<server-ip>"

echo
echo "======================================================================="
echo -e "${G}  FERTIG${N}"
echo "======================================================================="
echo
echo -e "  Plex       :  http://${HOST_IP}:32400/web"
[ -z "$PLEX_CLAIM_TOKEN" ] && echo "                (auf https://app.plex.tv claimen, da kein Token gesetzt)"
echo
echo "  Pfade:"
echo "    /opt/docker/plex/         - Compose + config + transcode"
echo "    /mnt/media/               - vorgesehen für SMB-Mounts (Webmin/fstab)"
echo
echo "  Update:    cd /opt/docker/plex && docker compose pull && docker compose up -d"
echo "  Logs:      docker logs -f plex"
echo "  Stop:      cd /opt/docker/plex && docker compose down"
echo
$NEEDS_RELOGIN && {
echo -e "${Y}HINWEIS:${N} '${CURRENT_USER}' wurde der docker-Gruppe hinzugefügt."
echo "         Für 'docker'-Befehle ohne sudo in der aktuellen Shell:"
echo "           newgrp docker         # neue Subshell mit aktiver docker-Gruppe"
echo "         Oder einmal abmelden + neu einloggen (dauerhaft)."
}
echo "======================================================================="
