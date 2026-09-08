# syntax=docker/dockerfile:1.7
###############################################################################
#  IMAGE DE BASE ODOO — construite depuis TES dépôts privés GitHub.
#
#  Construite UNE fois par (version × édition), poussée sur un registre,
#  puis réutilisée en `FROM` par tous les clients de cette version.
#
#  Ne pas lancer `docker build` à la main : utiliser ./base-images/build.sh,
#  qui gère le secret, la version de Python et les tags.
#
#  Le token GitHub est passé en SECRET BuildKit : il n'apparaît dans aucune
#  couche de l'image finale, et les dossiers .git sont supprimés avant copie.
#
#  Étages :
#    sources  -> clone des dépôts privés (contient le token, jeté ensuite)
#    builder  -> compilation des dépendances Python dans un venv
#    runtime  -> image finale : venv + sources + wkhtmltopdf, sans compilateur
###############################################################################

ARG PYTHON_VERSION=3.12

###############################################################################
#  ÉTAGE 1 — sources depuis les dépôts privés
###############################################################################
FROM alpine/git:latest AS sources

ARG GITHUB_OWNER
ARG ODOO_REPO=odoo
ARG ENTERPRISE_REPO=enterprise
ARG ODOO_VERSION=19.0
ARG EDITION=enterprise
ARG GIT_DEPTH=1

WORKDIR /src

RUN --mount=type=secret,id=gh_token \
    set -eux; \
    TOKEN="$(cat /run/secrets/gh_token)"; \
    # GIT_DEPTH=0 -> historique complet ; sinon clone superficiel
    if [ "${GIT_DEPTH}" = "0" ]; then DEPTH=""; else DEPTH="--depth ${GIT_DEPTH}"; fi; \
    # shellcheck disable=SC2086
    git clone ${DEPTH} --branch "${ODOO_VERSION}" --single-branch \
        "https://x-access-token:${TOKEN}@github.com/${GITHUB_OWNER}/${ODOO_REPO}.git" odoo; \
    if [ "${EDITION}" = "enterprise" ]; then \
        git clone ${DEPTH} --branch "${ODOO_VERSION}" --single-branch \
            "https://x-access-token:${TOKEN}@github.com/${GITHUB_OWNER}/${ENTERPRISE_REPO}.git" enterprise; \
    else \
        mkdir -p enterprise; \
    fi; \
    { \
      echo "odoo_repo=${GITHUB_OWNER}/${ODOO_REPO}"; \
      echo "branch=${ODOO_VERSION}"; \
      echo "edition=${EDITION}"; \
      echo "odoo_commit=$(git -C odoo rev-parse HEAD)"; \
      if [ -d enterprise/.git ]; then \
        echo "enterprise_repo=${GITHUB_OWNER}/${ENTERPRISE_REPO}"; \
        echo "enterprise_commit=$(git -C enterprise rev-parse HEAD)"; \
      fi; \
      echo "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; \
    } > /src/SOURCES.txt; \
    rm -rf odoo/.git enterprise/.git

###############################################################################
#  ÉTAGE 2 — dépendances Python compilées dans un venv
###############################################################################
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential python3-dev pkg-config \
        libpq-dev libxml2-dev libxslt1-dev libzip-dev \
        libldap2-dev libsasl2-dev libssl-dev libffi-dev \
        libjpeg-dev zlib1g-dev libfreetype6-dev liblcms2-dev \
        libwebp-dev libtiff-dev libopenjp2-7-dev; \
    rm -rf /var/lib/apt/lists/*

COPY --from=sources /src/odoo/requirements.txt /tmp/requirements.txt

# Dépendances supplémentaires communes à tous nos projets.
# Ajoutez ici ce qui doit être disponible pour TOUS les clients ;
# le spécifique à un client reste dans son propre requirements.txt.
COPY extra-requirements.txt /tmp/extra-requirements.txt

RUN set -eux; \
    python -m venv /opt/venv; \
    /opt/venv/bin/pip install --upgrade pip setuptools wheel; \
    /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt; \
    /opt/venv/bin/pip install --no-cache-dir -r /tmp/extra-requirements.txt

###############################################################################
#  ÉTAGE 3 — image finale
###############################################################################
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG ODOO_VERSION=19.0
ARG EDITION=enterprise
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG TARGETARCH

LABEL org.opencontainers.image.title="Odoo ${ODOO_VERSION} (${EDITION})" \
      org.opencontainers.image.description="Image de base Odoo construite depuis des dépôts privés" \
      org.opencontainers.image.vendor="odooAfia"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/opt/odoo \
    ODOO_VERSION=${ODOO_VERSION} \
    ODOO_EDITION=${EDITION} \
    ODOO_HOME=/opt/odoo \
    ODOO_CORE_ADDONS=/opt/odoo/addons \
    ODOO_ENTERPRISE_ADDONS=/opt/odoo-enterprise \
    ODOO_RC=/etc/odoo/odoo.conf

# --- Bibliothèques d'exécution seulement (aucun compilateur) -----------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        libpq5 libxml2 libxslt1.1 libzip4 \
        libldap-2.5-0 libsasl2-2 libssl3 libffi8 \
        libjpeg62-turbo zlib1g libfreetype6 liblcms2-2 \
        libwebp7 libtiff6 libopenjp2-7 \
        postgresql-client gettext-base \
        nodejs npm \
        fonts-liberation fonts-dejavu-core fonts-noto-cjk \
        xfonts-75dpi xfonts-base \
        less; \
    rm -rf /var/lib/apt/lists/*

# --- wkhtmltopdf « patched Qt » : indispensable aux rapports PDF Odoo --------
RUN set -eux; \
    ARCH="${TARGETARCH:-amd64}"; \
    curl -fsSL -o /tmp/wkhtmltox.deb \
      "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_${ARCH}.deb"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb; \
    rm -f /tmp/wkhtmltox.deb; \
    rm -rf /var/lib/apt/lists/*; \
    wkhtmltopdf --version

# --- rtlcss : rendu des langues RTL (arabe) ---------------------------------
RUN npm install -g rtlcss@4 && npm cache clean --force

# --- venv Python et code Odoo -----------------------------------------------
COPY --from=builder /opt/venv           /opt/venv
COPY --from=sources /src/odoo           /opt/odoo
COPY --from=sources /src/enterprise     /opt/odoo-enterprise
COPY --from=sources /src/SOURCES.txt    /opt/SOURCES.txt

RUN set -eux; \
    printf '#!/bin/sh\nexec /opt/venv/bin/python /opt/odoo/odoo-bin "$@"\n' > /usr/local/bin/odoo; \
    chmod +x /usr/local/bin/odoo; \
    groupadd -g 1001 odoo; \
    useradd -u 1001 -g odoo -d /var/lib/odoo -s /bin/bash odoo; \
    mkdir -p /var/lib/odoo /var/log/odoo /etc/odoo /mnt/addons-custom /mnt/addons-oca; \
    chown -R odoo:odoo /var/lib/odoo /var/log/odoo /etc/odoo /mnt; \
    # garde-fou : l'image ne sort du build que si Odoo s'importe réellement
    /opt/venv/bin/python -c "import odoo; print('OK — Odoo', odoo.release.version)"; \
    test -d /opt/odoo/addons/base || (echo 'addons core introuvable' && exit 1)

VOLUME ["/var/lib/odoo"]
EXPOSE 8069 8072 5678

USER odoo
WORKDIR /opt/odoo

CMD ["odoo"]
