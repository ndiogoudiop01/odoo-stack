# odoo-stack

Parc **Odoo Enterprise multi-versions, multi-clients** prêt à déployer sur
**Coolify** — un dossier par client, une base PostgreSQL par client, un dossier
`addons-custom/` par client.

Conçu pour qu'un **développeur junior** puisse créer, lancer, déboguer,
sauvegarder et déployer un client **sans jamais écrire un Dockerfile**.

---

## 1. Le principe en une image

```
odoo-stack/                       <- ce dépôt : l'outillage
├── new-client.sh                 <- assistant : crée un client complet
├── Makefile                      <- pilotage du parc (make new, make list…)
├── template/                     <- le squelette copié pour chaque client
├── lib/  bin/                    <- fonctions et scripts internes
├── registry/clients.tsv          <- registre : clients, domaines, ports
├── docs/                         <- COOLIFY.md · RUNBOOK.md · UPGRADE.md
└── clients/                      <- un dépôt git AUTONOME par client
    ├── acme/                     Odoo 19.0   erp.acme.sn      acme_prod
    ├── diodio/                   Odoo 18.0   erp.diodio.sn    diodio_prod
    └── intouch/                  Odoo 17.0   odoo.intouch.sn  intouch_prod
```

Et à l'intérieur d'un client :

```
clients/acme/
├── docker-compose.yml      db (PostgreSQL dédié) + odoo + proxy nginx + backup
├── docker-compose.dev.yml  surcouche développement (hot-reload, debugpy, ports)
├── Dockerfile              FROM odoo:19.0 + requirements + addons
├── .env                    toute la configuration + les secrets (jamais commité)
├── COOLIFY-ENV.txt         variables à coller dans Coolify (jamais commité)
├── Makefile                make dev · make logs · make upgrade M=… · make backup
├── config/odoo.conf.tpl    odoo.conf généré au démarrage depuis le .env
├── nginx/odoo.conf         route 8069 + 8072 (websocket) — seul port exposé
├── scripts/                backup.sh · restore.sh · backup-cron.sh · healthcheck.sh
├── enterprise/             submodule git — code Odoo Enterprise (jamais modifié)
├── addons-oca/             submodules OCA optionnels
└── addons-custom/          VOS modules
```

**Isolation totale :** chaque client a son conteneur PostgreSQL, son volume de
données, son filestore, son image et son domaine. Un client qui tombe n'affecte
aucun autre.

---

## 2. Installation (une fois, sur le VPS ou en local)

```bash
git clone <url-de-ce-depot> odoo-stack && cd odoo-stack
chmod +x new-client.sh bin/*.sh
./bin/doctor.sh                 # vérifie docker, RAM, disque…
```

Prérequis : `git`, `docker` + `docker compose v2`, `make`, `python3`, et un
accès au dépôt privé **odoo/enterprise** (clé SSH de déploiement GitHub).

---

## 3. Créer un client (3 minutes)

```bash
make new          # ou ./new-client.sh
```

L'assistant demande le nom du client, la version d'Odoo, le domaine, la base,
le nombre de workers et l'heure de sauvegarde. Il génère ensuite :

* le dossier `clients/<slug>/` complet, **déjà initialisé en dépôt git** ;
* les **mots de passe** (base, master password, chiffrement des sauvegardes) ;
* un bloc de **5 ports réservés** pour le développement local, sans collision ;
* le fichier **`COOLIFY-ENV.txt`** à coller dans l'interface Coolify ;
* l'entrée dans `registry/clients.tsv`.

En mode non interactif (CI) :

```bash
./new-client.sh --name "ACME SARL" --version 19.0 \
                --domain erp.acme.sn --db acme_prod --workers 4 --yes
```

---

## 4. Développer

```bash
cd clients/acme
make submodules            # récupère enterprise/ (première fois)
make dev                   # build + démarrage, hot-reload actif
```

Créer un module propre en une commande :

```bash
make module c=acme m=acme_ventes t="ACME · Ventes"    # depuis la racine
```

