#!/usr/bin/env bash
###############################################################################
#  new-client.sh — crée un nouveau client Odoo prêt à déployer.
#
#  Mode interactif (recommandé) :
#      ./new-client.sh
#
#  Mode direct (CI / scripts) :
#      ./new-client.sh --name "ACME SARL" --version 19.0 --edition enterprise \
#                      --domain erp.acme.sn --platform dokploy --yes
#
#  Ce que le script fabrique :
#    clients/<slug>/            dépôt git autonome, prêt pour Coolify / Dokploy
#      ├── Dockerfile           couche mince au-dessus de l'image de base
#      ├── docker-compose.yml   db + odoo + proxy nginx + backup, labels Traefik
#      ├── .env                 secrets générés, jamais commité
#      ├── DEPLOY-ENV.txt       variables à coller dans l'UI de la plateforme
#      ├── addons-oca/          submodules OCA optionnels
#      └── addons-custom/       vos modules
#  et enregistre le client + son bloc de ports dans registry/clients.tsv.
#
#  Le code Odoo (core + Enterprise) vient de VOS dépôts privés via l'image de
#  base : voir docs/BASE-IMAGES.md.
###############################################################################
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STACK_ROOT
# shellcheck source=lib/common.sh
source "${STACK_ROOT}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${STACK_ROOT}/lib/registry.sh"

TEMPLATE_DIR="${STACK_ROOT}/template"
CLIENTS_DIR="${STACK_ROOT}/clients"
BASE_CONF="${STACK_ROOT}/base-images/base.env"

# Valeurs par défaut du registre d'images, lues depuis base-images/base.env
REGISTRY_DEFAULT="ghcr.io/odooafia"
IMAGE_NAME_DEFAULT="odoo"
if [ -f "${BASE_CONF}" ]; then
  # shellcheck source=/dev/null
  REGISTRY_DEFAULT="$(grep -E '^REGISTRY=' "${BASE_CONF}" | cut -d= -f2- | tr -d '"' || echo "${REGISTRY_DEFAULT}")"
  IMAGE_NAME_DEFAULT="$(grep -E '^IMAGE_NAME=' "${BASE_CONF}" | cut -d= -f2- | tr -d '"' || echo "${IMAGE_NAME_DEFAULT}")"
fi

# ----------------------------------------------------------------- arguments
CLIENT_NAME=""; CLIENT_SLUG=""; ODOO_VERSION=""; DOMAIN=""; DB_NAME=""
EDITION=""; WORKERS=""; BACKUP_HOUR="2"; GIT_REMOTE=""; PLATFORM=""
BASE_IMAGE=""; ASSUME_YES=0

usage() { sed -n '2,25p' "$0" | sed 's/^#//'; exit 0; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)      CLIENT_NAME="$2"; shift 2 ;;
    --slug)      CLIENT_SLUG="$2"; shift 2 ;;
    --version)   ODOO_VERSION="$2"; shift 2 ;;
    --edition)   EDITION="$2"; shift 2 ;;
    --domain)    DOMAIN="$2"; shift 2 ;;
    --db)        DB_NAME="$2"; shift 2 ;;
    --platform)  PLATFORM="$2"; shift 2 ;;
    --base-image) BASE_IMAGE="$2"; shift 2 ;;
    --workers)   WORKERS="$2"; shift 2 ;;
    --remote)    GIT_REMOTE="$2"; shift 2 ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --help|-h)   usage ;;
    *) die "option inconnue : $1 (--help pour l'aide)" ;;
  esac
done

require_cmd git python3 docker
[ -d "${TEMPLATE_DIR}" ] || die "dossier template/ introuvable dans ${STACK_ROOT}"

printf "\n"
printf "${C_BOLD}${C_BLU}╔══════════════════════════════════════════════════════════╗${C_OFF}\n"
printf "${C_BOLD}${C_BLU}║           Nouveau client Odoo — odoo-stack               ║${C_OFF}\n"
printf "${C_BOLD}${C_BLU}╚══════════════════════════════════════════════════════════╝${C_OFF}\n"

