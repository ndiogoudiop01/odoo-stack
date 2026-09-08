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
#      --push                    pousse l'image sur le registre après le build
#      --no-cache                build complet sans cache
#      --python 3.11             force la version de Python
#      --platform ...            ex. linux/amd64,linux/arm64 (implique --push)
#      --odoo-subdir <chemin>    si la racine d'Odoo est dans un sous-dossier
#      --enterprise-subdir <ch.> idem pour les modules Enterprise
#      --odoo-branch <branche>   si la branche ne porte pas le nom de la version
#      --enterprise-branch <br.> idem pour le dépôt Enterprise
#      --probe                   ne construit rien : affiche l'arborescence des
#                                dépôts pour diagnostiquer une détection ratée
#      --anonymous               ignore le token (dépôts publics)
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
# ===========================================================================
#  Configuration des images de base Odoo.  Fichier NON commité (token dedans).
#
#  Comment remplir chaque variable : prenez l'URL GitHub de votre dépôt.
#
#      https://github.com/ndiogoudiop01/odoo/tree/18.0/18.0
#                         └────┬─────┘ └─┬─┘      └─┬┘ └┬┘
#                        GITHUB_OWNER  ODOO_REPO  branche  dossier
#
#  · GITHUB_OWNER = le compte ou l'organisation  -> ndiogoudiop01
#  · ODOO_REPO    = le NOM du dépôt uniquement   -> odoo
#                   (pas l'URL, pas de .git, pas de owner/)
#  · la branche vient du numéro de version passé à build.sh (18.0 -> branche 18.0).
#    Si elle diffère :   ./base-images/build.sh 18.0 community --odoo-branch main
#  · le dossier (18.0 ici) est DÉTECTÉ AUTOMATIQUEMENT : rien à saisir.
# ===========================================================================

# Compte ou organisation GitHub qui héberge vos dépôts
GITHUB_OWNER=ndiogoudiop01

# Dépôt contenant les sources du CORE (Community)
#   exemple : https://github.com/ndiogoudiop01/odoo  ->  ODOO_REPO=odoo
ODOO_REPO=odoo

# Dépôt contenant les modules ENTERPRISE (ignoré en édition community)
#   attention à l'orthographe : « entreprise » (fr) et « enterprise » (en)
#   sont deux dépôts différents pour GitHub.
ENTERPRISE_REPO=entreprise

# Registre où publier les images de base
#   GitHub Container Registry : ghcr.io/<owner en minuscules>
#   Docker Hub                : docker.io/<compte>
#   Registre auto-hébergé     : registry.mondomaine.sn
REGISTRY=ghcr.io/ndiogoudiop01
IMAGE_NAME=odoo

# Token GitHub.
#   · Dépôts PUBLICS  -> LAISSEZ VIDE. Un token sans droits sur le dépôt
#     provoque un 403 « Write access to repository not granted ».
#   · Dépôts PRIVÉS   -> PAT fine-grained avec, pour CHAQUE dépôt listé
#     ci-dessus : Repository access + permission « Contents: Read-only ».
#   Pour publier sur ghcr.io, le token doit aussi avoir « write:packages ».
GITHUB_TOKEN=

# Profondeur du clone : 1 = rapide et léger. 0 = historique complet.
GIT_DEPTH=1
EOF
  chmod 600 "${CONF}"
  err "Complétez ${CONF} (GITHUB_OWNER, ODOO_REPO, REGISTRY) puis relancez."
  info "Puis vérifiez avant de construire :  ./base-images/build.sh <version> <édition> --probe"
  exit 1
fi

# shellcheck source=/dev/null
set -a; source "${CONF}"; set +a

: "${GITHUB_OWNER:?GITHUB_OWNER manquant dans base.env}"
: "${REGISTRY:?REGISTRY manquant dans base.env}"
: "${GITHUB_TOKEN:=}"
[ -n "${GITHUB_TOKEN}" ] || warn "GITHUB_TOKEN vide : clone anonyme (ne marche que sur des dépôts publics)"
ODOO_REPO="${ODOO_REPO:-odoo}"
ENTERPRISE_REPO="${ENTERPRISE_REPO:-enterprise}"
IMAGE_NAME="${IMAGE_NAME:-odoo}"
GIT_DEPTH="${GIT_DEPTH:-1}"

# ------------------------------------------------------------------ arguments
VERSION="${1:-}"; shift || true
EDITION="enterprise"
case "${1:-}" in enterprise|community) EDITION="$1"; shift ;; esac

