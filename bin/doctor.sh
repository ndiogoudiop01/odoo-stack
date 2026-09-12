#!/usr/bin/env bash
###############################################################################
#  doctor.sh — diagnostic complet avant/après déploiement.
#
#      ./bin/doctor.sh            # tout le parc
#      ./bin/doctor.sh acme       # un client
#
#  Vérifie : outils requis, ressources du serveur, cohérence du registre,
#  ports en conflit, .env complets, submodules initialisés, validité des
#  fichiers docker compose, secrets non commités.
###############################################################################
set -uo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STACK_ROOT
source "${STACK_ROOT}/lib/common.sh"
source "${STACK_ROOT}/lib/registry.sh"

FAILURES=0
check()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else err "$1"; FAILURES=$((FAILURES+1)); fi; }

TARGET="${1:-}"

title "Outils"
for tool in git docker python3 make; do
  check "${tool} installé" "command -v ${tool}"
done
check "docker compose v2 disponible" "docker compose version"
check "démon docker joignable" "docker info"

title "Ressources du serveur"
if command -v free >/dev/null 2>&1; then
  TOTAL_MB="$(free -m | awk '/^Mem:/ {print $2}')"
  AVAIL_MB="$(free -m | awk '/^Mem:/ {print $7}')"
  info "RAM : ${AVAIL_MB} Mo disponibles sur ${TOTAL_MB} Mo"
  [ "${TOTAL_MB}" -ge 4000 ] || warn "moins de 4 Go de RAM : 2 clients maximum en production"
fi
if command -v df >/dev/null 2>&1; then
  info "Disque : $(df -h / | awk 'NR==2 {print $4" libres sur "$2}')"
fi
CLIENT_COUNT="$(find "${STACK_ROOT}/clients" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
info "Clients déclarés : ${CLIENT_COUNT}"

title "Images de base"
if [ -f "${STACK_ROOT}/base-images/base.env" ]; then
  ok "base-images/base.env présent"
  grep -qE '^GITHUB_TOKEN=.+' "${STACK_ROOT}/base-images/base.env" \
    && ok "  token GitHub renseigné" \
    || { warn "  GITHUB_TOKEN vide — impossible de construire une image de base"; }
  if [ -f "${STACK_ROOT}/.git/index" ] && \
     git -C "${STACK_ROOT}" ls-files --error-unmatch base-images/base.env >/dev/null 2>&1; then
    err "  ⚠ base-images/base.env EST SUIVI PAR GIT (contient un token) :"
    err "    git -C ${STACK_ROOT} rm --cached base-images/base.env"
    FAILURES=$((FAILURES+1))
  fi
else
  warn "base-images/base.env absent — lancez ./base-images/build.sh pour le générer"
fi
if command -v docker >/dev/null 2>&1; then
  IMGS="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '/odoo:[0-9]+\.[0-9]+-(enterprise|community)$' || true)"
  [ -n "${IMGS}" ] && { info "images de base locales :"; printf '    %s\n' ${IMGS}; } \
                   || warn "aucune image de base Odoo trouvée localement"
fi

title "Registre"
if [ -f "${REGISTRY_FILE}" ]; then
  ok "registry/clients.tsv présent"
  DUPES="$(awk -F'\t' 'NR>1 && $1 !~ /^#/ {print $7}' "${REGISTRY_FILE}" | sort | uniq -d)"
  if [ -n "${DUPES}" ]; then
    err "blocs de ports en doublon : ${DUPES}"; FAILURES=$((FAILURES+1))
  else
    ok "aucun conflit de ports dans le registre"
  fi
  DUPD="$(awk -F'\t' 'NR>1 && $1 !~ /^#/ {print $5}' "${REGISTRY_FILE}" | sort | uniq -d)"
  [ -z "${DUPD}" ] || { err "domaines en doublon : ${DUPD}"; FAILURES=$((FAILURES+1)); }
else
  warn "registre absent (aucun client créé ?)"
fi