# ------------------------------------------------------------------ questions
title "1/7 · Identité du client"

[ -n "${CLIENT_NAME}" ] || ask CLIENT_NAME "Nom commercial du client" "" '.{2,}' "au moins 2 caractères"
if [ -z "${CLIENT_SLUG}" ]; then
  SUGGESTED="$(slugify "${CLIENT_NAME}")"
  if [ "${ASSUME_YES}" -eq 1 ]; then
    CLIENT_SLUG="${SUGGESTED}"
  else
    ask CLIENT_SLUG "Identifiant technique (minuscules, _)" "${SUGGESTED}" \
        '^[a-z][a-z0-9_]{1,30}$' "minuscules, chiffres et _ uniquement, commence par une lettre"
  fi
fi

registry_has "${CLIENT_SLUG}" && die "le client « ${CLIENT_SLUG} » existe déjà dans le registre"
[ -d "${CLIENTS_DIR}/${CLIENT_SLUG}" ] && die "le dossier clients/${CLIENT_SLUG} existe déjà"

title "2/7 · Version et édition Odoo"
if [ -z "${ODOO_VERSION}" ]; then
  choose ODOO_VERSION "Quelle version d'Odoo ?" "19.0" "18.0" "17.0" "16.0"
fi
if [ -z "${EDITION}" ]; then
  if [ "${ASSUME_YES}" -eq 1 ]; then EDITION="enterprise"
  else choose EDITION "Quelle édition ?" "enterprise" "community"; fi
fi
PG_VERSION="$(pg_for_odoo "${ODOO_VERSION}")"

if [ -z "${BASE_IMAGE}" ]; then
  SUGGESTED_IMG="${REGISTRY_DEFAULT}/${IMAGE_NAME_DEFAULT}:${ODOO_VERSION}-${EDITION}"
  if [ "${ASSUME_YES}" -eq 1 ]; then
    BASE_IMAGE="${SUGGESTED_IMG}"
  else
    ask BASE_IMAGE "Image de base (construite depuis vos dépôts privés)" "${SUGGESTED_IMG}"
  fi
fi
ok "Odoo ${ODOO_VERSION} (${EDITION}) + PostgreSQL ${PG_VERSION}"
info "image de base : ${BASE_IMAGE}"

title "3/7 · Plateforme de déploiement"
if [ -z "${PLATFORM}" ]; then
  if [ "${ASSUME_YES}" -eq 1 ]; then PLATFORM="dokploy"
  else choose PLATFORM "Où ce client sera-t-il déployé ?" "dokploy" "coolify" "docker"; fi
fi
case "${PLATFORM}" in
  coolify) TRAEFIK_NETWORK="coolify";         EP_HTTP="http"; EP_HTTPS="https" ;;
  dokploy) TRAEFIK_NETWORK="dokploy-network"; EP_HTTP="web";  EP_HTTPS="websecure" ;;
  docker)  TRAEFIK_NETWORK="traefik";         EP_HTTP="web";  EP_HTTPS="websecure" ;;
  *) die "plateforme inconnue : ${PLATFORM} (dokploy | coolify | docker)" ;;
esac
CERTRESOLVER="letsencrypt"
ok "réseau Traefik : ${TRAEFIK_NETWORK} — entrypoints ${EP_HTTP}/${EP_HTTPS}"

title "4/7 · Domaine et base de données"
[ -n "${DOMAIN}" ] || ask DOMAIN "Domaine public (sans https://)" "erp.${CLIENT_SLUG}.sn" \
    '^[a-z0-9.-]+\.[a-z]{2,}$' "domaine invalide"
[ -n "${DB_NAME}" ] || ask DB_NAME "Nom de la base PostgreSQL" "${CLIENT_SLUG}_prod" \
    '^[a-z][a-z0-9_]{1,40}$' "minuscules, chiffres et _ uniquement"

title "5/7 · Dimensionnement"
if [ -z "${WORKERS}" ]; then
  if [ "${ASSUME_YES}" -eq 1 ]; then WORKERS=2; else
    ask WORKERS "Nombre de workers Odoo (2 = ~10 utilisateurs, 4 = ~30)" "2" '^[0-9]{1,2}$' "un nombre"
  fi
