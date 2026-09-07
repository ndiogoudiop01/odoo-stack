# Monter un client de version (17 → 18 → 19)

Une montée de version Odoo n'est **jamais** un simple changement de tag.
Elle se prépare sur une copie, se répète, et se joue en production dans une
fenêtre annoncée.

---

## Principe

Cette architecture rend l'opération réversible : la version est une variable
(`ODOO_VERSION`), le code métier est isolé dans `addons-custom/`, et vous avez
une sauvegarde complète avant chaque étape.

**Règle absolue : on ne saute pas de version.** 17 → 19 se fait en 17 → 18,
puis 18 → 19.

---

## 1. Préparer une copie de travail

```bash
cd clients/acme
make backup
make backup-pull

# nouveau client jetable, en version cible
cd ../..
./new-client.sh --name "ACME (migration 19)" --slug acme_mig \
                --version 19.0 --domain mig.acme.sn --db acme_mig --yes

cp -r clients/acme/addons-custom/* clients/acme_mig/addons-custom/
cd clients/acme_mig && make dev
make restore FILE=<archive de acme> DB=acme_mig
```

---

## 2. Migrer la base

Trois voies, par ordre de coût :

| Voie | Quand | Coût |
|---|---|---|
| **Odoo Upgrade** (upgrade.odoo.com) | client Enterprise sous contrat | inclus |
| **OpenUpgrade** (OCA) | Community, ou budget contraint | manuel, long |
| **Reprise de données** | base ancienne ou très dégradée | dépend du périmètre |

Voie recommandée en Enterprise :

```bash
# depuis le conteneur du client de migration
python3 <(curl -s https://upgrade.odoo.com/upgrade) test \
        -d acme_mig -t 19.0
```

Le service renvoie une base migrée à restaurer. Répétez jusqu'à obtenir un
rapport propre.

---

## 3. Adapter les modules custom

Points de rupture les plus fréquents :

| Depuis | Changement |
|---|---|
| 17 → 18 | `<tree>` devient `<list>` ; `attrs=`/`states=` supprimés (déjà en 17) au profit de `invisible="…"`, `readonly="…"`, `required="…"` |
| 17 → 18 | le chatter s'écrit `<chatter/>` au lieu de `<div class="oe_chatter">` |
| 18 → 19 | revoir les surcharges de `_compute_*` et les vues héritées d'apps profondément remaniées (Ventes, Comptabilité) |
| toutes | `@api.onchange` déprécié au profit de champs calculés `store=True, readonly=False` |
| toutes | assets : déclarer dans `__manifest__.py > assets`, plus de templates `qweb` |

Méthode :

```bash
make upgrade M=all 2>&1 | tee /tmp/upgrade.log
grep -E "ERROR|CRITICAL|WARNING.*deprecat" /tmp/upgrade.log
```

Traitez les erreurs dans l'ordre d'apparition : une seule vue cassée en fait
tomber dix autres.

---

## 4. Recette avec le client

Faites valider par écrit, sur la copie migrée :

* les 5 processus métier critiques du client, de bout en bout ;
* les rapports PDF (mise en page, en-têtes, totaux) ;
* les droits d'accès par profil utilisateur ;
* les intégrations (banque, e-commerce, API tierces) ;
* les états comptables sur un exercice complet.

---

## 5. Bascule en production

Fenêtre type, un samedi matin :

```bash
cd clients/acme
make backup && make backup-pull        # T0 : sauvegarde de sortie
make stop-odoo                         # gel des écritures

# 1. mettre à jour ODOO_VERSION dans .env et dans Coolify
#    (et POSTGRES_VERSION si la version PG change)
# 2. migrer la base avec la procédure rodée à l'étape 2
# 3. pousser le code custom adapté
git push origin main                   # Coolify rebuild

make upgrade M=all
make status
```

**Plan de retour arrière** (à annoncer avant de commencer) : remettre
`ODOO_VERSION` à l'ancienne valeur, redéployer, restaurer l'archive T0.
Compter 20 minutes. Ce plan doit être écrit *avant* la bascule, pas improvisé.

---

## 6. Après la bascule

* Surveiller `make logs` pendant les 2 premières heures.
* Réactiver et vérifier les crons (`Paramètres → Technique → Actions planifiées`).
* Vérifier l'envoi d'un e-mail réel.
* Lancer une sauvegarde manuelle une fois la journée passée.
* Supprimer le client de migration : `rm -rf clients/acme_mig` et retirer sa
  ligne du registre.

---

## Changement de version PostgreSQL

Passer de PG 15 à PG 16 **ne se fait pas** en changeant le tag de l'image : le
volume de données n'est pas compatible.

```bash
make backup                       # dump logique (pg_dump = portable)
make down
docker volume rm acme_db-data     # nom exact via : docker volume ls
# modifier POSTGRES_VERSION dans .env
make up
make restore FILE=/backups/…      # le dump se recharge dans la nouvelle version
```
