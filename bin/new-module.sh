#!/usr/bin/env bash
###############################################################################
#  new-module.sh — génère un module Odoo propre dans addons-custom/ d'un client.
#
#  Usage :
#      ./bin/new-module.sh <slug_client> <nom_module> ["Titre affiché"]
#
#  Exemple :
#      ./bin/new-module.sh acme acme_ventes "ACME · Ventes"
#
#  Produit un module conforme aux conventions Odoo 17/18/19 :
#  manifest, modèle exemple, vues list/form, action + menu, droits d'accès,
#  dossier i18n prêt pour la traduction FR.
###############################################################################
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STACK_ROOT
source "${STACK_ROOT}/lib/common.sh"

CLIENT="${1:-}"; MODULE="${2:-}"; TITLE="${3:-}"
[ -n "${CLIENT}" ] && [ -n "${MODULE}" ] || \
  die "usage : ./bin/new-module.sh <slug_client> <nom_module> [\"Titre\"]"

printf '%s' "${MODULE}" | grep -qE '^[a-z][a-z0-9_]{2,50}$' || \
  die "nom de module invalide (minuscules, chiffres et _ ; ex. acme_ventes)"

CLIENT_DIR="${STACK_ROOT}/clients/${CLIENT}"
[ -d "${CLIENT_DIR}" ] || die "client introuvable : clients/${CLIENT}"

MOD_DIR="${CLIENT_DIR}/addons-custom/${MODULE}"
[ -d "${MOD_DIR}" ] && die "le module ${MODULE} existe déjà"

# Lit ODOO_VERSION du .env en retirant un éventuel commentaire de fin de ligne
ODOO_VERSION="$(grep -E '^ODOO_VERSION=' "${CLIENT_DIR}/.env" 2>/dev/null \
  | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' \
                                 -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
ODOO_VERSION="${ODOO_VERSION:-19.0}"
TITLE="${TITLE:-${MODULE}}"
MODEL="${MODULE}.record"
MODEL_UNDER="${MODULE}_record"
CLASS_NAME="$(python3 -c 'import sys; print("".join(w.capitalize() for w in sys.argv[1].split("_")))' "${MODULE}")Record"

# Odoo 16/17 : <tree> + <div class="oe_chatter">   |   Odoo 18/19 : <list> + <chatter/>
case "${ODOO_VERSION}" in
  16.*|17.*) LIST_TAG="tree"; VIEW_MODE="tree,form"; LEGACY_CHATTER=1 ;;
  *)         LIST_TAG="list"; VIEW_MODE="list,form"; LEGACY_CHATTER=0 ;;
esac
if [ "${LEGACY_CHATTER}" -eq 1 ]; then
  CHATTER_XML='<div class="oe_chatter"><field name="message_follower_ids"/><field name="activity_ids"/><field name="message_ids"/></div>'
else
  CHATTER_XML='<chatter/>'
fi

mkdir -p "${MOD_DIR}"/{models,views,security,data,i18n,static/description,tests}

cat > "${MOD_DIR}/__manifest__.py" <<EOF
{
    "name": "${TITLE}",
    "summary": "Module métier ${TITLE}",
    "version": "${ODOO_VERSION}.1.0.0",
    "category": "Customizations",
    "author": "odooAfia",
    "website": "https://odooafia.sn",
    "license": "OPL-1",
    "depends": ["base", "mail"],
    "data": [
        "security/ir.model.access.csv",
        "views/${MODEL_UNDER}_views.xml",
        "views/menus.xml",
    ],
    "demo": [],
    "installable": True,
    "application": False,
    "auto_install": False,
}
EOF

cat > "${MOD_DIR}/__init__.py" <<'EOF'
from . import models
EOF

cat > "${MOD_DIR}/models/__init__.py" <<EOF
from . import ${MODEL_UNDER}
EOF

cat > "${MOD_DIR}/models/${MODEL_UNDER}.py" <<EOF
from odoo import _, api, fields, models
from odoo.exceptions import ValidationError


class ${CLASS_NAME}(models.Model):
    _name = "${MODEL}"
    _description = "${TITLE}"
    _inherit = ["mail.thread", "mail.activity.mixin"]
    _order = "date desc, id desc"

    name = fields.Char(string="Référence", required=True, copy=False,
                       default=lambda self: _("Nouveau"), tracking=True)
    date = fields.Date(string="Date", default=fields.Date.context_today, tracking=True)
    partner_id = fields.Many2one("res.partner", string="Partenaire", tracking=True)
    amount = fields.Monetary(string="Montant", currency_field="currency_id", tracking=True)
    currency_id = fields.Many2one(
        "res.currency", string="Devise",
        default=lambda self: self.env.company.currency_id,
    )
    state = fields.Selection(
        [("draft", "Brouillon"), ("confirmed", "Confirmé"), ("done", "Terminé")],
        string="État", default="draft", tracking=True,
    )
    note = fields.Html(string="Notes")
    company_id = fields.Many2one(
        "res.company", string="Société", required=True,
        default=lambda self: self.env.company,
    )

    _sql_constraints = [
        ("name_company_uniq", "unique(name, company_id)",
         "Cette référence existe déjà pour cette société."),
    ]

    @api.constrains("amount")
    def _check_amount(self):
        for record in self:
            if record.amount < 0:
                raise ValidationError(_("Le montant ne peut pas être négatif."))

    def action_confirm(self):
        self.write({"state": "confirmed"})

    def action_done(self):
        self.write({"state": "done"})

    def action_draft(self):
        self.write({"state": "draft"})
