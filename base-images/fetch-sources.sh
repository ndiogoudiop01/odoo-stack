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

# URL de clone. mode = "token" ou "anon".
repo_url() {
  if [ "${2:-token}" = "token" ] && [ -n "${TOKEN}" ]; then
    printf 'https://x-access-token:%s@github.com/%s/%s.git' "${TOKEN}" "${GITHUB_OWNER}" "$1"
  else
    printf 'https://github.com/%s/%s.git' "${GITHUB_OWNER}" "$1"
  fi
}

LAST_ERR=""

if [ "${GIT_DEPTH}" = "0" ]; then DEPTH=""; else DEPTH="--depth ${GIT_DEPTH}"; fi

# --------------------------------------------------------------------- clone
mask() { sed "s|${TOKEN:-@@nope@@}|***|g"; }

# Tente le clone avec le token puis, si le token est refusé, SANS token.
# Un dépôt PUBLIC est en effet rejeté (403) quand on présente un token qui n'a
# pas de droits dessus : l'anonyme réussit là où l'authentifié échoue.
clone_repo() {
  repo="$1"; dest="$2"; branch="$3"
  rm -rf "${dest}"          # jamais de clone dans un dossier déjà peuplé

  for mode in token anon; do
    [ "${mode}" = "token" ] && [ -z "${TOKEN}" ] && continue
    [ "${mode}" = "anon" ]  && [ -n "${TOKEN}" ] && log "nouvelle tentative SANS token (dépôt public ?)"
    log "clone ${GITHUB_OWNER}/${repo} (branche ${branch}, ${mode})"
    rm -rf "${dest}"
    # shellcheck disable=SC2086
    if git clone ${DEPTH} --branch "${branch}" --single-branch \
         "$(repo_url "${repo}" "${mode}")" "${dest}" 2>/tmp/git.err; then
      [ "${mode}" = "anon" ] && [ -n "${TOKEN}" ] \
        && log "OK en anonyme : ce dépôt est public, le token n'est pas requis"
      return 0
    fi
    log "----- sortie de git (${mode}) -----"
    mask < /tmp/git.err >&2 || true
    log "-----------------------------------"
    LAST_ERR="$(cat /tmp/git.err)"
  done

  log "branches disponibles sur ${GITHUB_OWNER}/${repo} :"
  { git ls-remote --heads "$(repo_url "${repo}" token)" 2>/dev/null \
    || git ls-remote --heads "$(repo_url "${repo}" anon)"  2>/dev/null; } \
    | sed 's|.*refs/heads/|  - |' >&2 \
    || log "  (dépôt inexistant, privé sans droits, ou token invalide)"

  case "${LAST_ERR}" in
    *"Write access to repository not granted"*|*"403"*)
      fail "GitHub renvoie 403 pour ${GITHUB_OWNER}/${repo}.
         Le token est valide mais n'a AUCUN droit sur ce dépôt précis.
           · dépôt PUBLIC  -> videz GITHUB_TOKEN dans base-images/base.env
           · dépôt PRIVÉ   -> le PAT fine-grained doit lister ce dépôt dans
             « Repository access » avec la permission « Contents: Read-only »" ;;
    *)
      fail "clone impossible : ${GITHUB_OWNER}/${repo}, branche ${branch}.
         Vérifiez le nom du dépôt, la branche (liste ci-dessus) et les droits du token." ;;
  esac
}

# Affiche l'arborescence utile pour diagnostiquer une détection ratée
show_tree() {
  log "contenu de $1 (3 niveaux) :"
  find "$1" -maxdepth 2 -not -path '*/.git/*' -not -name '.git' \
    | sed "s|^$1|  .|" | sort | head -60 >&2
}

