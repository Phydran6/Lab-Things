#!/usr/bin/env bash
#
# Open WebUI + Ollama Setup für Debian 13 (CPU-only)
# ---------------------------------------------------
# - Läuft als Docker-Compose-Projekt
# - Alle persistenten Daten unter /opt/ai-stack
# - Ollama nur lokal erreichbar, nur die Web-UI nach außen
#
# Ausführen als dedizierter User mit sudo-Rechten (root nicht nötig):
#   chmod +x setup-openwebui-ollama.sh && ./setup-openwebui-ollama.sh
#
set -euo pipefail

### Konfiguration ###############################################
BASE_DIR="/opt/ai-stack"
OPEN_WEBUI_PORT="3000"                       # Web-UI: http://<server>:PORT
OLLAMA_IMAGE="ollama/ollama:latest"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
#################################################################

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# sudo-Wrapper: als root direkt, sonst via sudo
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  die "Weder root noch sudo verfügbar."
fi

### 1. System aktualisieren #####################################
log "System-Update..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update
$SUDO apt-get -y full-upgrade

### 2. Voraussetzungen ##########################################
log "Basis-Pakete installieren..."
$SUDO apt-get install -y ca-certificates curl gnupg openssl

### 3. Docker installieren (offizielles Repo) ###################
if command -v docker >/dev/null 2>&1; then
  log "Docker bereits vorhanden – überspringe Installation."
else
  log "Docker CE installieren..."
  . /etc/os-release
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL https://download.docker.com/linux/debian/gpg \
       -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io \
       docker-buildx-plugin docker-compose-plugin
  # aktuellen User der docker-Gruppe hinzufügen (wirkt nach Neu-Login)
  [ -n "$SUDO" ] && $SUDO usermod -aG docker "$(id -un)" || true
fi

### 4. Verzeichnisstruktur unter /opt ###########################
log "Datenverzeichnisse anlegen unter ${BASE_DIR} ..."
$SUDO mkdir -p "${BASE_DIR}/ollama" "${BASE_DIR}/open-webui"

### 5. .env + docker-compose.yml schreiben ######################
log "Compose-Konfiguration schreiben..."

# Secret-Key einmalig erzeugen (bestehenden NICHT überschreiben)
ENV_FILE="${BASE_DIR}/.env"
if ! $SUDO grep -q '^WEBUI_SECRET_KEY=' "$ENV_FILE" 2>/dev/null; then
  SECRET="$(openssl rand -hex 32)"
  printf 'WEBUI_SECRET_KEY=%s\nOPEN_WEBUI_PORT=%s\n' "$SECRET" "$OPEN_WEBUI_PORT" \
    | $SUDO tee "$ENV_FILE" >/dev/null
fi

$SUDO tee "${BASE_DIR}/docker-compose.yml" >/dev/null <<EOF
services:
  ollama:
    image: ${OLLAMA_IMAGE}
    container_name: ollama
    restart: unless-stopped
    volumes:
      - ${BASE_DIR}/ollama:/root/.ollama
    ports:
      - "127.0.0.1:11434:11434"        # nur lokal (CLI/API)

  open-webui:
    image: ${WEBUI_IMAGE}
    container_name: open-webui
    restart: unless-stopped
    depends_on:
      - ollama
    ports:
      - "\${OPEN_WEBUI_PORT:-3000}:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_SECRET_KEY=\${WEBUI_SECRET_KEY}
    volumes:
      - ${BASE_DIR}/open-webui:/app/backend/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF

### 6. Stack starten ############################################
log "Images laden und Container starten..."
cd "$BASE_DIR"
$SUDO docker compose pull
$SUDO docker compose up -d

### 7. Auf Ollama warten ########################################
log "Warte auf Ollama-Dienst..."
for _ in $(seq 1 30); do
  $SUDO docker compose exec -T ollama ollama list >/dev/null 2>&1 && break
  sleep 2
done

### 8. Modellauswahl ############################################
MODELS=(
  "llama3.2:1b|~1.3 GB  – winzig, am schnellsten"
  "gemma2:2b|~1.6 GB  – sehr schnell, einfache Aufgaben"
  "llama3.2:3b|~2.0 GB  – guter Allrounder (Empfehlung)"
  "qwen3:4b|~2.6 GB  – stark & mehrsprachig"
  "gemma3:4b|~3.3 GB  – speichersparend, gute Qualität"
  "phi4-mini|~2.5 GB  – starkes Reasoning für die Größe"
  "mistral:7b|~4.4 GB  – Allzweck (langsamer auf CPU)"
  "qwen2.5-coder:7b|~4.7 GB  – fürs Programmieren (langsamer auf CPU)"
  "deepseek-r1:7b|~4.7 GB  – sichtbares Nachdenken (langsamer auf CPU)"
)

echo
echo "Verfügbare Modelle (CPU-tauglich):"
echo "-----------------------------------"
i=1
for entry in "${MODELS[@]}"; do
  printf "  %2d) %-20s %s\n" "$i" "${entry%%|*}" "${entry#*|}"
  i=$((i+1))
done
echo "   0) nichts laden / überspringen"
echo
read -rp "Nummer(n) wählen (mehrere mit Leerzeichen): " -a CHOICES

for c in "${CHOICES[@]:-0}"; do
  [[ "$c" =~ ^[0-9]+$ ]] || { warn "Ungültig: $c"; continue; }
  [ "$c" -eq 0 ] && continue
  idx=$((c-1))
  if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#MODELS[@]}" ]; then
    model="${MODELS[$idx]%%|*}"
    log "Lade Modell: $model"
    $SUDO docker compose exec -T ollama ollama pull "$model" \
      || warn "Pull fehlgeschlagen: $model"
  else
    warn "Nummer außerhalb des Bereichs: $c"
  fi
done

### 9. Fertig ###################################################
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Fertig!"
echo
echo "  Open WebUI:   http://${IP:-<server-ip>}:${OPEN_WEBUI_PORT}"
echo "                (beim ersten Aufruf Admin-Konto anlegen)"
echo
echo "  Verzeichnis:  ${BASE_DIR}"
echo "  Verwalten:    cd ${BASE_DIR} && $SUDO docker compose <ps|logs -f|restart|down>"
echo "  Modell laden: $SUDO docker compose exec ollama ollama pull <name>"
[ -n "$SUDO" ] && echo "  Hinweis:      einmal ab-/neu anmelden, dann 'docker' ohne sudo."
