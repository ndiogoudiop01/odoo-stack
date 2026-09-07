#!/usr/bin/env bash
###############################################################################
#  Entrypoint Odoo
#  1. attend que PostgreSQL réponde
#  2. génère /etc/odoo/odoo.conf à partir du template + variables du .env
#  3. lance Odoo (ou la commande passée en argument)
#
#  Aucune valeur n'est codée en dur ici : tout vient du .env.
###############################################################################
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 1. defaults
: "${DB_HOST:=db}"
: "${DB_PORT:=5432}"
: "${DB_USER:=odoo}"
: "${DB_PASSWORD:?DB_PASSWORD manquant dans le .env}"
: "${DB_NAME:=false}"
: "${DB_FILTER:=.*}"
: "${DB_MAXCONN:=64}"
: "${LIST_DB:=False}"
: "${ODOO_MASTER_PASSWORD:?ODOO_MASTER_PASSWORD manquant dans le .env}"
: "${ODOO_WORKERS:=2}"
: "${ODOO_MAX_CRON_THREADS:=1}"
: "${ODOO_LOG_LEVEL:=info}"
: "${ODOO_LOG_HANDLER:=:INFO}"
: "${WITHOUT_DEMO:=all}"
: "${LIMIT_MEMORY_SOFT:=2147483648}"
: "${LIMIT_MEMORY_HARD:=2684354560}"
: "${LIMIT_TIME_CPU:=600}"
: "${LIMIT_TIME_REAL:=1200}"
: "${LIMIT_TIME_REAL_CRON:=0}"
: "${LIMIT_REQUEST:=8192}"
: "${SERVER_WIDE_MODULES:=base,web}"
: "${ODOO_DEBUGPY:=0}"
: "${ODOO_DEBUGPY_WAIT:=0}"
: "${ODOO_EXTRA_ARGS:=}"

# addons_path : enterprise AVANT les addons core, custom en dernier (priorité).
ADDONS_DIRS=()
[ -d /mnt/enterprise ]    && [ -n "$(ls -A /mnt/enterprise 2>/dev/null)" ]    && ADDONS_DIRS+=("/mnt/enterprise")
ADDONS_DIRS+=("/usr/lib/python3/dist-packages/odoo/addons")
[ -d /mnt/addons-oca ]    && [ -n "$(ls -A /mnt/addons-oca 2>/dev/null)" ]    && ADDONS_DIRS+=("/mnt/addons-oca")
[ -d /mnt/addons-custom ] && [ -n "$(ls -A /mnt/addons-custom 2>/dev/null)" ] && ADDONS_DIRS+=("/mnt/addons-custom")

# Les dépôts OCA sont des dossiers de dépôts : on ajoute aussi leurs sous-dossiers.
if [ -d /mnt/addons-oca ]; then
  for repo in /mnt/addons-oca/*/; do
    [ -d "$repo" ] || continue
    # un dépôt OCA contient des modules (dossiers avec __manifest__.py)
    if compgen -G "${repo}*/__manifest__.py" >/dev/null; then
      ADDONS_DIRS+=("${repo%/}")
    fi
  done
fi

ADDONS_PATH="$(IFS=,; echo "${ADDONS_DIRS[*]}")"
export ADDONS_PATH

# ------------------------------------------------------- 2. attente PostgreSQL
log "attente de PostgreSQL sur ${DB_HOST}:${DB_PORT} ..."
for i in $(seq 1 60); do
  if PGPASSWORD="${DB_PASSWORD}" pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -q; then
    log "PostgreSQL est prêt (tentative ${i})"
    break
  fi
  if [ "${i}" -eq 60 ]; then
    log "ERREUR : PostgreSQL injoignable après 60 tentatives"
    exit 1
  fi
  sleep 2
done

# ------------------------------------------------------ 3. génération odoo.conf
export DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_FILTER DB_MAXCONN LIST_DB \
       ODOO_MASTER_PASSWORD ODOO_WORKERS ODOO_MAX_CRON_THREADS ODOO_LOG_LEVEL \
       ODOO_LOG_HANDLER WITHOUT_DEMO LIMIT_MEMORY_SOFT LIMIT_MEMORY_HARD \
       LIMIT_TIME_CPU LIMIT_TIME_REAL LIMIT_TIME_REAL_CRON LIMIT_REQUEST \
       SERVER_WIDE_MODULES

envsubst < /etc/odoo/odoo.conf.tpl > /etc/odoo/odoo.conf
chmod 640 /etc/odoo/odoo.conf
log "odoo.conf généré (addons_path=${ADDONS_PATH})"

# ------------------------------------------------------------------ 4. lancement
if [ "$#" -eq 0 ] || [ "$1" = "odoo" ]; then
  shift || true
  # shellcheck disable=SC2206
  EXTRA=( ${ODOO_EXTRA_ARGS} )
  if [ "${ODOO_DEBUGPY}" = "1" ]; then
    WAIT_FLAG=()
    [ "${ODOO_DEBUGPY_WAIT}" = "1" ] && WAIT_FLAG=(--wait-for-client)
    log "démarrage avec debugpy sur 0.0.0.0:5678 ${WAIT_FLAG[*]-}"
    exec python3 -m debugpy --listen 0.0.0.0:5678 "${WAIT_FLAG[@]}" \
         /usr/bin/odoo --config=/etc/odoo/odoo.conf "${EXTRA[@]}" "$@"
  fi
  exec odoo --config=/etc/odoo/odoo.conf "${EXTRA[@]}" "$@"
fi

# Toute autre commande (bash, psql, odoo shell, scripts...) est exécutée telle quelle.
exec "$@"
