#!/usr/bin/env bash
# =============================================================================
# Q-Matrix in einem Schritt installieren.
#
#   ./install.sh
#
# Das Skript erledigt alles: Passwörter erzeugen, Image bauen, Stack starten.
# Es kann jederzeit erneut ausgeführt werden, ohne Daten zu zerstören.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

titel()  { echo; echo "${BOLD}$1${OFF}"; }
ok()     { echo "  ${GREEN}✓${OFF} $1"; }
info()   { echo "    $1"; }
abbruch() {
  echo
  echo "${RED}${BOLD}Abbruch:${OFF} $1"
  shift
  for zeile in "$@"; do echo "  $zeile"; done
  echo
  exit 1
}

echo
echo "${BOLD}=====================================${OFF}"
echo "${BOLD}  Q-Matrix — Installation${OFF}"
echo "${BOLD}=====================================${OFF}"

# -----------------------------------------------------------------------------
# 1. Voraussetzungen prüfen
# -----------------------------------------------------------------------------
titel "1/4  Voraussetzungen prüfen"

if ! command -v docker >/dev/null 2>&1; then
  abbruch "Docker ist nicht installiert." \
    "Docker Desktop hier herunterladen und installieren:" \
    "  https://www.docker.com/products/docker-desktop/" \
    "Danach dieses Skript erneut starten:  ./install.sh"
fi
ok "Docker ist installiert"

if ! docker info >/dev/null 2>&1; then
  abbruch "Docker läuft gerade nicht." \
    "Bitte das Programm 'Docker Desktop' starten, warten bis es meldet," \
    "dass es läuft, und dieses Skript erneut ausführen:  ./install.sh"
fi
ok "Docker läuft"

if ! docker compose version >/dev/null 2>&1; then
  abbruch "Die benötigte Docker-Erweiterung 'Compose' fehlt." \
    "Meist hilft es, Docker Desktop auf die aktuelle Version zu aktualisieren."
fi
ok "Docker Compose ist verfügbar"

# -----------------------------------------------------------------------------
# 2. Konfiguration anlegen
# -----------------------------------------------------------------------------
titel "2/4  Konfiguration vorbereiten"

zufall() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

if [[ -f .env ]]; then
  ok "Konfiguration (.env) ist bereits vorhanden — wird beibehalten"
else
  [[ -f .env.example ]] || abbruch "Die Vorlage .env.example fehlt." \
    "Das Verzeichnis scheint unvollständig zu sein."

  ADMIN_PW="Qmatrix$(zufall 12)"
  DB_PW="$(zufall 24)"
  sed -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PW}|" \
      -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PW}|" \
      .env.example > .env
  chmod 600 .env
  ok "Konfiguration (.env) erzeugt, sichere Passwörter automatisch vergeben"
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

APP_NAME=${APP_NAME:-qmatrix}
APP_SOURCE=${APP_SOURCE:-local}
APP_BRANCH=${APP_BRANCH:-main}
CUSTOM_IMAGE=${CUSTOM_IMAGE:-qmatrix/frappe}
CUSTOM_TAG=${CUSTOM_TAG:-16}
PORT=${HTTP_PUBLISH_PORT:-8080}
SITE=${SITE_NAME:-qmatrix.localhost}

# Der Build klont die App aus apps-local/<app>. Ohne Git-Repository dort schlägt
# das fehl -- das legen wir bei Bedarf selbst an, damit niemand Git bedienen muss.
if [[ "$APP_SOURCE" == "local" ]]; then
  APP_DIR="apps-local/${APP_NAME}"
  if [[ -d "$APP_DIR" && ! -d "${APP_DIR}/.git" ]]; then
    info "Bereite ${APP_DIR} für den Build vor ..."
    git -C "$APP_DIR" init -q -b "$APP_BRANCH"
    git -C "$APP_DIR" add -A
    git -C "$APP_DIR" -c user.name="Q-Matrix Setup" \
        -c user.email="setup@localhost" commit -q -m "Initialer Stand"
    ok "App-Verzeichnis vorbereitet"
  elif [[ ! -d "$APP_DIR" ]]; then
    abbruch "Der App-Ordner ${APP_DIR} fehlt." \
      "Er muss den Quellcode der Q-Matrix-App enthalten."
  else
    ok "App-Quellcode gefunden"
  fi
