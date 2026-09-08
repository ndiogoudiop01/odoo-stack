#!/usr/bin/env bash
###############################################################################
#  build.sh — construit et publie une image de base Odoo depuis TES dépôts.
#
#  Usage :
#      ./base-images/build.sh <version> [édition] [options]
#
#  Exemples :
#      ./base-images/build.sh 19.0                      # enterprise, build local
#      ./base-images/build.sh 18.0 community
#      ./base-images/build.sh 19.0 enterprise --push    # build + push registre
#      ./base-images/build.sh all --push                # toutes les versions
#
#  Options :
#      --push            pousse l'image sur le registre après le build
#      --no-cache        build complet sans cache
#      --python 3.11     force la version de Python
#      --platform ...    ex. linux/amd64,linux/arm64 (implique --push)
#
#  Configuration : base-images/base.env  (créé au premier lancement)
###############################################################################
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STACK_ROOT
source "${STACK_ROOT}/lib/common.sh"

BASE_DIR="${STACK_ROOT}/base-images"
CONF="${BASE_DIR}/base.env"

# ------------------------------------------------------- configuration initiale
if [ ! -f "${CONF}" ]; then
  warn "première utilisation : création de ${CONF}"
  cat > "${CONF}" <<'EOF'
# ---------------------------------------------------------------------------
#  Configuration des images de base Odoo. Fichier NON commité.
# ---------------------------------------------------------------------------

# Compte ou organisation GitHub qui héberge tes dépôts privés
GITHUB_OWNER=odooAfia

# Noms des dépôts (une branche par version : 17.0, 18.0, 19.0…)
ODOO_REPO=odoo
ENTERPRISE_REPO=enterprise

# Registre de destination des images de base
#   GitHub Container Registry : ghcr.io/<owner>
#   Docker Hub privé          : docker.io/<compte>
#   Registre auto-hébergé     : registry.mondomaine.sn
REGISTRY=ghcr.io/odooafia
IMAGE_NAME=odoo

# Token GitHub (fine-grained PAT) avec « Contents: Read » sur les deux dépôts.
# Sert au clone pendant le build ET au login sur ghcr.io.
GITHUB_TOKEN=

# Profondeur du clone : 1 = rapide et léger. Mettre 0 pour l'historique complet.
GIT_DEPTH=1
EOF
  chmod 600 "${CONF}"
  err "Complétez ${CONF} (GITHUB_OWNER, REGISTRY, GITHUB_TOKEN) puis relancez."
  exit 1
fi

# shellcheck source=/dev/null
set -a; source "${CONF}"; set +a

: "${GITHUB_OWNER:?GITHUB_OWNER manquant dans base.env}"
: "${REGISTRY:?REGISTRY manquant dans base.env}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN manquant dans base.env}"
ODOO_REPO="${ODOO_REPO:-odoo}"
ENTERPRISE_REPO="${ENTERPRISE_REPO:-enterprise}"
IMAGE_NAME="${IMAGE_NAME:-odoo}"
GIT_DEPTH="${GIT_DEPTH:-1}"

# ------------------------------------------------------------------ arguments
VERSION="${1:-}"; shift || true
EDITION="enterprise"
case "${1:-}" in enterprise|community) EDITION="$1"; shift ;; esac

PUSH=0; NO_CACHE=""; PLATFORM=""; PYTHON_VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --push)     PUSH=1; shift ;;
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    --python)   PYTHON_VERSION="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; PUSH=1; shift 2 ;;
    *) die "option inconnue : $1" ;;
  esac
done

[ -n "${VERSION}" ] || die "usage : ./base-images/build.sh <version|all> [enterprise|community] [--push]"

require_cmd docker
docker buildx version >/dev/null 2>&1 || die "docker buildx requis (Docker >= 23)"

# Version de Python testée pour chaque version d'Odoo
python_for_odoo() {
  case "$1" in
    16.0) echo 3.10 ;;
    17.0) echo 3.11 ;;
    18.0) echo 3.12 ;;
    19.0) echo 3.12 ;;
    *)    echo 3.12 ;;
  esac
}

# ------------------------------------------------------------------- build
build_one() {
  local version="$1" edition="$2"
  local py="${PYTHON_VERSION:-$(python_for_odoo "${version}")}"
  local tag="${REGISTRY}/${IMAGE_NAME}:${version}-${edition}"
  local tag_date="${REGISTRY}/${IMAGE_NAME}:${version}-${edition}-$(date '+%Y%m%d')"

  title "Odoo ${version} — ${edition} — Python ${py}"
  info "image : ${tag}"

  local args=(
    buildx build
    --file "${BASE_DIR}/Dockerfile"
    --build-arg "GITHUB_OWNER=${GITHUB_OWNER}"
    --build-arg "ODOO_REPO=${ODOO_REPO}"
    --build-arg "ENTERPRISE_REPO=${ENTERPRISE_REPO}"
    --build-arg "ODOO_VERSION=${version}"
    --build-arg "EDITION=${edition}"
    --build-arg "PYTHON_VERSION=${py}"
    --build-arg "GIT_DEPTH=${GIT_DEPTH}"
    --secret "id=gh_token,env=GITHUB_TOKEN"
    --tag "${tag}"
    --tag "${tag_date}"
  )
  [ -n "${NO_CACHE}" ] && args+=("${NO_CACHE}")
  [ -n "${PLATFORM}" ] && args+=(--platform "${PLATFORM}")
  if [ "${PUSH}" -eq 1 ]; then args+=(--push); else args+=(--load); fi
  args+=("${BASE_DIR}")

  DOCKER_BUILDKIT=1 GITHUB_TOKEN="${GITHUB_TOKEN}" docker "${args[@]}"

  ok "construit : ${tag}"
  if [ "${PUSH}" -eq 1 ]; then
    ok "poussé sur ${REGISTRY}"
  else
    info "révision embarquée :"
    docker run --rm --entrypoint cat "${tag}" /opt/SOURCES.txt | sed 's/^/    /'
  fi
}

# --------------------------------------------------------------- login registre
if [ "${PUSH}" -eq 1 ]; then
  case "${REGISTRY}" in
    ghcr.io/*)
      info "connexion à ghcr.io…"
      printf '%s' "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_OWNER}" --password-stdin
      ;;
    *) warn "vérifiez que vous êtes connecté à ${REGISTRY} (docker login)" ;;
  esac
fi

# -------------------------------------------------------------------- exécution
if [ "${VERSION}" = "all" ]; then
  for v in 17.0 18.0 19.0; do
    build_one "${v}" "${EDITION}"
  done
else
  build_one "${VERSION}" "${EDITION}"
fi

printf "\n"
ok "terminé"
cat <<EOF

À utiliser dans un client (fichier .env) :

    ODOO_BASE_IMAGE=${REGISTRY}/${IMAGE_NAME}:${VERSION}-${EDITION}

Si le VPS doit tirer l'image depuis un registre privé, connectez-le une fois :

    docker login ghcr.io -u ${GITHUB_OWNER}
EOF