PUSH=0; NO_CACHE=""; PLATFORM=""; PYTHON_VERSION=""
ODOO_SUBDIR=""; ENTERPRISE_SUBDIR=""; PROBE=0
ODOO_BRANCH_OPT=""; ENTERPRISE_BRANCH_OPT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --push)     PUSH=1; shift ;;
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    --python)   PYTHON_VERSION="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; PUSH=1; shift 2 ;;
    --odoo-subdir)       ODOO_SUBDIR="$2"; shift 2 ;;
    --enterprise-subdir) ENTERPRISE_SUBDIR="$2"; shift 2 ;;
    --odoo-branch)       ODOO_BRANCH_OPT="$2"; shift 2 ;;
    --enterprise-branch) ENTERPRISE_BRANCH_OPT="$2"; shift 2 ;;
    --probe)    PROBE=1; shift ;;
    --anonymous) GITHUB_TOKEN=""; shift ;;
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
    --build-arg "ODOO_SUBDIR=${ODOO_SUBDIR}"
    --build-arg "ODOO_BRANCH=${ODOO_BRANCH_OPT:-${version}}"
    --build-arg "ENTERPRISE_BRANCH=${ENTERPRISE_BRANCH_OPT:-${version}}"
    --build-arg "ENTERPRISE_SUBDIR=${ENTERPRISE_SUBDIR}"
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

# ------------------------------------------------------------------- probe
repo_url() {
  if [ "${2:-token}" = "token" ] && [ -n "${GITHUB_TOKEN}" ]; then
    printf 'https://x-access-token:%s@github.com/%s/%s.git' "${GITHUB_TOKEN}" "${GITHUB_OWNER}" "$1"
  else
    printf 'https://github.com/%s/%s.git' "${GITHUB_OWNER}" "$1"
  fi
}
mask() { sed "s|${GITHUB_TOKEN:-@@nope@@}|***|g"; }