Le module généré contient déjà un modèle avec chatter et workflow, des vues
list/form/search, un menu, les droits d'accès et deux tests unitaires.

Débogage pas-à-pas : `make debug` puis **F5** dans VSCode
(configuration `.vscode/launch.json` déjà fournie).

---

## 5. Déployer sur Coolify

Résumé — la procédure détaillée, avec les pièges, est dans
**[`docs/COOLIFY.md`](docs/COOLIFY.md)**.

1. Pousser le dépôt du client sur GitHub (dépôt **privé**).
2. Coolify → **New Resource → Docker Compose** → ce dépôt, branche `main`,
   fichier `docker-compose.yml`.
3. **Environment Variables** → coller le contenu de `COOLIFY-ENV.txt`.
4. Service `proxy` → **Domains** → `https://erp.acme.sn`.
5. DNS : enregistrement **A** vers l'IP du VPS.
6. **Deploy**. Le SSL Let's Encrypt est automatique.

Chaque `git push` sur `main` redéploie ensuite le client.

---

## 6. Exploiter le parc

```bash
make list                  # tous les clients, versions, domaines, ports
make doctor                # diagnostic complet (secrets commités, ports, .env…)
make status-all            # état des conteneurs de tout le parc
make backup-all            # sauvegarde immédiate de tous les clients
make logs c=acme           # logs d'un client
make dev  c=acme           # démarrer un client en dev
```

Voir **[`docs/RUNBOOK.md`](docs/RUNBOOK.md)** pour les gestes du quotidien
(module à mettre à jour, restauration, base de test, incident) et
**[`docs/UPGRADE.md`](docs/UPGRADE.md)** pour les montées de version Odoo.

---

## 7. Choix d'architecture (et pourquoi)

| Choix | Raison |
|---|---|
| **Image officielle `odoo:XX`** + addons montés | build de 2 min au lieu de 20, image maintenue par Odoo, pas de patch du core |
| **1 conteneur PostgreSQL par client** | restauration, tuning et incident strictement isolés ; une version PG par version Odoo |
| **nginx interne devant Odoo** | Odoo écoute sur 8069 **et** 8072 (websocket) ; Traefik ne route qu'un port. nginx fait l'aiguillage, le gzip et la limite d'upload |
| **`enterprise/` en submodule git** | le code Enterprise reste chez Odoo, versionné par un pointeur de commit ; aucun token dans l'image |
| **`odoo.conf` généré au démarrage** | une seule source de vérité (le `.env`), pas de config divergente entre local et prod |
| **Sidecar `backup`** | sauvegardes dans la stack, pas de cron sur l'hôte à maintenir ; suit le client s'il change de serveur |
| **Registre central des ports** | zéro collision entre 20 clients sur le même VPS en développement |
| **1 dépôt git par client** | droits d'accès par client, historique propre, déploiement Coolify natif |

### Dimensionnement indicatif (VPS OVH)

| RAM | Clients en production | Workers par client |
|---|---|---|
| 8 Go | 2 à 3 | 2 |
| 16 Go | 4 à 6 | 2 à 4 |
| 32 Go | 8 à 12 | 4 |

Compter ~350 Mo par worker Odoo + ~300 Mo pour PostgreSQL + ~20 Mo pour nginx
et le sidecar de sauvegarde.

---

## 8. Sécurité — les règles appliquées par défaut

* `LIST_DB=False` et `DB_FILTER` verrouillé : impossible d'atteindre la base
  d'un autre client depuis un domaine.
* Secrets uniquement dans `.env` (gitignoré) et dans Coolify — jamais dans git,
  jamais dans l'image. `make doctor` échoue si un `.env` a été commité.
* Seul `proxy` est exposé ; Odoo et PostgreSQL restent sur le réseau interne.
* Aucun port publié sur l'hôte en production (uniquement en `make dev`).
* Sauvegardes chiffrables en AES-256, rétention configurable.
* En-têtes de sécurité HTTP posés par nginx.