# ------------------------------------------------------ détection de la racine
#  Deux structures possibles pour le core :
#    · clone git de odoo/odoo        -> odoo-bin à la racine
#    · archive « Sources » odoo.com  -> PAS d'odoo-bin, mais setup.py + odoo/
#      (le lanceur y est setup/odoo ; on en régénère un plus bas)
#  Le repère fiable et commun aux deux est le paquet python : odoo/release.py
detect_odoo_root() {
  base="$1"
  if [ -n "${ODOO_SUBDIR}" ]; then
    [ -d "${base}/${ODOO_SUBDIR}" ] || fail "ODOO_SUBDIR=${ODOO_SUBDIR} introuvable dans le dépôt"
    printf '%s' "${base}/${ODOO_SUBDIR}"; return 0
  fi
  # 1) clone git : odoo-bin
  hit="$(find "${base}" -maxdepth 4 -type f -name 'odoo-bin' 2>/dev/null | head -1)"
  if [ -n "${hit}" ]; then dirname "${hit}"; return 0; fi
  # 2) archive sources : le paquet python odoo/release.py
  hit="$(find "${base}" -maxdepth 5 -type f -path '*/odoo/release.py' 2>/dev/null | head -1)"
  if [ -n "${hit}" ]; then dirname "$(dirname "${hit}")"; return 0; fi
  # 3) dernier recours : setup.py à côté d'un dossier odoo/
  hit="$(find "${base}" -maxdepth 3 -type f -name 'setup.py' 2>/dev/null | while read -r f; do
           [ -d "$(dirname "${f}")/odoo" ] && { echo "${f}"; break; }
         done)"
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
  if [ "${ENTERPRISE_REPO}" = "${ODOO_REPO}" ] && [ "${ENTERPRISE_BRANCH}" = "${ODOO_BRANCH}" ]; then
    # Même dépôt : impossible de deviner quel sous-dossier porte Enterprise,
    # la détection tomberait sur les addons du core. On l'exige explicitement.
    [ -n "${ENTERPRISE_SUBDIR}" ] || fail "ODOO_REPO et ENTERPRISE_REPO désignent le même dépôt
         (${ODOO_REPO}@${ODOO_BRANCH}). Deux cas :
           · c'est une erreur de configuration -> corrigez base-images/base.env
           · le dépôt contient bien les deux -> indiquez où sont les modules
             Enterprise :  --enterprise-subdir <chemin>"
    # Un seul dépôt contient le core ET Enterprise : on réutilise le clone
    # au lieu de le refaire (et surtout au lieu d'échouer sur un dossier occupé).
    log "core et Enterprise dans le même dépôt/branche : réutilisation du clone"
    cp -a /tmp/raw-odoo /tmp/raw-enterprise
  else
    clone_repo "${ENTERPRISE_REPO}" /tmp/raw-enterprise "${ENTERPRISE_BRANCH}"
  fi
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
[ -d /src/odoo/odoo ]            || fail "paquet python odoo/ absent après normalisation"
[ -f /src/odoo/odoo/release.py ] || fail "odoo/release.py absent : ce n'est pas une source Odoo valide"

# Lanceur : le clone git fournit odoo-bin, l'archive « Sources » d'odoo.com non
# (elle expose setup/odoo). On en régénère un pour avoir un point d'entrée
# identique dans tous les cas — c'est ce que l'entrypoint et debugpy utilisent.
if [ ! -f /src/odoo/odoo-bin ]; then
  if [ -f /src/odoo/setup/odoo ]; then
    log "odoo-bin absent (archive Sources) : lanceur repris depuis setup/odoo"
    cp /src/odoo/setup/odoo /src/odoo/odoo-bin
  else
    log "odoo-bin absent : génération d'un lanceur équivalent"
    cat > /src/odoo/odoo-bin <<'LAUNCHER'
#!/usr/bin/env python3
# Lanceur généré par odoo-stack : les archives « Sources » d'odoo.com ne
# contiennent pas odoo-bin. Strictement équivalent à celui du dépôt git.
import odoo
if __name__ == "__main__":
    odoo.cli.main()
LAUNCHER
  fi
  chmod +x /src/odoo/odoo-bin
fi

# --- où sont les addons du core ? ----------------------------------------------
# clone git   : odoo/addons/base (module base) + addons/ (le reste)
# archive src : idem, mais addons/ peut être absent sur un fork partiel
CORE_ADDONS=""
for d in /src/odoo/addons /src/odoo/odoo/addons; do
  [ -d "${d}" ] && [ -n "$(ls -A "${d}" 2>/dev/null)" ] && CORE_ADDONS="${CORE_ADDONS}${CORE_ADDONS:+,}${d#/src/odoo}"
done
[ -d /src/odoo/odoo/addons/base ] || [ -d /src/odoo/addons/base ] \
  || fail "module « base » introuvable (ni odoo/addons/base ni addons/base) :
         la source du core est incomplète."
log "addons du core : ${CORE_ADDONS:-aucun}"

# --- traçabilité ---------------------------------------------------------------
{
  echo "odoo_repo=${GITHUB_OWNER}/${ODOO_REPO}"
  echo "odoo_subdir=${ODOO_REL:-.}"
  echo "odoo_commit=${ODOO_COMMIT}"
  echo "odoo_branch=${ODOO_BRANCH}"
  echo "odoo_core_addons=${CORE_ADDONS}"
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
