# Odoo Enterprise — __CLIENT_NAME__

| | |
|---|---|
| **Client** | `__CLIENT_SLUG__` |
| **Version Odoo** | `__ODOO_VERSION__` |
| **Domaine** | https://__DOMAIN__ |
| **Base par défaut** | `__DB_NAME__` |
| **Hébergement** | Coolify (VPS OVH) — ressource « Docker Compose » |

> Ce dépôt contient **tout** ce qu'il faut pour faire tourner l'instance : image,
> configuration, addons, sauvegardes. Il n'y a rien à installer à la main sur le
> serveur.

---

## 1. Démarrer en local (5 minutes)

```bash
git clone <url-du-repo> __CLIENT_SLUG__ && cd __CLIENT_SLUG__
make submodules          # récupère enterprise/ et addons-oca/
cp .env.example .env     # (déjà fait si le dossier vient de new-client.sh)
make dev                 # build + démarrage en mode développement
make logs                # suivre le démarrage
```

Puis ouvrez **http://localhost:__PROXY_PORT__** et créez une base.

Arrêter : `make dev-down`.

---

## 2. Les commandes du quotidien

```
make                     # liste toutes les commandes disponibles
make dev                 # démarrage en développement (hot-reload)
make logs                # logs Odoo en direct
make install M=mon_module     # installer un module
make upgrade M=mon_module     # mettre à jour un module
make upgrade M=all            # tout mettre à jour (après une grosse MAJ)
make test    M=mon_module     # lancer les tests du module
make odoo-shell               # shell Python Odoo (env, self…)
make psql                     # console PostgreSQL
make backup                   # sauvegarde immédiate
make backups                  # lister les sauvegardes
make restore FILE=/backups/…  # restaurer
make status                   # état + santé des conteneurs
```

**Règle d'or :** vous ne modifiez jamais un fichier *dans* un conteneur.
Tout se passe dans ce dossier, puis `make restart` ou `make upgrade`.

---

## 3. Où écrire du code ?

```
addons-custom/           <-- VOS modules (le seul dossier que vous modifiez)
  └── acme_ventes/
        ├── __init__.py
        ├── __manifest__.py
        ├── models/
        ├── views/
        └── security/
addons-oca/              <-- modules OCA (submodules git, en lecture seule)
enterprise/              <-- code Odoo Enterprise (submodule, JAMAIS modifié)
```

En mode `make dev`, `addons-custom/` est monté en direct dans le conteneur :

* modification **Python** → `make restart` (ou rien du tout, `--dev=all` recharge)
* modification **XML / vues** → `make upgrade M=mon_module`
* nouveau module → `make install M=mon_module`

---

## 4. Déboguer pas-à-pas (VSCode)

```bash
make debug        # Odoo démarre et ATTEND le débogueur
```

Dans VSCode : `F5` → **Odoo: attach (docker)**. Les points d'arrêt posés dans
`addons-custom/` fonctionnent immédiatement.

---

## 5. Mise en production

La production est pilotée par **Coolify** : chaque `git push` sur la branche
`main` déclenche un redéploiement automatique.

```bash
git add -A
git commit -m "feat(ventes): ajout du champ remise commerciale"
git push origin main
```

Après un déploiement qui touche des vues ou des modèles :

```bash
# depuis le terminal Coolify de la ressource, ou en SSH sur le VPS
make upgrade M=acme_ventes
```

> Détails et première configuration : voir `../docs/COOLIFY.md` du dépôt
> `odoo-stack`.

---

## 6. Sauvegardes

Un conteneur `backup` tourne en permanence et effectue un dump complet
(base + filestore) chaque nuit à **__BACKUP_HOUR__h00**, conservé
**__BACKUP_RETENTION_DAYS__ jours**.

```bash
make backup                                   # dump immédiat
make backups                                  # lister
make backup-pull                              # rapatrier dans ./backups-local/
make restore FILE=/backups/xxx.tar.gz         # restaurer en écrasant
make restore FILE=/backups/xxx.tar.gz DB=test # restaurer dans une base de test
```

Une restauration vers une **autre** base désactive automatiquement les crons et
les serveurs mail sortants : aucun risque d'envoyer des e-mails depuis une copie.

---

## 7. Sécurité — points non négociables

* `LIST_DB=False` en production (le sélecteur de base est masqué).
* `DB_FILTER` verrouille la base servie par le domaine.
* `ODOO_MASTER_PASSWORD` et `DB_PASSWORD` vivent **uniquement** dans les
  variables d'environnement Coolify, jamais dans git.
* Seul le service `proxy` est exposé ; Odoo et PostgreSQL restent sur le
  réseau interne du projet.
* Les ports hôte ne sont publiés qu'en mode `dev`.