probe_repo() {
  local repo="$1" branch="$2" kind="$3"
  printf "\n${C_BOLD}%s${C_OFF} — dépôt ${C_BLU}%s/%s${C_OFF}, branche ${C_BLU}%s${C_OFF}\n" \
         "${kind}" "${GITHUB_OWNER}" "${repo}" "${branch}"

  # 1. le dépôt est-il joignable ? (avec token, puis en anonyme)
  local mode="" auth_err=""
  if [ -n "${GITHUB_TOKEN}" ] \
     && git ls-remote --heads "$(repo_url "${repo}" token)" >/tmp/heads.txt 2>/tmp/lsr.err; then
    mode="token"; ok "dépôt joignable (avec le token)"
  else
    [ -n "${GITHUB_TOKEN}" ] && auth_err="$(cat /tmp/lsr.err)"
    if git ls-remote --heads "$(repo_url "${repo}" anon)" >/tmp/heads.txt 2>/tmp/lsr.err; then
      mode="anon"
      if [ -n "${GITHUB_TOKEN}" ]; then
        warn "dépôt joignable SANS token, mais REFUSÉ avec le token :"
        printf "%s\n" "${auth_err}" | mask | sed 's/^/      /'
        warn "-> ce dépôt est public : videz GITHUB_TOKEN dans base.env,"
        warn "   ou donnez au PAT l'accès « Contents: Read-only » sur ${GITHUB_OWNER}/${repo}."
        warn "   Le build sait retomber tout seul en anonyme, mais autant être explicite."
      else
        ok "dépôt joignable (public, sans token)"
      fi
    else
      err "dépôt injoignable"
      printf "  sortie de git :\n"; mask < /tmp/lsr.err | sed 's/^/    /'
      cat <<EOF
  Pistes :
    · nom du dépôt exact ? (attention : « entreprise » ≠ « enterprise »)
    · « Write access ... not granted » / 403 -> le token n'a AUCUN droit sur CE
      dépôt : videz GITHUB_TOKEN s'il est public, sinon ajoutez le dépôt dans
      « Repository access » du PAT fine-grained (permission Contents: Read-only)
    · token expiré ou révoqué ?
EOF
      return 1
    fi
  fi

  # 2. la branche existe-t-elle ?
  printf "  branches disponibles :\n"
  sed 's|.*refs/heads/|    - |' /tmp/heads.txt | sort | head -20
  if ! grep -q "refs/heads/${branch}\$" /tmp/heads.txt; then
    err "la branche « ${branch} » n'existe PAS dans ce dépôt"
    printf "  -> relancez avec : --%s-branch <une des branches ci-dessus>\n" \
           "$([ "${kind}" = "Core Odoo" ] && echo odoo || echo enterprise)"
    return 1
  fi
  ok "branche « ${branch} » présente"

  # 3. structure
  # dossier unique par (dépôt, branche) : deux sondes du même dépôt ne peuvent
  # plus se marcher dessus
  local dir
  dir="${WORK}/$(printf '%s@%s' "${repo}" "${branch}" | tr -c 'A-Za-z0-9._-' '_')"
  rm -rf "${dir}"
  if ! git clone --depth 1 --branch "${branch}" --single-branch \
        "$(repo_url "${repo}" "${mode}")" "${dir}" >/dev/null 2>/tmp/clone.err; then
    err "clone échoué"
    printf "  sortie de git :\n"; mask < /tmp/clone.err | sed 's/^/    /'
    printf "  espace disque disponible : %s\n" "$(df -h "${WORK}" | awk 'NR==2 {print $4}')"
    cat <<EOF
  Pistes :
    · « already exists » -> ODOO_REPO et ENTERPRISE_REPO pointent le même dépôt
      dans base-images/base.env (voir la configuration affichée plus haut)
    · dépôt volumineux + disque plein -> libérez de la place (docker system prune -af)
    · dépôt utilisant Git LFS -> installez git-lfs, ou déposez les sources sans LFS
    · coupure réseau pendant le transfert -> réessayez
EOF
    return 1
  fi

  printf "  racine du dépôt :\n"
  find "${dir}" -maxdepth 1 -not -path '*/.git*' -not -path "${dir}" \
    | sed "s|${dir}/|    |" | sort | head -20

  printf "  fichiers clés :\n"
  local found
  for f in odoo-bin requirements.txt setup.py release.py; do
    found="$(find "${dir}" -maxdepth 4 -name "${f}" -not -path '*/.git/*' | head -1)"
    if [ -n "${found}" ]; then
      printf "    %-18s ${C_GRN}%s${C_OFF}\n" "${f}" "${found#"${dir}"/}"
    else
      printf "    %-18s ${C_RED}absent${C_OFF}\n" "${f}"
    fi
  done
  found="$(find "${dir}" -maxdepth 4 -name '__manifest__.py' -not -path '*/.git/*' | head -1)"
  [ -n "${found}" ] && printf "    %-18s ${C_GRN}%s${C_OFF}\n" "premier module" "$(dirname "${found#"${dir}"/}")"

  # 4. sous-dossier à utiliser
  local bin sub rel
  bin="$(find "${dir}" -maxdepth 4 -name 'odoo-bin' -not -path '*/.git/*' | head -1)"
  if [ -z "${bin}" ] && [ "${kind}" = "Core Odoo" ]; then
    # archive « Sources » d'odoo.com : pas d'odoo-bin, mais le paquet python
    rel="$(find "${dir}" -maxdepth 5 -type f -path '*/odoo/release.py' -not -path '*/.git/*' | head -1)"
    if [ -n "${rel}" ]; then
      sub="$(dirname "$(dirname "$(dirname "${rel#"${dir}"/}")")")"
      ok "archive « Sources » détectée (pas d'odoo-bin, c'est normal)"
      info "racine Odoo : « ${sub:-.} » — un lanceur odoo-bin sera généré au build"
      return 0
    fi
    err "ni odoo-bin ni odoo/release.py : ce dépôt ne contient pas les sources d'Odoo"
    return 1
  fi
  if [ -n "${bin}" ]; then
    sub="$(dirname "${bin#"${dir}"/}")"
    [ "${sub}" = "." ] && info "racine Odoo : à la racine du dépôt (détection automatique OK)" \
                       || info "racine Odoo : sous-dossier « ${sub} » (détection automatique OK)"
  elif [ "${kind}" != "Core Odoo" ]; then
    found="$(find "${dir}" -maxdepth 4 -name '__manifest__.py' -not -path '*/.git/*' | head -1)"
    if [ -n "${found}" ]; then
      sub="$(dirname "$(dirname "${found#"${dir}"/}")")"
      info "racine Enterprise : « ${sub:-.} » (détection automatique OK)"
    fi
  fi
  return 0
}

if [ "${PROBE}" -eq 1 ]; then
  title "Sondage des dépôts — Odoo ${VERSION} (${EDITION})"

  # Configuration effectivement utilisée : c'est la première chose à vérifier
  # quand quelque chose ne colle pas.
  cat <<EOF
Configuration lue dans base-images/base.env :
  GITHUB_OWNER      ${GITHUB_OWNER}
  ODOO_REPO         ${ODOO_REPO}          @ ${ODOO_BRANCH_OPT:-${VERSION}}
  ENTERPRISE_REPO   ${ENTERPRISE_REPO}    @ ${ENTERPRISE_BRANCH_OPT:-${VERSION}}
  REGISTRY          ${REGISTRY}/${IMAGE_NAME}
  GITHUB_TOKEN      $([ -n "${GITHUB_TOKEN}" ] && echo "renseigné (${#GITHUB_TOKEN} caractères)" || echo "absent — clone anonyme")
EOF
  if [ "${ODOO_REPO}" = "${ENTERPRISE_REPO}" ]; then
    warn "ODOO_REPO et ENTERPRISE_REPO désignent le MÊME dépôt (${ODOO_REPO})."
    warn "C'est valide si ce dépôt contient à la fois le core et les modules"
    warn "Enterprise dans des sous-dossiers distincts ; sinon corrigez base.env."
  fi

  WORK="$(mktemp -d)"
  trap 'rm -rf "${WORK}"' EXIT
  RC=0
  probe_repo "${ODOO_REPO}" "${ODOO_BRANCH_OPT:-${VERSION}}" "Core Odoo" || RC=1
  if [ "${EDITION}" = "enterprise" ]; then
    probe_repo "${ENTERPRISE_REPO}" "${ENTERPRISE_BRANCH_OPT:-${VERSION}}" "Enterprise" || RC=1
  fi
  printf "\n"
  if [ "${RC}" -eq 0 ]; then
    ok "les deux dépôts sont exploitables — vous pouvez lancer le build :"
    printf "    ./base-images/build.sh %s %s --push\n\n" "${VERSION}" "${EDITION}"
  else
    err "corrigez les points ci-dessus (base-images/base.env, ou options --*-branch / --*-subdir)"
  fi
  exit "${RC}"
fi

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