fi
if [ "${ASSUME_YES}" -eq 0 ]; then
  ask BACKUP_HOUR "Heure de la sauvegarde quotidienne (0-23)" "2" '^([0-9]|1[0-9]|2[0-3])$' "0 à 23"
fi

title "6/7 · Dépôt git"
if [ "${ASSUME_YES}" -eq 0 ] && [ -z "${GIT_REMOTE}" ]; then
  printf "URL du dépôt distant (vide = à configurer plus tard) : "
  IFS= read -r GIT_REMOTE || true
fi

PORT_BASE="$(registry_next_base)"
HTTP_PORT=$(( PORT_BASE + 0 ))
LONGPOLLING_PORT=$(( PORT_BASE + 1 ))
PROXY_PORT=$(( PORT_BASE + 2 ))
PG_PORT=$(( PORT_BASE + 3 ))
DEBUGPY_PORT=$(( PORT_BASE + 4 ))
registry_check_ports "${PORT_BASE}" || warn "des ports du bloc ${PORT_BASE} sont déjà pris (dev local uniquement)"

# ------------------------------------------------------------------ résumé
title "7/7 · Récapitulatif"
cat <<EOF
  Client            : ${CLIENT_NAME}  (${CLIENT_SLUG})
  Odoo              : ${ODOO_VERSION} — ${EDITION}
  Image de base     : ${BASE_IMAGE}
  PostgreSQL        : ${PG_VERSION} (conteneur dédié)
  Plateforme        : ${PLATFORM}  (réseau ${TRAEFIK_NETWORK})
  Domaine           : https://${DOMAIN}
  Base              : ${DB_NAME}
  Workers           : ${WORKERS}
  Sauvegarde        : chaque jour à ${BACKUP_HOUR}h00, rétention 14 jours
  Ports (dev local) : http ${HTTP_PORT} · ws ${LONGPOLLING_PORT} · nginx ${PROXY_PORT} · pg ${PG_PORT} · debug ${DEBUGPY_PORT}
  Dossier           : clients/${CLIENT_SLUG}
  Dépôt distant     : ${GIT_REMOTE:-<à configurer>}
EOF

if [ "${ASSUME_YES}" -eq 0 ]; then
  confirm "Créer ce client ?" || die "annulé"
fi

