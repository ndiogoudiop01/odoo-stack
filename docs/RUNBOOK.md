# Runbook — les gestes du quotidien

Toutes les commandes se lancent depuis `clients/<slug>/`, sauf mention contraire.
`make` seul affiche la liste complète.

---

## Développement

| Je veux… | Commande |
|---|---|
| démarrer en local | `make dev` |
| voir les logs | `make logs` |
| redémarrer Odoo | `make restart` |
| créer un module | `make module c=acme m=acme_ventes` *(depuis la racine)* |
| installer un module | `make install M=acme_ventes` |
| mettre à jour un module | `make upgrade M=acme_ventes` |
| tout mettre à jour | `make upgrade M=all` |
| lancer les tests | `make test M=acme_ventes` |
| shell Python Odoo | `make odoo-shell` |
| console PostgreSQL | `make psql` |
| déboguer pas-à-pas | `make debug` puis F5 dans VSCode |
| arrêter | `make dev-down` |

### Quand faut-il `upgrade` plutôt que `restart` ?

| Modification | Action |
|---|---|
| code Python d'une méthode | `make restart` (ou rien en `--dev=all`) |
| nouveau champ, nouveau modèle | `make upgrade M=mon_module` |
| vue XML, menu, rapport | `make upgrade M=mon_module` |
| `__manifest__.py` (dépendances, data) | `make upgrade M=mon_module` |
| fichier de sécurité CSV | `make upgrade M=mon_module` |
| assets JS/SCSS | `make restart` (en `--dev=all`, rafraîchir suffit souvent) |

---

## Sauvegardes et restauration

```bash
make backup                                    # dump immédiat (base + filestore)
make backups                                   # lister les archives
make backup-pull                               # rapatrier dans ./backups-local/
make restore FILE=/backups/acme__acme_prod__20260907-0200.tar.gz
```

### Créer une base de test à partir de la production

```bash
make restore FILE=/backups/acme__acme_prod__20260907-0200.tar.gz DB=acme_test
```

La copie a automatiquement ses **crons désactivés**, ses **serveurs mail
sortants désactivés** et son code Enterprise délié : aucun risque d'envoyer un
e-mail réel ou de déclencher une facturation depuis une copie.

Pour y accéder, passez temporairement `LIST_DB=True` et élargissez `DB_FILTER`,
ou utilisez un sous-domaine dédié (`test.acme.sn`) avec sa propre ressource.

### Vérifier qu'une sauvegarde est restaurable

Une sauvegarde jamais testée n'est pas une sauvegarde. Une fois par trimestre :

```bash
make restore FILE=<dernière archive> DB=acme_restore_test
make psql DB=acme_restore_test -- -c "SELECT count(*) FROM res_partner;"
```

---

## Incidents

### Odoo ne démarre pas

```bash
make logs            # lire la dernière trace
make status          # état et santé des conteneurs
make config          # configuration docker compose résolue
```

Causes fréquentes :

| Message | Cause | Correction |
|---|---|---|
| `psycopg2.OperationalError: could not connect` | PostgreSQL pas encore prêt | l'entrypoint attend 120 s ; au-delà, vérifier `make logs-all` côté `db` |
| `FATAL: password authentication failed` | `DB_PASSWORD` changé après création du volume | remettre l'ancien mot de passe, ou recréer le volume et restaurer |
| `ModuleNotFoundError` | dépendance Python absente | l'ajouter dans `requirements.txt` puis `make rebuild` |
| `KeyError: 'ir.model.xxx'` au chargement | module mal désinstallé | `make odoo-shell` → nettoyer `ir_model_data` |
| `Database is being upgraded` bloqué | `-u` interrompu | redémarrer avec `-u` sur le même module |

### Odoo consomme toute la RAM

`LIMIT_MEMORY_SOFT` / `LIMIT_MEMORY_HARD` sont **par worker**. Avec 4 workers à
2,5 Go de hard limit, Odoo peut réclamer 10 Go. Ajustez :

```
ODOO_WORKERS=2
LIMIT_MEMORY_SOFT=1610612736     # 1,5 Go
LIMIT_MEMORY_HARD=2147483648     # 2 Go
```

puis `make restart` (ou redéployer côté Coolify).

### Une requête est lente

`PG_LOG_SLOW_MS=2000` journalise les requêtes de plus de 2 s :

```bash
docker compose logs db | grep "duration:"
```

Réflexes : index manquant sur un `Many2one` filtré, `search()` dans une boucle,
champ calculé non `store=True` utilisé dans un tri.

### Le chat / les notifications ne fonctionnent plus

Le websocket ne passe pas. Vérifiez que le domaine Coolify pointe sur le service
**`proxy`** et non sur `odoo`, et que `ODOO_WORKERS >= 1` (avec `workers=0`,
Odoo sert le websocket sur 8069 — c'est le mode dev uniquement).

---

## Ajouter des modules OCA

```bash
cd clients/acme
git submodule add -b 19.0 --depth 1 \
    https://github.com/OCA/l10n-france.git addons-oca/l10n-france
make rebuild
make install M=l10n_fr_siret
```

L'`addons_path` est recalculé automatiquement au démarrage : chaque dépôt placé
dans `addons-oca/` est détecté.

Mise à jour : `git submodule update --remote --depth 1 addons-oca/l10n-france`,
puis commit du nouveau pointeur.

---

## Ajouter une dépendance Python

```bash
echo "phonenumbers==8.13.44" >> requirements.txt
make rebuild
```

Épinglez toujours la version : sans `==`, deux déploiements du même commit
peuvent produire deux images différentes.

---

## Rotation d'un secret

1. Changer la valeur dans les **Environment Variables** de Coolify.
2. Redéployer.
3. `DB_PASSWORD` est un cas particulier : il est figé dans le volume PostgreSQL
   à sa création. Pour le changer réellement :

```bash
make psql
ALTER USER odoo WITH PASSWORD 'nouveau_mot_de_passe';
```

puis mettre à jour la variable et redéployer.

---

## Supprimer un client

```bash
cd clients/acme && make backup && make backup-pull   # sauvegarde de sortie
cd ../.. && make down c=acme
# supprimer la ressource dans Coolify (cocher « delete volumes »)
# retirer la ligne du client dans registry/clients.tsv
rm -rf clients/acme
```

Conservez l'archive de sortie hors du VPS : c'est souvent une obligation
contractuelle vis-à-vis du client.
