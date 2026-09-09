# odoo-stack

Parc **Odoo multi-versions, multi-clients**, construit depuis **vos dépôts
GitHub privés** (core + Enterprise) et déployable indifféremment sur
**Dokploy**, **Coolify** ou un Docker nu — un dossier par client, une base
PostgreSQL par client, un dossier `addons-custom/` par client.

Conçu pour qu'un **développeur junior** puisse créer, lancer, déboguer,
sauvegarder et déployer un client **sans jamais écrire un Dockerfile**.

---

## 1. Le principe

```
        VOS DÉPÔTS PRIVÉS                    REGISTRE (ghcr.io)
   ┌──────────────────────────┐        ┌──────────────────────────────┐
   │ <owner>/odoo             │        │ odoo:19.0-enterprise         │
   │   branches 17.0/18.0/19.0│  ───▶  │ odoo:18.0-enterprise         │
   │ <owner>/enterprise       │        │ odoo:17.0-community          │
   │   branches 17.0/18.0/19.0│        └──────────────┬───────────────┘
   └──────────────────────────┘                       │  FROM (build ~30 s)
                                          ┌───────────┴───────────┐
                                     clients/lodge          clients/acme
                                     erp.lodge.sn           erp.acme.sn
                                     Dokploy                Coolify
```

Le clone des sources privées a lieu **une fois par version**, pas une fois par
client. Chaque client n'ajoute que ses modules et sa configuration.

```
odoo-stack/                       <- ce dépôt : l'outillage
├── base-images/                  <- construction des images Odoo depuis vos dépôts
│   ├── Dockerfile                   multi-étages, token en secret BuildKit
│   ├── build.sh                     ./base-images/build.sh 19.0 enterprise --push
│   ├── extra-requirements.txt       dépendances Python communes à tous les clients
│   └── base.env                     GITHUB_OWNER, REGISTRY, PAT  (non commité)
├── new-client.sh                 <- assistant : crée un client complet
├── Makefile                      <- make new · list · doctor · base · dev c=acme
├── template/                     <- le squelette copié pour chaque client
├── lib/  bin/                    <- fonctions, new-module.sh, doctor.sh
├── registry/clients.tsv          <- registre : clients, domaines, ports, plateforme
├── docs/                         <- BASE-IMAGES · DOKPLOY · COOLIFY · RUNBOOK · UPGRADE
└── clients/                      <- un dépôt git AUTONOME par client
```

À l'intérieur d'un client :

```
clients/lodge/
├── docker-compose.yml      db (PostgreSQL dédié) + odoo + proxy nginx + backup
│                           labels Traefik explicites -> portable Coolify/Dokploy
├── docker-compose.dev.yml  surcouche développement (hot-reload, debugpy, ports)
├── Dockerfile              FROM <image de base> + requirements + addons  (~30 s)
├── .env                    toute la configuration + les secrets (jamais commité)
├── DEPLOY-ENV.txt          variables à coller dans l'UI de la plateforme
├── Makefile                make dev · logs · upgrade M=… · backup · pull-base
├── config/odoo.conf.tpl    odoo.conf généré au démarrage depuis le .env
├── nginx/odoo.conf         route 8069 + 8072 (websocket) — seul port exposé
├── scripts/                backup.sh · restore.sh · backup-cron.sh · healthcheck.sh
├── addons-oca/             submodules OCA optionnels
└── addons-custom/          VOS modules
```

**Isolation totale :** chaque client a son conteneur PostgreSQL, ses volumes, son
filestore, son image et son domaine. Un client qui tombe n'affecte aucun autre.

---

## 2. Installation (une fois)

```bash
git clone <url-de-ce-depot> odoo-stack && cd odoo-stack
chmod +x new-client.sh bin/*.sh base-images/build.sh
./bin/doctor.sh
```

Prérequis : `git`, `docker` + `compose v2` + `buildx`, `make`, `python3`, et un
**PAT GitHub fine-grained** avec `Contents: Read` sur vos deux dépôts Odoo.

---

## 3. Construire les images de base (une fois par version)

```bash
./base-images/build.sh 19.0                  # crée base-images/base.env, à compléter
# … renseigner GITHUB_OWNER / REGISTRY / GITHUB_TOKEN …
./base-images/build.sh 19.0 enterprise --push
./base-images/build.sh all --push            # 17.0, 18.0, 19.0
```

Puis, sur chaque VPS : `docker login ghcr.io -u <owner>`.

Détails, sécurité du token et automatisation CI : **[`docs/BASE-IMAGES.md`](docs/BASE-IMAGES.md)**.

---

## 4. Créer un client (3 minutes)

```bash
make new          # ou ./new-client.sh
```

L'assistant demande le nom, la version, l'édition, la **plateforme cible**, le
domaine, la base, les workers et l'heure de sauvegarde. Il génère :

* `clients/<slug>/` complet, **déjà initialisé en dépôt git** ;
* les **mots de passe** (base, master password, chiffrement des sauvegardes) ;
* les variables Traefik correspondant à la plateforme choisie ;
* un bloc de **5 ports réservés** pour le développement local, sans collision ;
* **`DEPLOY-ENV.txt`** à coller dans l'UI de Coolify ou Dokploy ;
* l'entrée dans `registry/clients.tsv`.