fi

# -----------------------------------------------------------------------------
# 3. Image bauen
# -----------------------------------------------------------------------------
titel "3/4  Programm bauen"

if docker image inspect "${CUSTOM_IMAGE}:${CUSTOM_TAG}" >/dev/null 2>&1; then
  ok "Fertiges Image ist schon vorhanden — Bauen wird übersprungen"
  info "Neu bauen (nach Code-Änderungen):  ./qmatrix.sh update"
else
  info "Das dauert beim ersten Mal 10–20 Minuten. Kaffee holen ist erlaubt."
  info "Es werden Frappe 16 und die Q-Matrix-App aus dem Internet geladen."
  echo
  if ! ./build.sh; then
    abbruch "Das Bauen ist fehlgeschlagen." \
      "Häufigste Ursache: keine Internetverbindung oder zu wenig Speicherplatz." \
      "Docker Desktop braucht mindestens 10 GB freien Speicher."
  fi
  ok "Image gebaut"
fi

# -----------------------------------------------------------------------------
# 4. Starten
# -----------------------------------------------------------------------------
titel "4/4  Q-Matrix starten"
info "Beim ersten Start wird die Datenbank angelegt — das dauert 1–3 Minuten."
echo

docker compose up -d
# Kein 'logs -f': Das kehrt nicht zurueck, wenn der verfolgte Container endet.
# 'up -d' wartet ohnehin auf create-site, ein einmaliges Nachsehen genuegt.
docker compose logs --tail=15 create-site 2>/dev/null || true

# Warten, bis die Anwendung wirklich antwortet.
echo
info "Warte, bis die Anwendung erreichbar ist ..."
bereit=0
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${PORT}/login" || echo "000")
  if [[ "$code" == "200" ]]; then bereit=1; break; fi
  sleep 5
done

echo
if [[ $bereit -eq 1 ]]; then
  ok "Q-Matrix läuft"
else
  echo "  ${YELLOW}!${OFF} Die Anwendung antwortet noch nicht."
  echo "    Das kann bei langsamen Rechnern vorkommen. Status prüfen mit:"
  echo "      ./qmatrix.sh status"
  echo "      ./qmatrix.sh logs backend"
fi

echo
echo "${BOLD}=====================================${OFF}"
echo "${BOLD}  Fertig${OFF}"
echo "${BOLD}=====================================${OFF}"
echo
echo "  Adresse   : ${BOLD}http://localhost:${PORT}${OFF}"
echo "  Benutzer  : ${BOLD}Administrator${OFF}"
echo "  Passwort  : ${BOLD}${ADMIN_PASSWORD}${OFF}"
echo
echo "  Diese Zugangsdaten stehen auch in der Datei .env"
echo
echo "  ${BOLD}DeepL-Übersetzung einrichten${OFF} (optional):"
echo "    Im Menü auf 'Q-Matrix' → 'DeepL Einstellungen' den API-Key eintragen."
echo "    Einen kostenlosen Key gibt es unter:"
echo "      https://www.deepl.com/pro-api"
echo
echo "  ${BOLD}Weitere Befehle${OFF}"
echo "    ./qmatrix.sh stopp     Q-Matrix anhalten (Daten bleiben erhalten)"
echo "    ./qmatrix.sh start     wieder starten"
echo "    ./qmatrix.sh sichern   Sicherung nach ./backups/ schreiben"
echo "    ./qmatrix.sh hilfe     alle Befehle anzeigen"
echo

if command -v open >/dev/null 2>&1; then
  open "http://localhost:${PORT}" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "http://localhost:${PORT}" >/dev/null 2>&1 || true
fi
