#!/usr/bin/env bash
# =============================================================================
# Baut das Frappe-16-Image inklusive der Q-Matrix-App (qmatrix).
#
#   ./build.sh              # normaler Build (nutzt Docker-Layer-Cache)
#   ./build.sh --no-cache   # kompletter Neubau
#   ./build.sh --refresh    # Frappe/App-Layer neu holen, Rest aus dem Cache
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "FEHLER: .env fehlt. Anlegen mit:  cp .env.example .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

CUSTOM_IMAGE=${CUSTOM_IMAGE:-qmatrix/frappe}
CUSTOM_TAG=${CUSTOM_TAG:-16}
FRAPPE_PATH=${FRAPPE_PATH:-https://github.com/frappe/frappe}
FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-16}
APP_NAME=${APP_NAME:-qmatrix}
APP_BRANCH=${APP_BRANCH:-main}
APP_SOURCE=${APP_SOURCE:-local}
APP_REPO_TOKEN=${APP_REPO_TOKEN:-}

REFRESH=0
BUILD_ARGS=(
  --build-arg "FRAPPE_PATH=${FRAPPE_PATH}"
  --build-arg "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
)
[[ -n "${PYTHON_VERSION:-}" ]] && BUILD_ARGS+=(--build-arg "PYTHON_VERSION=${PYTHON_VERSION}")
[[ -n "${NODE_VERSION:-}" ]] && BUILD_ARGS+=(--build-arg "NODE_VERSION=${NODE_VERSION}")

for arg in "$@"; do
  case "$arg" in
    --no-cache) BUILD_ARGS+=(--no-cache) ;;
    # CACHE_BUST invalidiert genau den Layer, der Frappe und die Apps klont.
    --refresh)  REFRESH=1; BUILD_ARGS+=(--build-arg "CACHE_BUST=$(date +%s)") ;;
    *)          BUILD_ARGS+=("$arg") ;;
  esac
done

# -----------------------------------------------------------------------------
# App-Quelle bestimmen
#   local : Arbeitskopie unter apps-local/<app> wird ins Image kopiert.
#           Braucht keine Zugangsdaten im Container (das Klonen macht der Host).
#   git   : Der Container klont direkt aus APP_REPO_URL. Für öffentliche
#           Repos (GitHub) ohne alles, für private mit APP_REPO_TOKEN.
# -----------------------------------------------------------------------------
LOCAL_APPS_DIR="apps-local"
mkdir -p "$LOCAL_APPS_DIR"

