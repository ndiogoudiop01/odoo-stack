#!/bin/sh
###############################################################################
#  fetch-sources.sh — clone les dépôts Odoo privés et NORMALISE l'arborescence.
#
#  Exécuté dans l'étage « sources » du build (image alpine/git).
#
#  Problème résolu : selon les dépôts, la racine d'Odoo n'est pas toujours à la
#  racine du dépôt (elle peut être dans odoo/, src/, odoo-19.0/ …). Ce script
#  détecte la vraie racine et produit TOUJOURS la même arborescence :
#
#      /src/odoo/               racine Odoo (contient odoo-bin)
#      /src/enterprise/         modules Enterprise (dossiers à __manifest__.py)
#      /src/requirements.txt    copie garantie, quel que soit son emplacement
#      /src/SOURCES.txt         dépôts, branches, commits, sous-dossiers détectés
#
#  Variables attendues : GITHUB_OWNER ODOO_REPO ENTERPRISE_REPO ODOO_VERSION
#                        EDITION GIT_DEPTH [ODOO_SUBDIR] [ENTERPRISE_SUBDIR]
#  Le token est lu dans /run/secrets/gh_token.
###############################################################################
set -eu

log()  { printf '[sources] %s\n' "$*" >&2; }
fail() { printf '[sources] ERREUR : %s\n' "$*" >&2; exit 1; }

TOKEN="$(cat /run/secrets/gh_token 2>/dev/null || true)"

: "${GITHUB_OWNER:?GITHUB_OWNER manquant}"
: "${ODOO_REPO:=odoo}"
: "${ENTERPRISE_REPO:=enterprise}"
: "${ODOO_VERSION:=19.0}"
: "${EDITION:=enterprise}"
: "${GIT_DEPTH:=1}"
: "${ODOO_SUBDIR:=}"          # forcer le sous-dossier si la détection échoue
: "${ENTERPRISE_SUBDIR:=}"
# La branche peut différer du numéro de version (dépôt sans branche 19.0, etc.)
: "${ODOO_BRANCH:=${ODOO_VERSION}}"
: "${ENTERPRISE_BRANCH:=${ODOO_VERSION}}"

[ -n "${TOKEN}" ] || log "aucun token fourni : clone anonyme (dépôts publics uniquement)"

# URL de clone, avec ou sans token
repo_url() {
  if [ -n "${TOKEN}" ]; then
    printf 'https://x-access-token:%s@github.com/%s/%s.git' "${TOKEN}" "${GITHUB_OWNER}" "$1"
  else
    printf 'https://github.com/%s/%s.git' "${GITHUB_OWNER}" "$1"
  fi
}

if [ "${GIT_DEPTH}" = "0" ]; then DEPTH=""; else DEPTH="--depth ${GIT_DEPTH}"; fi

# --------------------------------------------------------------------- clone
clone_repo() {
  repo="$1"; dest="$2"; branch="$3"
  log "clone ${GITHUB_OWNER}/${repo} (branche ${branch})"
  # shellcheck disable=SC2086
  if git clone ${DEPTH} --branch "${branch}" --single-branch "$(repo_url "${repo}")" "${dest}" 2>/tmp/git.err; then
    return 0
  fi
  log "----- sortie de git -----"
  sed "s|${TOKEN:-@@nope@@}|***|g" /tmp/git.err >&2 || true
  log "-------------------------"
  log "branches disponibles sur ${GITHUB_OWNER}/${repo} :"
  if git ls-remote --heads "$(repo_url "${repo}")" 2>/dev/null | sed 's|.*refs/heads/|  - |' >&2; then :; else
    log "  (impossible de lister : dépôt inexistant, privé sans droits, ou token invalide)"
  fi
  fail "clone impossible : ${GITHUB_OWNER}/${repo}, branche ${branch}.
         Causes possibles : nom de dépôt erroné (attention à enterprise / entreprise),
         branche absente (voir la liste ci-dessus), ou token sans accès à ce dépôt."
}

# Affiche l'arborescence utile pour diagnostiquer une détection ratée
show_tree() {
  log "contenu de $1 (3 niveaux) :"
  find "$1" -maxdepth 2 -not -path '*/.git/*' -not -name '.git' \
    | sed "s|^$1|  .|" | sort | head -60 >&2
}

# ------------------------------------------------------ détection de la racine
# Racine Odoo = dossier contenant odoo-bin (ou, à défaut, odoo/release.py)
detect_odoo_root() {
  base="$1"
  if [ -n "${ODOO_SUBDIR}" ]; then
    [ -d "${base}/${ODOO_SUBDIR}" ] || fail "ODOO_SUBDIR=${ODOO_SUBDIR} introuvable dans le dépôt"
    printf '%s' "${base}/${ODOO_SUBDIR}"; return 0
  fi
  hit="$(find "${base}" -maxdepth 4 -type f -name 'odoo-bin' 2>/dev/null | head -1)"
  [ -n "${hit}" ] || hit="$(find "${base}" -maxdepth 5 -type f -path '*/odoo/release.py' 2>/dev/null | head -1 | sed 's|/odoo/release.py$|/x|')"
  [ -n "${hit}" ] || return 1
  dirname "${hit}"
}

