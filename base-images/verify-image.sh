#!/bin/sh
###############################################################################
#  verify-image.sh — contrôles exécutés à la FIN du build de l'image de base.
#
#  Une image qui ne passe pas ces contrôles ne sort JAMAIS du build : mieux vaut
#  un build rouge qu'un conteneur qui redémarre en boucle en production.
#
#  Point important, Odoo 19 :
#    · Odoo <= 18 -> « odoo » est un paquet python CLASSIQUE (odoo/__init__.py)
#    · Odoo 19    -> « odoo » est un paquet-ESPACE-DE-NOMS (PEP 420) : il n'y a
#                    PAS d'odoo/__init__.py. « import odoo » rend alors un
#                    module VIDE, et « odoo.release » lève :
#                        AttributeError: module 'odoo' has no attribute 'release'
#                    Ce n'est pas une image cassée : c'est le contrôle qui doit
#                    importer le SOUS-MODULE (import odoo.release).
###############################################################################
set -eu

PY="${PY:-/opt/venv/bin/python}"
ODOO_HOME="${ODOO_HOME:-/opt/odoo}"

fail() { printf '\n[verify] ECHEC : %s\n' "$*" >&2; exit 1; }
ok()   { printf '[verify] OK    %s\n' "$*"; }

# --- 1. le module « base » ----------------------------------------------------
if   [ -d "${ODOO_HOME}/odoo/addons/base" ]; then BASE="odoo/addons/base"
elif [ -d "${ODOO_HOME}/addons/base" ];      then BASE="addons/base"
else
  printf '[verify] contenu de %s :\n' "${ODOO_HOME}" >&2
  ls -A "${ODOO_HOME}" >&2 || true
  fail "module « base » introuvable (ni odoo/addons/base ni addons/base) :
         la source du core est incomplète."
fi
ok "module base       ${BASE}"

# --- 2. le lanceur ------------------------------------------------------------
[ -x "${ODOO_HOME}/odoo-bin" ] || fail "odoo-bin absent ou non exécutable dans ${ODOO_HOME}"
ok "lanceur           ${ODOO_HOME}/odoo-bin"

# --- 3. le paquet python s'importe réellement ---------------------------------
"${PY}" - <<'PY' || fail "le paquet python « odoo » ne s'importe pas (trace ci-dessus).
         Causes habituelles : dossier odoo/ incomplet dans le dépôt, dépendance
         manquante dans requirements.txt, ou version de Python inadaptée."
import sys, traceback

try:
    import odoo.release as release   # présent dans TOUTES les versions
    import odoo.cli                  # point d'entrée réel du serveur
except Exception:
    traceback.print_exc()
    try:
        import odoo
        print("odoo.__file__ =", getattr(odoo, "__file__", None), file=sys.stderr)
        print("odoo.__path__ =", list(getattr(odoo, "__path__", [])), file=sys.stderr)
    except Exception:
        print("« import odoo » lui-même a échoué", file=sys.stderr)
    print("sys.path =", sys.path, file=sys.stderr)
    sys.exit(1)

import odoo
kind = "classique" if getattr(odoo, "__file__", None) else "espace de noms (PEP 420)"
print(f"[verify] OK    paquet python   odoo {release.version}  [{kind}]")
PY

# --- 4. cohérence version demandée / version réelle ---------------------------
#  Avertissement et non erreur : les versions « saas~xx.y » ne portent pas le
#  même libellé que le tag de l'image.
REAL="$("${PY}" -c 'import odoo.release as r; print(r.series)')"
if [ -n "${ODOO_VERSION:-}" ] && [ "${REAL}" != "${ODOO_VERSION}" ]; then
  printf '[verify] ATTENTION : image demandée en %s, sources en %s.\n' \
         "${ODOO_VERSION}" "${REAL}" >&2
  printf '[verify]             vérifiez ODOO_BRANCH / ODOO_SUBDIR dans base.env.\n' >&2
fi
ok "version           ${REAL}"

# --- 5. outils externes -------------------------------------------------------
command -v wkhtmltopdf >/dev/null || fail "wkhtmltopdf absent : les rapports PDF ne fonctionneraient pas"
ok "wkhtmltopdf       $(wkhtmltopdf --version 2>/dev/null | head -1)"
command -v rtlcss >/dev/null \
  || printf '[verify] ATTENTION : rtlcss absent, le rendu RTL (arabe) sera dégradé.\n' >&2

printf '[verify] image valide\n'