case "$APP_SOURCE" in
  local)
    APP_CHECKOUT="${LOCAL_APPS_DIR}/${APP_NAME}"

    if [[ ! -d "${APP_CHECKOUT}/.git" ]]; then
      # Kein Checkout vorhanden -> vom Remote holen. Solange das Repo privat
      # ist, geht das per SSH bequemer als per HTTPS -- dafür APP_REPO_URL_HOST.
      HOST_CLONE_URL="${APP_REPO_URL_HOST:-${APP_REPO_URL:-}}"
      if [[ -z "$HOST_CLONE_URL" ]]; then
        echo "FEHLER: ${APP_CHECKOUT} ist kein Git-Repository und in der .env" >&2
        echo "       steht keine APP_REPO_URL zum Klonen." >&2
        echo "       Entweder APP_REPO_URL setzen oder im vorhandenen Ordner" >&2
        echo "       ein Repo anlegen:  git -C ${APP_CHECKOUT} init -b ${APP_BRANCH}" >&2
        exit 1
      fi
      if [[ -d "$APP_CHECKOUT" ]]; then
        echo "FEHLER: ${APP_CHECKOUT} existiert, ist aber kein Git-Repository." >&2
        echo "       bench klont aus diesem Verzeichnis -- ohne Repo geht das nicht." >&2
        echo "       Reparieren mit:" >&2
        echo "         git -C ${APP_CHECKOUT} init -b ${APP_BRANCH}" >&2
        echo "         git -C ${APP_CHECKOUT} add -A && git -C ${APP_CHECKOUT} commit -m 'Initial'" >&2
        exit 1
      fi
      echo "Hole Arbeitskopie nach ${APP_CHECKOUT} ..."
      git clone --branch "$APP_BRANCH" "$HOST_CLONE_URL" "$APP_CHECKOUT"
    elif [[ $REFRESH -eq 1 ]]; then
      # Nur aktualisieren, wenn es überhaupt ein Remote gibt. Ein rein lokales
      # Repo (App noch nicht veröffentlicht) bleibt einfach, wie es ist.
      if git -C "$APP_CHECKOUT" remote get-url origin >/dev/null 2>&1; then
        echo "Aktualisiere Arbeitskopie ${APP_CHECKOUT} ..."
        git -C "$APP_CHECKOUT" fetch origin "$APP_BRANCH"
        git -C "$APP_CHECKOUT" checkout "$APP_BRANCH"
        git -C "$APP_CHECKOUT" merge --ff-only "origin/${APP_BRANCH}"
      else
        echo "Hinweis: ${APP_CHECKOUT} hat kein Remote 'origin' -- nehme den lokalen Stand."
      fi
    fi

    # bench klont aus dem Verzeichnis -- ein git clone sieht nur Committetes.
    # Nicht committete Änderungen landen also NICHT im Image.
    if [[ -n "$(git -C "$APP_CHECKOUT" status --porcelain)" ]]; then
      echo
      echo "WARNUNG: ${APP_CHECKOUT} hat nicht committete Änderungen." >&2
      git -C "$APP_CHECKOUT" status --short >&2
      echo "Der Build klont aus dem Repo und übernimmt nur Committetes." >&2
      echo "Erst committen, dann bauen." >&2
      echo
    fi
    APP_URL="/opt/frappe/apps-local/${APP_NAME}"
    APP_INFO="lokal aus ${APP_CHECKOUT} @ $(git -C "$APP_CHECKOUT" rev-parse --short HEAD) (Branch ${APP_BRANCH})"
    ;;
  git)
    if [[ -z "${APP_REPO_URL:-}" ]]; then
      echo "FEHLER: APP_REPO_URL ist in .env nicht gesetzt (nötig für APP_SOURCE=git)." >&2
      exit 1
    fi
    APP_URL="$APP_REPO_URL"
    if [[ -n "$APP_REPO_TOKEN" ]]; then
      APP_URL="${APP_REPO_URL/https:\/\//https://${APP_REPO_TOKEN}@}"
    fi
    APP_INFO="${APP_REPO_URL} @ ${APP_BRANCH}"
    [[ -n "$APP_REPO_TOKEN" ]] && APP_INFO="${APP_INFO} (mit Token)"
    ;;
  *)
    echo "FEHLER: APP_SOURCE muss 'local' oder 'git' sein (ist: ${APP_SOURCE})." >&2
    exit 1
    ;;
esac

# apps.json wird aus der .env erzeugt und als BuildKit-Secret übergeben,
# damit ein evtl. Token nicht in "docker image history" auftaucht.
APPS_JSON=$(mktemp)
trap 'rm -f "$APPS_JSON"' EXIT
cat >"$APPS_JSON" <<EOF
[
  {
    "url": "${APP_URL}",
    "branch": "${APP_BRANCH}"
  }
]
EOF

echo "-------------------------------------------------------------"
echo " Image      : ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
echo " Frappe     : ${FRAPPE_PATH} @ ${FRAPPE_BRANCH}"
echo " Q-Matrix   : ${APP_INFO}"
echo "-------------------------------------------------------------"

DOCKER_BUILDKIT=1 docker build \
  "${BUILD_ARGS[@]}" \
  --secret "id=apps_json,src=${APPS_JSON}" \
  --tag "${CUSTOM_IMAGE}:${CUSTOM_TAG}" \
  --file Containerfile \
  .

echo
echo "Fertig: ${CUSTOM_IMAGE}:${CUSTOM_TAG}"
echo "Weiter mit:  ./qmatrix.sh up"
