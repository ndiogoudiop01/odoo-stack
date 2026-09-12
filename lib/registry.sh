#!/usr/bin/env bash
###############################################################################
#  Registre central des clients et des ports.
#
#  Fichier : registry/clients.tsv (versionné dans git, source de vérité)
#  Colonnes :
#     slug  nom  odoo  pg  domaine  base  port_base  plateforme  date  repo
#
#  Chaque client reçoit un BLOC de 10 ports consécutifs :
#     +0 HTTP   +1 longpolling   +2 nginx   +3 PostgreSQL   +4 debugpy
#  Ces ports ne servent qu'au développement local ; en production tout passe
#  par Traefik et rien n'est publié sur l'hôte.
###############################################################################

REGISTRY_FILE="${REGISTRY_FILE:-${STACK_ROOT}/registry/clients.tsv}"
PORT_BASE_START="${PORT_BASE_START:-8100}"
PORT_BLOCK="${PORT_BLOCK:-10}"

registry_init() {
  mkdir -p "$(dirname "${REGISTRY_FILE}")"
  if [ ! -f "${REGISTRY_FILE}" ]; then
    printf '# slug\tnom\todoo\tpg\tdomaine\tbase\tport_base\tplateforme\tcree_le\trepo\n' > "${REGISTRY_FILE}"
  fi
}

registry_has() {
  registry_init
  awk -F'\t' -v s="$1" '$1 == s { found = 1 } END { exit !found }' "${REGISTRY_FILE}"
}

# Prochain bloc de ports libre
registry_next_base() {
  registry_init
  local max
  max="$(awk -F'\t' '$1 !~ /^#/ && $7 ~ /^[0-9]+$/ { if ($7 > m) m = $7 } END { print m + 0 }' "${REGISTRY_FILE}")"
  if [ "${max}" -eq 0 ]; then
    echo "${PORT_BASE_START}"
  else
    echo $(( max + PORT_BLOCK ))
  fi
}

registry_add() {
  # slug nom odoo pg domaine base port_base plateforme repo
  registry_init
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:--}" "$(date '+%Y-%m-%d')" "${9:--}" \
    >> "${REGISTRY_FILE}"
}

registry_remove() {
  registry_init
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v s="$1" 'BEGIN{OFS="\t"} $1 != s' "${REGISTRY_FILE}" > "${tmp}"
  mv "${tmp}" "${REGISTRY_FILE}"
}

registry_list() {
  registry_init
  printf "%-14s %-20s %-18s %-3s %-26s %-16s %-9s %-9s %s\n" \
    "SLUG" "CLIENT" "ODOO" "PG" "DOMAINE" "BASE" "PORTS" "PLATEFORME" "CRÉÉ LE"
  printf '%.0s─' {1..140}; printf '\n'
  awk -F'\t' 'NR > 1 && $1 !~ /^#/ {
      printf "%-14s %-20s %-18s %-3s %-26s %-16s %-9s %-9s %s\n",
             $1, $2, $3, $4, $5, $6, $7 "-" ($7+4), $8, $9
  }' "${REGISTRY_FILE}"
}

# Vérifie qu'aucun port du bloc n'est déjà occupé sur la machine
registry_check_ports() {
  local base="$1" p busy=0
  for offset in 0 1 2 3 4; do
    p=$(( base + offset ))
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then
      warn "le port ${p} est déjà utilisé sur cette machine"
      busy=1
    fi
  done
  return "${busy}"
}