# ---------------------------------------------------------------- par client
for dir in "${STACK_ROOT}"/clients/*/; do
  [ -d "${dir}" ] || continue
  slug="$(basename "${dir}")"
  [ -n "${TARGET}" ] && [ "${TARGET}" != "${slug}" ] && continue

  title "Client : ${slug}"

  if [ -f "${dir}.env" ]; then
    ok ".env présent"
    for v in CLIENT_SLUG ODOO_VERSION POSTGRES_VERSION ODOO_BASE_IMAGE DB_PASSWORD ODOO_MASTER_PASSWORD DB_NAME; do
      if grep -qE "^${v}=.+" "${dir}.env"; then :; else
        err "  variable ${v} vide ou absente"; FAILURES=$((FAILURES+1))
      fi
    done
    # secret trop court = généré à la main
    PWD_LEN="$(grep -E '^DB_PASSWORD=' "${dir}.env" | cut -d= -f2- | tr -d '"' | wc -c)"
    [ "${PWD_LEN}" -ge 16 ] || warn "  DB_PASSWORD très court (${PWD_LEN} caractères)"
  else
    err ".env manquant"; FAILURES=$((FAILURES+1))
  fi

  # --- image de base -------------------------------------------------------
  BASE_IMG="$(grep -E '^ODOO_BASE_IMAGE=' "${dir}.env" 2>/dev/null | head -1 \
              | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -z "${BASE_IMG}" ]; then
    err "ODOO_BASE_IMAGE absent du .env"; FAILURES=$((FAILURES+1))
  elif docker image inspect "${BASE_IMG}" >/dev/null 2>&1; then
    ok "image de base présente localement : ${BASE_IMG}"
  else
    warn "image de base absente en local : ${BASE_IMG}"
    warn "  -> docker pull ${BASE_IMG}   (ou ./base-images/build.sh <version> <édition> --push)"
  fi

  # --- réseau du reverse-proxy ---------------------------------------------
  NET="$(grep -E '^TRAEFIK_NETWORK=' "${dir}.env" 2>/dev/null | head -1 \
         | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')"
  NET="${NET:-traefik}"
  if docker network inspect "${NET}" >/dev/null 2>&1; then
    ok "réseau ${NET} présent"
  else
    warn "réseau ${NET} absent — sera créé par « make up » / par la plateforme"
  fi

  # --- domaine --------------------------------------------------------------
  if grep -qE '^DOMAIN=.+' "${dir}.env" 2>/dev/null; then
    ok "DOMAIN renseigné"
  else
    err "DOMAIN absent du .env (les labels Traefik seront invalides)"; FAILURES=$((FAILURES+1))
  fi

  if [ -d "${dir}.git" ]; then
    ok "dépôt git initialisé"
    if git -C "${dir}" ls-files --error-unmatch .env >/dev/null 2>&1; then
      err "  ⚠ LE FICHIER .env EST SUIVI PAR GIT — retirez-le immédiatement :"
      err "    git -C clients/${slug} rm --cached .env"
      FAILURES=$((FAILURES+1))
    else
      ok "  .env non suivi par git"
    fi
    if git -C "${dir}" ls-files --error-unmatch DEPLOY-ENV.txt >/dev/null 2>&1; then
      err "  ⚠ DEPLOY-ENV.txt est suivi par git — retirez-le"; FAILURES=$((FAILURES+1))
    fi
    REMOTE="$(git -C "${dir}" remote get-url origin 2>/dev/null || echo '')"
    [ -n "${REMOTE}" ] && info "  origin : ${REMOTE}" || warn "  aucun dépôt distant configuré"
  else
    warn "pas de dépôt git"
  fi

  if (cd "${dir}" && docker compose config >/dev/null 2>&1); then
    ok "docker-compose.yml valide"
  else
    err "docker-compose.yml invalide — détail : (cd clients/${slug} && docker compose config)"
    FAILURES=$((FAILURES+1))
  fi

  if command -v docker >/dev/null 2>&1; then
    RUNNING="$( (cd "${dir}" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null) | tr '\n' ' ')"
    [ -n "${RUNNING}" ] && info "services actifs : ${RUNNING}" || info "stack arrêtée"
  fi
done

title "Résultat"
if [ "${FAILURES}" -eq 0 ]; then
  ok "aucun problème bloquant détecté"
  exit 0
fi
err "${FAILURES} problème(s) à corriger"
exit 1