EOF

cat > "${MOD_DIR}/views/${MODEL_UNDER}_views.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<odoo>

    <record id="view_${MODEL_UNDER}_list" model="ir.ui.view">
        <field name="name">${MODEL}.list</field>
        <field name="model">${MODEL}</field>
        <field name="arch" type="xml">
            <${LIST_TAG} string="${TITLE}">
                <field name="name"/>
                <field name="date"/>
                <field name="partner_id"/>
                <field name="amount" sum="Total"/>
                <field name="currency_id" column_invisible="1"/>
                <field name="state" widget="badge"
                       decoration-info="state == 'draft'"
                       decoration-success="state == 'done'"/>
            </${LIST_TAG}>
        </field>
    </record>

    <record id="view_${MODEL_UNDER}_form" model="ir.ui.view">
        <field name="name">${MODEL}.form</field>
        <field name="model">${MODEL}</field>
        <field name="arch" type="xml">
            <form string="${TITLE}">
                <header>
                    <button name="action_confirm" string="Confirmer" type="object"
                            class="btn-primary" invisible="state != 'draft'"/>
                    <button name="action_done" string="Terminer" type="object"
                            class="btn-primary" invisible="state != 'confirmed'"/>
                    <button name="action_draft" string="Remettre en brouillon" type="object"
                            invisible="state == 'draft'"/>
                    <field name="state" widget="statusbar"
                           statusbar_visible="draft,confirmed,done"/>
                </header>
                <sheet>
                    <div class="oe_title">
                        <h1><field name="name" placeholder="Référence"/></h1>
                    </div>
                    <group>
                        <group>
                            <field name="date"/>
                            <field name="partner_id"/>
                        </group>
                        <group>
                            <field name="amount"/>
                            <field name="currency_id" invisible="1"/>
                            <field name="company_id" groups="base.group_multi_company"/>
                        </group>
                    </group>
                    <notebook>
                        <page string="Notes">
                            <field name="note"/>
                        </page>
                    </notebook>
                </sheet>
                ${CHATTER_XML}
            </form>
        </field>
    </record>

    <record id="view_${MODEL_UNDER}_search" model="ir.ui.view">
        <field name="name">${MODEL}.search</field>
        <field name="model">${MODEL}</field>
        <field name="arch" type="xml">
            <search>
                <field name="name"/>
                <field name="partner_id"/>
                <filter name="draft" string="Brouillon" domain="[('state','=','draft')]"/>
                <filter name="done" string="Terminé" domain="[('state','=','done')]"/>
                <group expand="0" string="Regrouper par">
                    <filter name="group_partner" string="Partenaire"
                            context="{'group_by': 'partner_id'}"/>
                    <filter name="group_state" string="État"
                            context="{'group_by': 'state'}"/>
                </group>
            </search>
        </field>
    </record>

    <record id="action_${MODEL_UNDER}" model="ir.actions.act_window">
        <field name="name">${TITLE}</field>
        <field name="res_model">${MODEL}</field>
        <field name="view_mode">${VIEW_MODE}</field>
        <field name="help" type="html">
            <p class="o_view_nocontent_smiling_face">Créer le premier enregistrement</p>
        </field>
    </record>

</odoo>
EOF

cat > "${MOD_DIR}/views/menus.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <menuitem id="menu_${MODULE}_root" name="${TITLE}" sequence="90"/>
    <menuitem id="menu_${MODEL_UNDER}" name="${TITLE}"
              parent="menu_${MODULE}_root"
              action="action_${MODEL_UNDER}" sequence="10"/>
</odoo>
EOF

cat > "${MOD_DIR}/security/ir.model.access.csv" <<EOF
id,name,model_id:id,group_id:id,perm_read,perm_write,perm_create,perm_unlink
access_${MODEL_UNDER}_user,${MODEL}.user,model_${MODEL_UNDER},base.group_user,1,1,1,0
access_${MODEL_UNDER}_manager,${MODEL}.manager,model_${MODEL_UNDER},base.group_system,1,1,1,1
EOF

cat > "${MOD_DIR}/tests/__init__.py" <<EOF
from . import test_${MODEL_UNDER}
EOF

cat > "${MOD_DIR}/tests/test_${MODEL_UNDER}.py" <<EOF
from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged


@tagged("post_install", "-at_install")
class Test${CLASS_NAME}(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Record = self.env["${MODEL}"]

    def test_workflow(self):
        record = self.Record.create({"name": "TEST-001"})
        self.assertEqual(record.state, "draft")
        record.action_confirm()
        self.assertEqual(record.state, "confirmed")
        record.action_done()
        self.assertEqual(record.state, "done")

    def test_negative_amount_is_rejected(self):
        with self.assertRaises(ValidationError):
            self.Record.create({"name": "TEST-002", "amount": -1})
EOF

touch "${MOD_DIR}/i18n/.gitkeep" "${MOD_DIR}/data/.gitkeep" \
      "${MOD_DIR}/static/description/.gitkeep"

ok "module créé : clients/${CLIENT}/addons-custom/${MODULE}"
cat <<EOF

Pour l'installer :
    cd clients/${CLIENT}
    make dev
    make install M=${MODULE}

Le module contient déjà : un modèle avec chatter et workflow, des vues
list/form/search, un menu, les droits d'accès et deux tests unitaires
(\`make test M=${MODULE}\`).
EOF
