# syntax=docker/dockerfile:1
###############################################################################
#  Image Odoo Enterprise — basée sur l'image officielle Odoo
#  ODOO_VERSION est injecté par docker-compose depuis le .env (17.0 / 18.0 / 19.0)
###############################################################################
ARG ODOO_VERSION=19.0
FROM odoo:${ODOO_VERSION}

ARG ODOO_VERSION=19.0
ENV ODOO_VERSION=${ODOO_VERSION} \
    PYTHONUNBUFFERED=1 \
    ODOO_RC=/etc/odoo/odoo.conf

USER root

# --- Dépendances système ------------------------------------------------------
# (wkhtmltopdf, fonts et libs Odoo sont déjà présents dans l'image officielle)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        gettext-base \
        postgresql-client \
        less \
        ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# --- Dépendances Python du projet --------------------------------------------
COPY requirements.txt /tmp/requirements.txt
RUN set -eux; \
    pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt \
      || pip3 install --no-cache-dir -r /tmp/requirements.txt

# --- Code applicatif ----------------------------------------------------------
# enterprise/     -> submodule git (odoo/enterprise, branche = ODOO_VERSION)
# addons-custom/  -> modules développés pour ce client
# addons-oca/     -> submodules OCA optionnels
COPY --chown=odoo:odoo enterprise      /mnt/enterprise
COPY --chown=odoo:odoo addons-custom   /mnt/addons-custom
COPY --chown=odoo:odoo addons-oca      /mnt/addons-oca

# --- Configuration & entrypoint ----------------------------------------------
COPY config/odoo.conf.tpl        /etc/odoo/odoo.conf.tpl
COPY entrypoint.sh               /usr/local/bin/odoo-entrypoint
COPY scripts/healthcheck.sh      /usr/local/bin/odoo-healthcheck

RUN set -eux; \
    chmod +x /usr/local/bin/odoo-entrypoint /usr/local/bin/odoo-healthcheck; \
    mkdir -p /var/lib/odoo /var/log/odoo /etc/odoo; \
    chown -R odoo:odoo /var/lib/odoo /var/log/odoo /etc/odoo

USER odoo

EXPOSE 8069 8072 5678

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD /usr/local/bin/odoo-healthcheck

ENTRYPOINT ["/usr/local/bin/odoo-entrypoint"]
CMD ["odoo"]
