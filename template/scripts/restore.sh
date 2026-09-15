#!/bin/sh
###############################################################################
#  Restauration d'une sauvegarde produite par backup.sh.
#
#  Usage :
#      docker compose exec backup /bin/sh /scripts/restore.sh <archive> [base_cible]
#
#  Exemples :
#      /scripts/restore.sh /backups/acme__acme_prod__20260907-0200.tar.gz
#      /scripts/restore.sh /backups/acme__acme_prod__20260907-0200.tar.gz acme_test
#
#  ATTENTION : la base cible est SUPPRIMÉE puis recréée.
#  Arrêtez Odoo avant (`make stop-odoo`) pour éviter les connexions actives.
###############################################################################
set -eu

ARCHIVE="${1:?usage: restore.sh <archive.tar.gz[.enc]> [base_cible]}"
FILESTORE_DIR="${FILESTORE_DIR:-/filestore/filestore}"

log() { printf '[restore] %s\n' "$*"; }

[ -f "${ARCHIVE}" ] || { log "archive introuvable : ${ARCHIVE}"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- Déchiffrement éventuel ---------------------------------------------------
SRC="${ARCHIVE}"
case "${ARCHIVE}" in
  *.enc)
    [ -n "${BACKUP_ENC_PASSPHRASE:-}" ] || { log "BACKUP_ENC_PASSPHRASE requis"; exit 1; }
    command -v openssl >/dev/null 2>&1 || apk add --no-cache openssl >/dev/null 2>&1
    SRC="${WORK}/archive.tar.gz"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
      -pass "pass:${BACKUP_ENC_PASSPHRASE}" -in "${ARCHIVE}" -out "${SRC}"
    ;;
esac

tar -xzf "${SRC}" -C "${WORK}"
[ -f "${WORK}/manifest.txt" ] && { log "manifeste :"; cat "${WORK}/manifest.txt"; }

SOURCE_DB="$(grep '^database=' "${WORK}/manifest.txt" 2>/dev/null | cut -d= -f2 || true)"
TARGET_DB="${2:-${SOURCE_DB}}"
[ -n "${TARGET_DB}" ] || { log "impossible de déterminer la base cible"; exit 1; }

log "restauration vers la base « ${TARGET_DB} »"

# --- Recréation de la base ----------------------------------------------------
psql -v ON_ERROR_STOP=1 postgres <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${TARGET_DB}";
CREATE DATABASE "${TARGET_DB}" TEMPLATE template0 ENCODING 'UTF8';
SQL

psql -v ON_ERROR_STOP=1 -q -d "${TARGET_DB}" -f "${WORK}/dump.sql" >/dev/null
log "dump SQL restauré"

# --- Filestore ----------------------------------------------------------------
if [ -n "${SOURCE_DB}" ] && [ -d "${WORK}/filestore/${SOURCE_DB}" ]; then
  if [ -w "$(dirname "${FILESTORE_DIR}")" ] 2>/dev/null; then
    mkdir -p "${FILESTORE_DIR}"
    rm -rf "${FILESTORE_DIR:?}/${TARGET_DB}"
    cp -a "${WORK}/filestore/${SOURCE_DB}" "${FILESTORE_DIR}/${TARGET_DB}"
    log "filestore restauré dans ${FILESTORE_DIR}/${TARGET_DB}"
  else
    log "ATTENTION : /filestore est monté en lecture seule dans ce conteneur."
    log "            Lancez plutôt :  make restore FILE=... (le Makefile utilise le conteneur odoo)"
  fi
fi

# --- Neutralisation des automatismes si c'est une copie de test ---------------
if [ "${TARGET_DB}" != "${SOURCE_DB}" ]; then
  log "base de test détectée : désactivation des crons et des serveurs mail sortants"
  psql -v ON_ERROR_STOP=1 -d "${TARGET_DB}" <<'SQL' >/dev/null
UPDATE ir_cron SET active = false;
UPDATE ir_mail_server SET active = false;
DELETE FROM ir_config_parameter WHERE key = 'database.enterprise_code';
SQL
fi

log "terminé — pensez à redémarrer Odoo (make restart)"