En mode non interactif :

```bash
./new-client.sh --name "Lodge Terre et Mer" --version 19.0 --edition enterprise \
                --domain erp.lodge.sn --platform dokploy --workers 4 --yes
```

---

## 5. Développer

```bash
cd clients/lodge
make dev                   # build + démarrage, hot-reload actif
make logs
```

Créer un module propre en une commande :

```bash
make module c=lodge m=lodge_pos t="Lodge · Point de vente"
```

Le module généré contient un modèle avec chatter et workflow, des vues
list/form/search adaptées à la version d'Odoo, un menu, les droits d'accès et
deux tests unitaires.

Débogage pas-à-pas : `make debug` puis **F5** dans VSCode.

---

## 6. Déployer

| Plateforme | Guide |
|---|---|
| Dokploy | **[`docs/DOKPLOY.md`](docs/DOKPLOY.md)** |
| Coolify | **[`docs/COOLIFY.md`](docs/COOLIFY.md)** |
| **Enterprise sur Coolify, de zéro** | **[`docs/ENTERPRISE-COOLIFY.md`](docs/ENTERPRISE-COOLIFY.md)** — runbook complet, sans registre |

Résumé : pousser le dépôt du client → créer une ressource **Docker Compose**
dessus → coller `DEPLOY-ENV.txt` → pointer le DNS → *Deploy*.

Le routage HTTPS est porté par des **labels Traefik dans le compose**, donc rien
à saisir dans l'onglet *Domains* de la plateforme. Passer un client de Dokploy à
Coolify revient à changer trois variables :

| | Coolify | Dokploy | Docker nu |
|---|---|---|---|
| `TRAEFIK_NETWORK` | `coolify` | `dokploy-network` | `traefik` |
| `TRAEFIK_ENTRYPOINT_HTTP` | `http` | `web` | `web` |
| `TRAEFIK_ENTRYPOINT_HTTPS` | `https` | `websecure` | `websecure` |

---

## 7. Exploiter le parc

```bash
make list                  # clients, versions, domaines, ports, plateforme
make doctor                # diagnostic (secrets commités, images, réseaux, .env)
make status-all            # état des conteneurs de tout le parc
make backup-all            # sauvegarde immédiate de tous les clients
make base v=19.0 e=enterprise      # (re)construire et publier une image de base
make dev c=lodge           # démarrer un client en dev
```

**[`docs/RUNBOOK.md`](docs/RUNBOOK.md)** pour les gestes du quotidien,
**[`docs/UPGRADE.md`](docs/UPGRADE.md)** pour les montées de version Odoo.

---

## 8. Choix d'architecture (et pourquoi)

| Choix | Raison |
|---|---|
| **Image de base par version**, poussée sur un registre | le clone privé a lieu 1 fois au lieu de 20 ; build client ~30 s ; le PAT ne circule pas dans les ressources du PaaS |
| **Token en secret BuildKit** | jamais dans une couche d'image ; `.git` supprimé avant copie ; `SOURCES.txt` garde la trace du commit exact |
| **Labels Traefik dans le compose** | un seul fichier pour Coolify, Dokploy et Docker nu ; aucune dépendance aux « magies » propriétaires |
| **1 conteneur PostgreSQL par client** | restauration, tuning et incident strictement isolés ; version PG alignée sur la version Odoo |
| **nginx interne devant Odoo** | Odoo écoute sur 8069 **et** 8072 (websocket) ; Traefik ne route qu'un port. nginx aiguille, compresse et fixe la limite d'upload |
| **`odoo.conf` généré au démarrage** | une seule source de vérité (le `.env`), pas de dérive entre local et prod |
| **Sidecar `backup`** | sauvegardes dans la stack, pas de cron hôte à maintenir ; suit le client s'il change de serveur |
| **Registre central des ports** | zéro collision entre 20 clients sur le même VPS en développement |
| **1 dépôt git par client** | droits d'accès par client, historique propre, déploiement natif |

### Dimensionnement indicatif (VPS OVH)

| RAM | Clients en production | Workers par client |
|---|---|---|
| 8 Go | 2 à 3 | 2 |
| 16 Go | 4 à 6 | 2 à 4 |
| 32 Go | 8 à 12 | 4 |

Compter ~350 Mo par worker Odoo + ~300 Mo pour PostgreSQL + ~20 Mo pour nginx et
le sidecar de sauvegarde.

---

## 9. Sécurité — les règles appliquées par défaut

* Le **PAT GitHub** ne vit que dans `base-images/base.env` (gitignoré, `chmod 600`)
  et dans les secrets CI. Jamais dans une image, jamais dans un dépôt client.
* `LIST_DB=False` et `DB_FILTER` verrouillé : impossible d'atteindre la base d'un
  autre client depuis un domaine.
* Secrets clients uniquement dans `.env` et dans l'UI de la plateforme.
  `make doctor` échoue si un `.env` ou un `base.env` a été commité.
* Seul `proxy` est exposé ; Odoo et PostgreSQL restent sur le réseau interne.
* Aucun port publié sur l'hôte en production (uniquement en `make dev`).
* Sauvegardes chiffrables en AES-256, rétention configurable.
* Redirection HTTP → HTTPS permanente et en-têtes de sécurité posés par nginx.
