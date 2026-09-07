#!/usr/bin/env bash
###############################################################################
#  Fonctions communes aux scripts d'odoo-stack.
#  Sourcé par new-client.sh, bin/*.sh — jamais exécuté directement.
###############################################################################

# --- Couleurs -----------------------------------------------------------------
if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[0;33m'
  C_BLU='\033[0;34m'; C_BOLD='\033[1m';   C_OFF='\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''; C_OFF=''
fi

info()  { printf "${C_BLU}ℹ${C_OFF}  %s\n" "$*"; }
ok()    { printf "${C_GRN}✓${C_OFF}  %s\n" "$*"; }
warn()  { printf "${C_YEL}⚠${C_OFF}  %s\n" "$*" >&2; }
err()   { printf "${C_RED}✗${C_OFF}  %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }
title() { printf "\n${C_BOLD}${C_BLU}%s${C_OFF}\n%s\n" "$1" "$(printf '─%.0s' $(seq 1 ${#1}))"; }

# --- Dépendances --------------------------------------------------------------
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "commande requise introuvable : $c"
  done
}

# --- Saisie -------------------------------------------------------------------
# ask VAR "Question" ["valeur par défaut"] [regex de validation] [message d'erreur]
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __regex="${4:-}" __msg="${5:-valeur invalide}"
  local __input
  while true; do
    if [ -n "${__default}" ]; then
      printf "%s ${C_YEL}[%s]${C_OFF} : " "${__prompt}" "${__default}"
    else
      printf "%s : " "${__prompt}"
    fi
    IFS= read -r __input || true
    __input="${__input:-${__default}}"
    if [ -z "${__input}" ]; then err "réponse obligatoire"; continue; fi
    if [ -n "${__regex}" ] && ! printf '%s' "${__input}" | grep -qE "${__regex}"; then
      err "${__msg}"; continue
    fi
    break
  done
  printf -v "${__var}" '%s' "${__input}"
}

# choose VAR "Question" "opt1" "opt2" ...   (la 1re option est la valeur par défaut)
choose() {
  local __var="$1" __prompt="$2"; shift 2
  local __opts=("$@") __i __sel
  printf "%s\n" "${__prompt}"
  for __i in "${!__opts[@]}"; do
    printf "   ${C_GRN}%d${C_OFF}) %s%s\n" "$((__i+1))" "${__opts[$__i]}" \
      "$([ "$__i" -eq 0 ] && printf ' (défaut)')"
  done
  while true; do
    printf "Votre choix ${C_YEL}[1]${C_OFF} : "
    IFS= read -r __sel || true
    __sel="${__sel:-1}"
    if printf '%s' "${__sel}" | grep -qE '^[0-9]+$' \
       && [ "${__sel}" -ge 1 ] && [ "${__sel}" -le "${#__opts[@]}" ]; then
      printf -v "${__var}" '%s' "${__opts[$((__sel-1))]}"
      return 0
    fi
    err "choix invalide"
  done
}

confirm() {
  local __prompt="${1:-Confirmer ?}" __ans
  printf "%s ${C_YEL}[o/N]${C_OFF} : " "${__prompt}"
  IFS= read -r __ans || true
  case "${__ans}" in [oOyY]*) return 0 ;; *) return 1 ;; esac
}

# --- Utilitaires --------------------------------------------------------------
slugify() {
  python3 - "$1" <<'PY'
import re, sys, unicodedata
raw = unicodedata.normalize('NFKD', sys.argv[1])
raw = ''.join(c for c in raw if not unicodedata.combining(c))
slug = re.sub(r'[^a-z0-9]+', '_', raw.lower()).strip('_')
slug = re.sub(r'_+', '_', slug)
print(slug or 'client')
PY
}

gen_password() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${len}"
  else
    head -c 200 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "${len}"
  fi
  printf '\n'
}

# PostgreSQL recommandé selon la version d'Odoo
pg_for_odoo() {
  case "$1" in
    16.0) echo 15 ;;
    17.0|18.0|19.0) echo 16 ;;
    *) echo 16 ;;
  esac
}

# Remplace __CLE__ par une valeur dans un fichier (portable macOS / Linux)
tpl_replace() {
  local file="$1" key="$2" value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as fh:
    content = fh.read()
content = content.replace('__%s__' % key, value)
with open(path, 'w', encoding='utf-8') as fh:
    fh.write(content)
PY
}

# Écrit / met à jour une clé dans un fichier .env
env_set() {
  local file="$1" key="$2" value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as fh:
    lines = fh.readlines()
pattern = re.compile(r'^(\s*)%s\s*=' % re.escape(key))
done = False
for i, line in enumerate(lines):
    if pattern.match(line):
        # conserve le commentaire de fin de ligne s'il y en a un
        comment = ''
        if '#' in line:
            after = line.split('=', 1)[1]
            if '#' in after:
                comment = '  #' + after.split('#', 1)[1].rstrip('\n')
        lines[i] = '%s=%s%s\n' % (key, value, comment)
        done = True
        break
if not done:
    lines.append('%s=%s\n' % (key, value))
with open(path, 'w', encoding='utf-8') as fh:
    fh.writelines(lines)
PY
}