# ------------------------------------------------------------------ création
title "Création"
mkdir -p "${CLIENTS_DIR}"
cp -a "${TEMPLATE_DIR}" "${CLIENTS_DIR}/${CLIENT_SLUG}"
CLIENT_DIR="${CLIENTS_DIR}/${CLIENT_SLUG}"
mkdir -p "${CLIENT_DIR}/addons-custom" "${CLIENT_DIR}/addons-oca"
touch "${CLIENT_DIR}/addons-custom/.gitkeep" "${CLIENT_DIR}/addons-oca/.gitkeep"
chmod +x "${CLIENT_DIR}/entrypoint.sh" "${CLIENT_DIR}"/scripts/*.sh
ok "arborescence copiée"

# --- .env ---------------------------------------------------------------------
DB_PASSWORD="$(gen_password 32)"
MASTER_PASSWORD="$(gen_password 32)"
BACKUP_PASSPHRASE="$(gen_password 40)"

cp "${CLIENT_DIR}/.env.example" "${CLIENT_DIR}/.env"
env_set "${CLIENT_DIR}/.env" CLIENT_SLUG             "${CLIENT_SLUG}"
env_set "${CLIENT_DIR}/.env" CLIENT_NAME             "\"${CLIENT_NAME}\""
env_set "${CLIENT_DIR}/.env" ODOO_VERSION            "${ODOO_VERSION}"
env_set "${CLIENT_DIR}/.env" POSTGRES_VERSION        "${PG_VERSION}"
env_set "${CLIENT_DIR}/.env" ODOO_BASE_IMAGE         "${BASE_IMAGE}"
env_set "${CLIENT_DIR}/.env" DOMAIN                  "${DOMAIN}"
env_set "${CLIENT_DIR}/.env" TRAEFIK_NETWORK         "${TRAEFIK_NETWORK}"
env_set "${CLIENT_DIR}/.env" TRAEFIK_ENTRYPOINT_HTTP "${EP_HTTP}"
env_set "${CLIENT_DIR}/.env" TRAEFIK_ENTRYPOINT_HTTPS "${EP_HTTPS}"
env_set "${CLIENT_DIR}/.env" TRAEFIK_CERTRESOLVER    "${CERTRESOLVER}"
env_set "${CLIENT_DIR}/.env" DB_PASSWORD             "${DB_PASSWORD}"
env_set "${CLIENT_DIR}/.env" DB_NAME                 "${DB_NAME}"
env_set "${CLIENT_DIR}/.env" DB_FILTER               "^${DB_NAME}\$"
env_set "${CLIENT_DIR}/.env" ODOO_MASTER_PASSWORD    "${MASTER_PASSWORD}"
env_set "${CLIENT_DIR}/.env" ODOO_WORKERS            "${WORKERS}"
env_set "${CLIENT_DIR}/.env" BACKUP_HOUR             "${BACKUP_HOUR}"
env_set "${CLIENT_DIR}/.env" BACKUP_ENC_PASSPHRASE   "${BACKUP_PASSPHRASE}"
env_set "${CLIENT_DIR}/.env" HTTP_PORT               "${HTTP_PORT}"
env_set "${CLIENT_DIR}/.env" LONGPOLLING_PORT        "${LONGPOLLING_PORT}"
env_set "${CLIENT_DIR}/.env" PROXY_PORT              "${PROXY_PORT}"
env_set "${CLIENT_DIR}/.env" PG_PORT                 "${PG_PORT}"
env_set "${CLIENT_DIR}/.env" DEBUGPY_PORT            "${DEBUGPY_PORT}"
ok ".env généré (secrets aléatoires)"

# --- README -------------------------------------------------------------------
for pair in "CLIENT_SLUG=${CLIENT_SLUG}" "CLIENT_NAME=${CLIENT_NAME}" \
            "ODOO_VERSION=${ODOO_VERSION}" "EDITION=${EDITION}" \
            "BASE_IMAGE=${BASE_IMAGE}" "PLATFORM=${PLATFORM}" \
            "DOMAIN=${DOMAIN}" "DB_NAME=${DB_NAME}" \
            "PROXY_PORT=${PROXY_PORT}" "BACKUP_HOUR=${BACKUP_HOUR}" \
            "BACKUP_RETENTION_DAYS=14"; do
  tpl_replace "${CLIENT_DIR}/README.md" "${pair%%=*}" "${pair#*=}"
done
ok "README personnalisé"

# --- Fiche de déploiement -----------------------------------------------------
cat > "${CLIENT_DIR}/DEPLOY-ENV.txt" <<EOF
###############################################################################
#  ${CLIENT_NAME} — variables d'environnement pour ${PLATFORM}
#
#  Coolify : Ressource > Environment Variables > Developer view (coller tel quel)
#  Dokploy : Application > Environment > Environment Settings (coller tel quel)
#
#  Marquez comme secrètes : DB_PASSWORD, ODOO_MASTER_PASSWORD,
#  BACKUP_ENC_PASSPHRASE.
#  Ce fichier N'EST PAS commité (voir .gitignore).
###############################################################################
CLIENT_SLUG=${CLIENT_SLUG}
CLIENT_NAME=${CLIENT_NAME}
ODOO_VERSION=${ODOO_VERSION}
POSTGRES_VERSION=${PG_VERSION}
ODOO_BASE_IMAGE=${BASE_IMAGE}
TZ=Africa/Dakar
DOMAIN=${DOMAIN}
TRAEFIK_NETWORK=${TRAEFIK_NETWORK}
TRAEFIK_ENTRYPOINT_HTTP=${EP_HTTP}
TRAEFIK_ENTRYPOINT_HTTPS=${EP_HTTPS}
TRAEFIK_CERTRESOLVER=${CERTRESOLVER}
DB_USER=odoo
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
DB_FILTER=^${DB_NAME}\$
DB_MAXCONN=64
LIST_DB=False
ODOO_MASTER_PASSWORD=${MASTER_PASSWORD}
ODOO_WORKERS=${WORKERS}
ODOO_MAX_CRON_THREADS=1
LIMIT_MEMORY_SOFT=2147483648
LIMIT_MEMORY_HARD=2684354560
LIMIT_TIME_CPU=600
LIMIT_TIME_REAL=1200
LIMIT_TIME_REAL_CRON=0
LIMIT_REQUEST=8192
SERVER_WIDE_MODULES=base,web
WITHOUT_DEMO=all
ODOO_LOG_LEVEL=info
ODOO_LOG_HANDLER=:INFO
PG_MAX_CONNECTIONS=100
PG_SHARED_BUFFERS=256MB
PG_WORK_MEM=16MB
PG_MAINTENANCE_WORK_MEM=128MB
PG_EFFECTIVE_CACHE_SIZE=1GB
PG_LOG_SLOW_MS=2000
BACKUP_ENABLED=true
BACKUP_HOUR=${BACKUP_HOUR}
BACKUP_RETENTION_DAYS=14
BACKUP_ENC_PASSPHRASE=${BACKUP_PASSPHRASE}
EOF
printf 'DEPLOY-ENV.txt\n' >> "${CLIENT_DIR}/.gitignore"
ok "DEPLOY-ENV.txt généré"

# --- git ----------------------------------------------------------------------
cd "${CLIENT_DIR}"
git init -q -b main
git add -A >/dev/null
git -c user.email="dev@odoo-stack.local" -c user.name="odoo-stack" \
    commit -q -m "chore: initialisation du client ${CLIENT_SLUG} (Odoo ${ODOO_VERSION} ${EDITION})" || true

if [ -n "${GIT_REMOTE}" ]; then
  git remote add origin "${GIT_REMOTE}"
  ok "dépôt distant configuré : ${GIT_REMOTE}"
fi
cd "${STACK_ROOT}"

# --- registre -----------------------------------------------------------------
registry_add "${CLIENT_SLUG}" "${CLIENT_NAME}" "${ODOO_VERSION}-${EDITION}" "${PG_VERSION}" \
             "${DOMAIN}" "${DB_NAME}" "${PORT_BASE}" "${PLATFORM}" "${GIT_REMOTE:--}"
ok "client enregistré dans registry/clients.tsv"

# ------------------------------------------------------------------ conclusion
printf "\n${C_GRN}${C_BOLD}Client « ${CLIENT_SLUG} » créé.${C_OFF}\n\n"
cat <<EOF
Étapes suivantes :

  1. Vérifier que l'image de base existe
       docker pull ${BASE_IMAGE}
     Si elle n'existe pas encore :
       ./base-images/build.sh ${ODOO_VERSION} ${EDITION} --push

  2. Tester en local
       cd clients/${CLIENT_SLUG}
       make dev
       -> http://localhost:${PROXY_PORT}

  3. Créer un module de démarrage (optionnel)
       ./bin/new-module.sh ${CLIENT_SLUG} ${CLIENT_SLUG}_base

  4. Pousser le dépôt
       cd clients/${CLIENT_SLUG}
       git remote add origin <url>      # si pas déjà fait
       git push -u origin main

  5. Déployer — procédure détaillée : docs/$(echo "${PLATFORM}" | tr '[:lower:]' '[:upper:]').md
       · Nouvelle ressource « Docker Compose » pointant sur ce dépôt (branche main)
       · Coller le contenu de clients/${CLIENT_SLUG}/DEPLOY-ENV.txt
       · Connecter le serveur au registre : docker login ghcr.io
       · Deploy

  6. Pointer le DNS : enregistrement A  ${DOMAIN}  ->  IP du VPS

EOF
warn "clients/${CLIENT_SLUG}/.env et DEPLOY-ENV.txt contiennent les mots de passe : ne les commitez jamais."
