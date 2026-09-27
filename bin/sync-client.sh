#!/usr/bin/env bash
###############################################################################
#  sync-client.sh — remet l'INFRASTRUCTURE d'un client existant au niveau du
#  template courant, sans toucher à ce qui lui appartient.
#
#      ./bin/sync-client.sh <slug> [--dry-run] [--all]
#
#  Pourquoi ce script : un client est généré une fois, puis le template évolue
#  (correctifs de compose, de Dockerfile, d'entrypoint…). Sans lui, chaque
#  client reste figé sur la version du jour de sa création et rejoue des pannes
#  déjà corrigées ailleurs. C'est exactement ce qui arrive quand on corrige un
#  client à la main et pas les autres.
#
#  ÉCRASÉ (fichiers d'infrastructure, identiques pour tous les clients) :
#      docker-compose.yml · docker-compose.dev.yml · Dockerfile · entrypoint.sh
#      Makefile · .dockerignore · config/odoo.conf.tpl
#      nginx/  (odoo.conf, Dockerfile)      scripts/ (*.sh, Dockerfile)
#
#  JAMAIS TOUCHÉ (ce qui appartient au client) :
#      .env · DEPLOY-ENV.txt · requirements.txt · addons-custom/ · addons-oca/
#      .git/ · README.md · .vscode/
#
#  Une copie de sauvegarde horodatée est faite avant toute écriture.
###############################################################################
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${STACK_ROOT}/template"
CLIENTS="${STACK_ROOT}/clients"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
ok()   { printf '%s✓%s  %s\n'  "${c_ok}"   "${c_off}" "$*"; }
warn() { printf '%s⚠%s  %s\n'  "${c_warn}" "${c_off}" "$*"; }
die()  { printf '%s✗%s  %s\n'  "${c_err}"  "${c_off}" "$*" >&2; exit 1; }

DRY=0; ALL=0; SLUGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --all)     ALL=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*)        die "option inconnue : $1" ;;
    *)         SLUGS+=("$1"); shift ;;
  esac
done

[ -d "${TEMPLATE}" ] || die "template introuvable : ${TEMPLATE}"

if [ "${ALL}" -eq 1 ]; then
  SLUGS=()
  for d in "${CLIENTS}"/*/; do [ -d "${d}" ] && SLUGS+=("$(basename "${d}")"); done
fi
[ "${#SLUGS[@]}" -gt 0 ] || die "usage : ./bin/sync-client.sh <slug> [--dry-run]  |  --all"

# Fichiers d'infrastructure, relatifs à template/
FILES=(
  docker-compose.yml
  docker-compose.dev.yml
  Dockerfile
  entrypoint.sh
  Makefile
  .dockerignore
  config/odoo.conf.tpl
  nginx/odoo.conf
  nginx/Dockerfile
  scripts/Dockerfile
  scripts/backup.sh
  scripts/backup-cron.sh
  scripts/restore.sh
  scripts/healthcheck.sh
)

sync_one() {
  local slug="$1"
  local dir="${CLIENTS}/${slug}"
  local changed=0
  [ -d "${dir}" ] || { warn "client « ${slug} » introuvable, ignoré"; return 0; }

  printf '\n── %s ────────────────────────────────────────\n' "${slug}"

  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${dir}/.sync-backup-${stamp}"

  for f in "${FILES[@]}"; do
    local src="${TEMPLATE}/${f}"
    local dst="${dir}/${f}"
    [ -f "${src}" ] || continue
    if [ -f "${dst}" ] && cmp -s "${src}" "${dst}"; then continue; fi

    changed=1
    if [ "${DRY}" -eq 1 ]; then
      printf '   à mettre à jour : %s\n' "${f}"
      continue
    fi
    mkdir -p "$(dirname "${dst}")"
    if [ -f "${dst}" ]; then
      mkdir -p "$(dirname "${backup}/${f}")"
      cp -p "${dst}" "${backup}/${f}"
    fi
    cp "${src}" "${dst}"
    printf '   mis à jour : %s\n' "${f}"
  done

  if [ "${changed}" -eq 0 ]; then
    ok "${slug} : déjà à jour"
    return 0
  fi
  if [ "${DRY}" -eq 1 ]; then
    warn "${slug} : simulation, rien n'a été écrit"
    return 0
  fi

  chmod +x "${dir}/entrypoint.sh" 2>/dev/null || true
  chmod +x "${dir}"/scripts/*.sh   2>/dev/null || true

  # La sauvegarde ne doit jamais partir dans le dépôt du client.
  if [ -f "${dir}/.gitignore" ] && ! grep -q '^\.sync-backup-' "${dir}/.gitignore"; then
    printf '\n# copies de sauvegarde de bin/sync-client.sh\n.sync-backup-*/\n' \
      >> "${dir}/.gitignore"
  fi

  ok "${slug} : synchronisé (sauvegarde dans .sync-backup-${stamp}/)"
  printf '   à pousser :  cd clients/%s && git add -A && git commit -m "chore: sync template" && git push\n' "${slug}"
}

for s in "${SLUGS[@]}"; do sync_one "${s}"; done

printf '\n'
ok "terminé — .env, DEPLOY-ENV.txt, requirements.txt et addons-* n'ont pas été touchés"
