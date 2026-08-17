#!/usr/bin/env bash
# =============================================================================
# Bedienhilfe für den Q-Matrix-Stack.
# Jeder Befehl gibt es auf Deutsch und auf Englisch.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

BOLD=$'\033[1m'; OFF=$'\033[0m'

if [[ ! -f .env ]]; then
  echo "Q-Matrix ist noch nicht eingerichtet." >&2
  echo "Bitte einmalig ausführen:  ./install.sh" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

SITE=${SITE_NAME:-qmatrix.localhost}
PORT=${HTTP_PUBLISH_PORT:-8080}

dc() { docker compose "$@"; }

usage() {
  cat <<EOF

${BOLD}Verwendung:${OFF} ./qmatrix.sh <befehl>

  ${BOLD}start${OFF}          Q-Matrix starten                      (auch: up)
  ${BOLD}stopp${OFF}          Q-Matrix anhalten, Daten bleiben      (auch: down)
  ${BOLD}neustart${OFF}       neu starten                           (auch: restart)
  ${BOLD}zustand${OFF}        läuft alles?                          (auch: status)
  ${BOLD}protokoll${OFF} [x]  Meldungen mitlesen                    (auch: logs)
  ${BOLD}sichern${OFF}        Sicherung nach ./backups/ schreiben   (auch: backup)
  ${BOLD}aktualisieren${OFF}  neu bauen, starten, migrieren         (auch: update)
  ${BOLD}zuruecksetzen${OFF}  ALLES löschen (fragt vorher nach)     (auch: reset)
  ${BOLD}hilfe${OFF}          diese Übersicht                       (auch: help)

  ${BOLD}Für Fortgeschrittene${OFF}
  migrate              Datenbank-Migration nachziehen
  konsole | console    Frappe-Python-Konsole
  shell                Kommandozeile im Container
  bench <args...>      bench ausführen, z. B.
                       ./qmatrix.sh bench --site $SITE list-apps

  Adresse: http://localhost:${PORT}

EOF
}

zugang() {
  echo
  echo "  Adresse  : ${BOLD}http://localhost:${PORT}${OFF}"
  echo "  Benutzer : ${BOLD}Administrator${OFF}"
  echo "  Passwort : ${BOLD}${ADMIN_PASSWORD}${OFF}"
  echo
}

cmd=${1:-}
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
  up|start|starten)
    # 'up -d' kehrt erst zurueck, wenn create-site fertig ist -- die uebrigen
    # Dienste warten per depends_on auf dessen Abschluss. Ein 'logs -f' wuerde
    # danach nicht zurueckkehren und den Befehl haengen lassen.
    echo "Starte (beim ersten Mal dauert die Site-Anlage ein paar Minuten) ..."
    dc up -d "$@"
    dc logs --tail=15 create-site || true
    zugang
    ;;
  down|stopp|stoppen|anhalten)
    dc down "$@"
    echo "Q-Matrix ist angehalten. Die Daten bleiben erhalten."
    echo "Wieder starten mit:  ./qmatrix.sh start"
    ;;
  restart|neustart)   dc restart "$@" ;;
  status|zustand)     dc ps ;;
  logs|protokoll)     dc logs -f --tail=100 "$@" ;;
  bench)              dc exec backend bench "$@" ;;
  shell)              dc exec backend bash ;;
  console|konsole)    dc exec backend bench --site "$SITE" console ;;
  migrate|migrieren)  dc exec backend bench --site "$SITE" migrate ;;
  update|aktualisieren)
    # Vor dem Update sichern: 'bench migrate' laeuft beim Hochfahren automatisch,
    # und ein mittendrin gescheiterter Patch hinterlaesst eine halb migrierte
    # Datenbank. Mit --no-backup abschaltbar.
    if [[ "${1:-}" == "--no-backup" ]]; then
      echo "HINWEIS: Update ohne vorherige Sicherung (--no-backup)." >&2
    elif [[ -z "$(dc ps -q backend 2>/dev/null)" ]]; then
      # Nicht stillschweigend ueberspringen -- genau dieser Fall tritt nach einem
      # Neustart des Rechners auf, und dann fehlt die Sicherung ausgerechnet
      # dann, wenn man sie am ehesten braucht.
      echo "HINWEIS: Stack läuft nicht, es wurde keine Sicherung angelegt." >&2
      echo "         Für eine Sicherung vorher: ./qmatrix.sh start && ./qmatrix.sh sichern" >&2
      echo
    else
      echo "Sichere vor dem Update ..."
      "$0" sichern
      echo
    fi
    ./build.sh --refresh
    dc up -d --force-recreate
    dc logs --tail=15 create-site || true
    zugang
    echo "Bei Problemen zurück auf den vorherigen Stand:"
    echo "  CUSTOM_TAG in .env auf den vorherigen Commit-Tag setzen, dann ./qmatrix.sh start"
    docker images "${CUSTOM_IMAGE:-qmatrix/frappe}" \
      --format "  {{.Tag}}  ({{.CreatedSince}})" | head -6
    ;;
  backup|sichern)
    mkdir -p backups
    dc exec backend bench --site "$SITE" backup --with-files
    # Backups liegen im sites-Volume; von dort herauskopieren:
    cid=$(dc ps -q backend)
    docker cp "${cid}:/home/frappe/frappe-bench/sites/${SITE}/private/backups/." ./backups/
    echo "Die Sicherung liegt im Ordner  ./backups/"
    ;;
  reset|zuruecksetzen|zurücksetzen)
    echo "ACHTUNG: Das löscht alle Mitarbeiter, Schulungen, Unterweisungen"
    echo "und hochgeladenen Dateien unwiderruflich."
    read -r -p "Wirklich ALLES löschen? Tippe 'ja' zum Bestätigen: " answer
    if [[ "$answer" == "ja" ]]; then
      dc down -v
      echo "Alles entfernt. Neu aufsetzen mit:  ./install.sh"
    else
      echo "Abgebrochen — es wurde nichts gelöscht."
    fi
    ;;
  ""|-h|--help|help|hilfe) usage ;;
  *)
    echo "Unbekannter Befehl: $cmd" >&2
    usage
    exit 1
    ;;
esac