# Racine Enterprise = dossier contenant directement des modules (*/__manifest__.py)
detect_enterprise_root() {
  base="$1"
  if [ -n "${ENTERPRISE_SUBDIR}" ]; then
    [ -d "${base}/${ENTERPRISE_SUBDIR}" ] || fail "ENTERPRISE_SUBDIR=${ENTERPRISE_SUBDIR} introuvable"
    printf '%s' "${base}/${ENTERPRISE_SUBDIR}"; return 0
  fi
  hit="$(find "${base}" -maxdepth 3 -type f -name '__manifest__.py' 2>/dev/null | head -1)"
  [ -n "${hit}" ] || return 1
  dirname "$(dirname "${hit}")"
}

# ------------------------------------------------------------------ exécution
mkdir -p /src
clone_repo "${ODOO_REPO}" /tmp/raw-odoo "${ODOO_BRANCH}"

ODOO_ROOT="$(detect_odoo_root /tmp/raw-odoo || true)"
if [ -z "${ODOO_ROOT}" ]; then
  show_tree /tmp/raw-odoo
  fail "racine Odoo introuvable (aucun odoo-bin dans ${GITHUB_OWNER}/${ODOO_REPO}@${ODOO_BRANCH}).
         Si le code est dans un sous-dossier, relancez avec :
             ./base-images/build.sh ${ODOO_VERSION} ${EDITION} --odoo-subdir <chemin>"
fi
ODOO_REL="${ODOO_ROOT#/tmp/raw-odoo}"; ODOO_REL="${ODOO_REL#/}"
log "racine Odoo détectée : ${ODOO_REL:-<racine du dépôt>}"

# --- Enterprise ---------------------------------------------------------------
ENT_REL="-"
if [ "${EDITION}" = "enterprise" ]; then
  clone_repo "${ENTERPRISE_REPO}" /tmp/raw-enterprise "${ENTERPRISE_BRANCH}"
  ENT_ROOT="$(detect_enterprise_root /tmp/raw-enterprise || true)"
  if [ -z "${ENT_ROOT}" ]; then
    show_tree /tmp/raw-enterprise
    fail "aucun module Enterprise trouvé dans ${GITHUB_OWNER}/${ENTERPRISE_REPO}.
         Si les modules sont dans un sous-dossier, relancez avec :
             ./base-images/build.sh ${ODOO_VERSION} enterprise --enterprise-subdir <chemin>"
  fi
  ENT_REL="${ENT_ROOT#/tmp/raw-enterprise}"; ENT_REL="${ENT_REL#/}"
  log "racine Enterprise détectée : ${ENT_REL:-<racine du dépôt>}"
fi

# --- commits AVANT de retirer les .git ----------------------------------------
ODOO_COMMIT="$(git -C /tmp/raw-odoo rev-parse HEAD)"
ENT_COMMIT="-"
[ -d /tmp/raw-enterprise/.git ] && ENT_COMMIT="$(git -C /tmp/raw-enterprise rev-parse HEAD)"

# --- normalisation de l'arborescence ------------------------------------------
mv "${ODOO_ROOT}" /src/odoo
if [ "${EDITION}" = "enterprise" ]; then
  mv "${ENT_ROOT}" /src/enterprise
else
  mkdir -p /src/enterprise
fi

# --- requirements.txt garanti --------------------------------------------------
if [ -f /src/odoo/requirements.txt ]; then
  cp /src/odoo/requirements.txt /src/requirements.txt
else
  alt="$(find /tmp/raw-odoo /src/odoo -maxdepth 3 -type f -name 'requirements.txt' 2>/dev/null | head -1)"
  if [ -n "${alt}" ]; then
    log "requirements.txt trouvé hors racine : ${alt}"
    cp "${alt}" /src/requirements.txt
  else
    show_tree /src/odoo
    fail "requirements.txt introuvable dans ${GITHUB_OWNER}/${ODOO_REPO}.
         Le dépôt est-il un fork complet d'odoo/odoo ?
         À défaut, ajoutez un requirements.txt à la racine de votre fork."
  fi
fi

# --- contrôles de cohérence ----------------------------------------------------
[ -f /src/odoo/odoo-bin ]     || fail "odoo-bin absent après normalisation"
[ -d /src/odoo/odoo ]         || fail "paquet python odoo/ absent après normalisation"
[ -d /src/odoo/addons ]       || log "ATTENTION : /src/odoo/addons absent (fork partiel ?)"

# --- traçabilité ---------------------------------------------------------------
{
  echo "odoo_repo=${GITHUB_OWNER}/${ODOO_REPO}"
  echo "odoo_subdir=${ODOO_REL:-.}"
  echo "odoo_commit=${ODOO_COMMIT}"
  echo "odoo_branch=${ODOO_BRANCH}"
  echo "edition=${EDITION}"
  if [ "${EDITION}" = "enterprise" ]; then
    echo "enterprise_repo=${GITHUB_OWNER}/${ENTERPRISE_REPO}"
    echo "enterprise_branch=${ENTERPRISE_BRANCH}"
    echo "enterprise_subdir=${ENT_REL:-.}"
    echo "enterprise_commit=${ENT_COMMIT}"
  fi
  echo "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > /src/SOURCES.txt

# --- le token vit dans les remotes : on supprime tout .git ---------------------
rm -rf /src/odoo/.git /src/enterprise/.git /tmp/raw-odoo /tmp/raw-enterprise
find /src -name '.git' -maxdepth 3 -exec rm -rf {} + 2>/dev/null || true

log "sources prêtes"
cat /src/SOURCES.txt >&2
