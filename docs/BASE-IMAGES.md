# Images de base Odoo — construites depuis vos dépôts privés

Le code Odoo (core **et** Enterprise) vient de **vos** dépôts GitHub privés, pas
des dépôts officiels. Il est empaqueté une fois par version dans une **image de
base**, que tous les clients de cette version réutilisent en `FROM`.

```
        VOS DÉPÔTS PRIVÉS                    REGISTRE (ghcr.io)
   ┌──────────────────────────┐        ┌──────────────────────────────┐
   │ <owner>/odoo             │        │ odoo:19.0-enterprise         │
   │   branches 17.0/18.0/19.0│  ───▶  │ odoo:18.0-enterprise         │
   │ <owner>/enterprise       │        │ odoo:17.0-community          │
   │   branches 17.0/18.0/19.0│        └──────────────┬───────────────┘
   └──────────────────────────┘                       │  FROM
                                          ┌───────────┴───────────┐
                                     clients/lodge          clients/acme
                                     (+ addons-custom)      (+ addons-custom)
```

**Pourquoi ce découpage.** Cloner plusieurs Go de sources dans chacun des 20
dépôts clients coûterait 20 fois le temps et l'espace, et obligerait à donner le
token GitHub à chaque ressource du PaaS. Ici le clone privé a lieu **une fois par
version**, et le build d'un client dure ~30 secondes.

---

## 1. Prérequis

* `git`, `docker` ≥ 23 avec `buildx`
* un compte GitHub hébergeant vos sources Odoo
* **pour publier les images** : un PAT *classic* avec `write:packages`
* **pour lire des dépôts privés** : un PAT *fine-grained* avec `Contents: Read-only`

La création pas à pas des deux tokens est en **[§5](#5-les-deux-tokens-github--et-comment-les-créer)** :
ils ne sont pas du même type et ne sont pas interchangeables.

---

## 2. Configuration (une fois)

```bash
./base-images/build.sh 19.0          # crée base-images/base.env puis s'arrête
```

### Comment remplir `base.env` : lire l'URL GitHub

```
https://github.com/ndiogoudiop01/odoo/tree/18.0/18.0
                   └────┬─────┘ └─┬─┘      └─┬┘ └┬┘
                  GITHUB_OWNER  ODOO_REPO  branche  dossier
```

| Variable | Ce qu'on met | Exemple |
|---|---|---|
| `GITHUB_OWNER` | le compte ou l'organisation | `ndiogoudiop01` |
| `ODOO_REPO` | le **nom du dépôt seul** — pas l'URL, pas de `.git`, pas de `owner/` | `odoo` |
| `ENTERPRISE_REPO` | idem pour les modules Enterprise (ignoré en `community`) | `entreprise` |
| `REGISTRY` | destination des images | `ghcr.io/ndiogoudiop01` |
| `GITHUB_TOKEN` | **vide si les dépôts sont publics** | *(vide)* |

Deux choses ne se mettent **pas** dans `base.env` :

* la **branche** vient du numéro de version passé à `build.sh` (`18.0` → branche
  `18.0`). Si elle diffère : `--odoo-branch <nom>` ;
* le **dossier** (`18.0` dans l'URL ci-dessus) est détecté automatiquement.

### Exemple complet — Community 18.0 depuis un dépôt public

```bash
# base-images/base.env
GITHUB_OWNER=ndiogoudiop01
ODOO_REPO=odoo
ENTERPRISE_REPO=entreprise
REGISTRY=ghcr.io/ndiogoudiop01
IMAGE_NAME=odoo
GITHUB_TOKEN=                 # vide : dépôt public
GIT_DEPTH=1
```

```bash
./base-images/build.sh 18.0 community --probe    # vérifier
./base-images/build.sh 18.0 community --push     # construire et publier
# -> ghcr.io/ndiogoudiop01/odoo:18.0-community
```

### Token : vide ou renseigné, mais jamais « au cas où »

Sur un dépôt **public**, présenter un token qui n'a aucun droit dessus fait
**échouer** l'accès avec `403 — Write access to repository not granted`, alors
que l'anonyme réussirait. Le build sait retomber tout seul en anonyme, mais la
règle reste :

* dépôts **publics** → `GITHUB_TOKEN=` vide (ou `--anonymous`) ;
* dépôts **privés** → PAT fine-grained listant **chaque** dépôt dans
  *Repository access*, permission **Contents: Read-only**.

Le token reste nécessaire pour **publier** sur `ghcr.io` (scope `write:packages`) :
c'est `docker login`, indépendant du clone.

Ce fichier contient un token : il est déjà dans `.gitignore` et créé en `chmod 600`.
`make doctor` échoue s'il se retrouve suivi par git.

---

## 3. Vérifier la structure de vos dépôts (recommandé au premier build)

Vos forks n'ont pas forcément la même arborescence que `odoo/odoo`. Le mode
`--probe` clone et affiche ce qu'il trouve, sans rien construire :

```bash
./base-images/build.sh 19.0 enterprise --probe
```

Pour chaque dépôt, la sonde répond à trois questions dans l'ordre :

1. **le dépôt est-il joignable ?** sinon, elle affiche la sortie brute de git
   (token masqué) — nom de dépôt erroné, dépôt privé sans droits, token expiré ;
2. **la branche existe-t-elle ?** sinon, elle liste toutes les branches du dépôt ;
3. **où est le code ?** elle affiche la racine, `odoo-bin`, `requirements.txt` et
   le premier module trouvé.

### Le code est dans un sous-dossier : c'est géré

Beaucoup de dépôts rangent les sources dans un dossier portant le numéro de
version — `github.com/<owner>/odoo/tree/18.0/18.0` signifie *branche `18.0`,
dossier `18.0`*. Le build **détecte tout seul** la racine d'Odoo (le dossier
contenant `odoo-bin`) et celle d'Enterprise (le dossier contenant des
`__manifest__.py`), jusqu'à 4 niveaux de profondeur. Rien à configurer.

Si la détection échoue malgré tout :

```bash
./base-images/build.sh 19.0 enterprise \
    --odoo-subdir 19.0 --enterprise-subdir 19.0
```

### Sources téléchargées depuis odoo.com (sans `odoo-bin`)

Si vous avez déposé dans votre dépôt l'archive **Sources** d'odoo.com plutôt
qu'un clone de `odoo/odoo`, la structure diffère :

| | clone git `odoo/odoo` | archive Sources odoo.com |
|---|---|---|
| lanceur | `odoo-bin` à la racine | **absent** — le script est `setup/odoo` |
| packaging | pas de `setup.py` utile | `setup.py`, `PKG-INFO` |
| paquet python | `odoo/` | `odoo/` |
| module `base` | `odoo/addons/base` | `odoo/addons/base` |
| autres modules | `addons/` | `addons/` |

`odoo-bin absent` **n'est donc pas une erreur** dans ce cas. Le build le gère :
il reprend `setup/odoo` s'il existe, sinon il génère un lanceur équivalent

```python
#!/usr/bin/env python3
import odoo
if __name__ == "__main__":
    odoo.cli.main()
```

et l'image expose toujours `/opt/odoo/odoo-bin`. Le vrai repère de validité
n'est pas `odoo-bin` mais **`odoo/release.py`** et la présence du module `base` :
c'est ce que le build vérifie.

> **Enterprise n'a jamais d'`odoo-bin`** : c'est un jeu de modules, pas un
> serveur. La sonde n'en cherche pas dans ce dépôt — elle y cherche des
> `__manifest__.py`.

### La branche ne porte pas le nom de la version

Si votre dépôt core n'a pas de branche `19.0` mais que vous voulez quand même
construire une image `19.0` :

```bash
./base-images/build.sh 19.0 enterprise \
    --odoo-branch 18.0 --enterprise-branch 19.0
```

> **Attention à l'orthographe du dépôt.** `entreprise` (français) et
> `enterprise` (anglais) sont deux noms différents pour GitHub. Renseignez le nom
> exact dans `ENTERPRISE_REPO` de `base.env`.

Quelle que soit la structure d'origine, l'image finale est toujours normalisée :
`/opt/odoo` (avec `odoo-bin`), `/opt/odoo-enterprise` (les modules).

### Un seul dépôt pour le core ET Enterprise

C'est possible, mais la détection automatique ne peut pas deviner quel
sous-dossier porte Enterprise (elle tomberait sur les addons du core). Indiquez-le :

```bash
./base-images/build.sh 19.0 enterprise --enterprise-subdir enterprise-19
```

Sans cette option, le build s'arrête avec un message explicite plutôt que de
produire une image incohérente.

### Dépôts publics

Si vos dépôts sont publics, laissez `GITHUB_TOKEN` vide : le clone se fait en
anonyme. Le token reste nécessaire pour publier sur `ghcr.io`.

---

## 4. Construire

```bash
./base-images/build.sh 19.0 enterprise            # build local (test)
./base-images/build.sh 19.0 enterprise --push     # build + publication
./base-images/build.sh 18.0 community --push
./base-images/build.sh all --push                 # 17.0, 18.0, 19.0
```

Premier build : 10 à 20 minutes (compilation des dépendances Python).
Builds suivants : 2 à 5 minutes grâce au cache.

Le build échoue volontairement si Odoo ne s'importe pas ou si les addons du core
sont introuvables — une image cassée ne sort jamais du build.

### Ce que contient l'image

| | |
|---|---|
| `/opt/odoo` | votre dépôt core (branche = version) |
| `/opt/odoo-enterprise` | votre dépôt enterprise (vide en édition community) |
| `/opt/venv` | dépendances Python (`requirements.txt` d'Odoo + `extra-requirements.txt`) |
| `/opt/SOURCES.txt` | dépôts, branches, **sous-dossiers détectés** et **commits exacts** embarqués |
| `wkhtmltopdf` | build « patched Qt », indispensable aux rapports PDF |
| `rtlcss` | rendu des langues RTL (arabe) |

```bash
docker run --rm --entrypoint cat ghcr.io/odooafia/odoo:19.0-enterprise /opt/SOURCES.txt
```

Vous saurez toujours quel commit tourne chez un client donné.

### Le token ne finit jamais dans l'image

Il est injecté via `--mount=type=secret` (BuildKit) dans un étage jetable, et les
dossiers `.git` sont supprimés avant la copie vers l'image finale. À vérifier
après un build :

```bash
docker history --no-trunc ghcr.io/odooafia/odoo:19.0-enterprise | grep -i token   # rien
docker run --rm ghcr.io/odooafia/odoo:19.0-enterprise \
       sh -c 'ls -a /opt/odoo | grep "^.git$"'                                     # rien
```

---

## 5. Les deux tokens GitHub — et comment les créer

C'est la source d'erreur numéro un. **Deux usages, deux tokens de types
différents**, qui ne sont pas interchangeables :

| Usage | Type de token | Droits | Variable |
|---|---|---|---|
| `git clone` de vos sources | **fine-grained** | `Contents: Read-only` sur chaque dépôt | `GITHUB_TOKEN` |
| `docker push` vers ghcr.io | **classic** | `write:packages`, `read:packages` | `REGISTRY_TOKEN` |

> **ghcr.io n'accepte pas les tokens fine-grained.** Un fine-grained est rejeté au
> push avec `denied: permission_denied: The token provided does not match
> expected scopes`. Ce n'est pas un problème de scope à ajuster : il faut un PAT
> *classic*.

### A. Token de publication (obligatoire pour `--push`)

1. https://github.com/settings/tokens → **Generate new token (classic)**
2. *Note* : `ghcr-odoo-stack` · *Expiration* : 90 jours ou plus
3. Cochez uniquement :
   * ✅ `write:packages`
   * ✅ `read:packages`
   *(`repo` n'est nécessaire que si vous voulez aussi lire des dépôts privés
   avec ce même token)*
4. **Generate token**, copiez la valeur `ghp_…` (elle ne sera plus affichée)
5. Dans `base-images/base.env` :

```bash
REGISTRY_USER=ndiogoudiop01
REGISTRY_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

Le script se connecte au registre **avant** de construire : une erreur de droits
apparaît en 5 secondes, pas après 15 minutes de build.

### B. Token de lecture des sources privées

Nécessaire seulement si vos dépôts Odoo sont **privés** (laissez `GITHUB_TOKEN`
vide s'ils sont publics — un token sans droits ferait échouer un dépôt public) :

1. https://github.com/settings/tokens?type=beta → **Generate new token**
2. *Repository access* → **Only select repositories** → cochez
   `ndiogoudiop01/odoo` **et** `ndiogoudiop01/entreprise`
3. *Repository permissions* → **Contents** → **Read-only**
   *(laissez tout le reste sur « No access »)*
4. **Generate token**, copiez `github_pat_…`
5. Dans `base.env` : `GITHUB_TOKEN=github_pat_…`

> Un dépôt oublié dans « Only select repositories » donne
> `403 — Write access to repository not granted` sur ce dépôt précis, même si
> les autres passent.

### C. Publier et autoriser le VPS

```bash
./base-images/build.sh 18.0 community --push
```

Sur GHCR, un package publié est **privé par défaut**. Pour que le VPS puisse le
tirer, deux options :

**Option 1 — authentifier le serveur** (recommandé pour du code Enterprise)

```bash
# sur le VPS
echo ghp_xxxx | docker login ghcr.io -u ndiogoudiop01 --password-stdin
```

Un `read:packages` suffit côté serveur : créez un second PAT classic avec ce
seul scope plutôt que d'y copier celui qui sait publier.

Coolify et Dokploy réutilisent le `~/.docker/config.json` du serveur — un seul
login couvre tous les clients. Vous pouvez aussi déclarer le registre dans leur
interface (*Keys & Tokens → Docker Registries* sur Coolify, *Registry* sur
Dokploy).

**Option 2 — rendre le package public** (acceptable pour du Community pur)

GitHub → votre profil → **Packages** → `odoo` → *Package settings* →
**Change visibility** → Public. Plus aucun login nécessaire sur le VPS.

> Ne rendez **jamais** public un package contenant du code Enterprise : votre
> licence Odoo ne le permet pas.

### D. Se passer complètement de registre

Si vous n'avez qu'un seul VPS, construisez l'image **sur** le VPS et sautez le
push :

```bash
./base-images/build.sh 18.0 community        # sans --push : image locale
```

L'image reste dans le démon Docker du serveur, et les clients la trouvent en
`FROM`. Vous perdez le partage entre plusieurs serveurs et le retour arrière par
tag daté ; c'est le compromis raisonnable pour un parc mono-serveur.

---

## 6. Ajouter une dépendance Python à toutes les images

`base-images/extra-requirements.txt` est installé dans **toutes** les images de
base. Ce qui ne concerne qu'un seul client reste dans
`clients/<slug>/requirements.txt`.

```bash
echo "openupgradelib==3.7.0" >> base-images/extra-requirements.txt
./base-images/build.sh all --push
```

---

## 7. Mettre à jour un client vers une nouvelle image

```bash
# 1. reconstruire l'image de base après un push sur votre branche 19.0
./base-images/build.sh 19.0 enterprise --push

# 2. côté client
cd clients/lodge
make backup
make pull-base        # docker pull de l'image de base
make rebuild          # reconstruit la couche client et redémarre
make upgrade M=all    # si des modules ont changé de version
```

Sur Coolify / Dokploy : **Redeploy** avec l'option *Pull latest images* suffit.

Les images sont aussi taguées avec la date (`19.0-enterprise-20260908`) : pour
revenir en arrière, pointez `ODOO_BASE_IMAGE` sur un tag daté antérieur et
redéployez.

---

## 8. Automatiser (GitHub Actions)

`base-images/github-actions.example.yml` reconstruit les trois versions chaque
lundi à 3h UTC et publie sur GHCR. Copiez-le en
`.github/workflows/base-images.yml` dans ce dépôt et ajoutez le secret
`ODOO_SOURCES_TOKEN`.

---

## 9. Problèmes fréquents

| Symptôme | Cause | Solution |
|---|---|---|
| `clone impossible` sans détail | ancienne version du script | mettre à jour : la sortie de git et la liste des branches sont désormais affichées |
| `Repository not found` | nom de dépôt erroné (`entreprise` vs `enterprise`), ou PAT sans accès | corriger `ENTERPRISE_REPO` dans `base.env` ; vérifier *Repository access* du token fine-grained |
| `403 — Write access to repository not granted` | un token est présenté alors qu'il n'a aucun droit sur ce dépôt | dépôt public → videz `GITHUB_TOKEN` (ou `--anonymous`) ; dépôt privé → ajoutez-le au PAT avec *Contents: Read-only* |
| `Remote branch 19.0 not found` | la branche n'existe pas dans ce dépôt | `--probe` liste les branches ; utiliser `--odoo-branch` / `--enterprise-branch` |
| `failed to compute cache key: "/src/odoo/requirements.txt": not found` | ancienne version du Dockerfile | mettre à jour : le build normalise désormais l'arborescence et produit `/src/requirements.txt` |
| `racine Odoo introuvable (aucun odoo-bin)` | le code est dans un sous-dossier, ou le dépôt n'est pas un fork d'Odoo | `--probe` puis `--odoo-subdir <chemin>` |
| `aucun module Enterprise trouvé` | modules dans un sous-dossier | `--probe` puis `--enterprise-subdir <chemin>` |
| `requirements.txt introuvable` | fork partiel du core | ajouter un `requirements.txt` à la racine du fork (copiable depuis `odoo/odoo` à la même version) |
| `odoo-bin absent` dans la sonde | archive Sources d'odoo.com (normal) ou dépôt Enterprise (normal) | rien à faire : le build génère le lanceur |
| `module « base » introuvable` | source du core incomplète | vérifier la présence de `odoo/addons/base` dans le dépôt |
| `clone échoué` après « branche présente » | disque plein, Git LFS, ou coupure réseau | la sonde affiche l'erreur git et l'espace disque ; `docker system prune -af` libère souvent le nécessaire |
| `destination path … already exists and is not an empty directory` | `ODOO_REPO` et `ENTERPRISE_REPO` pointent le même dépôt | la sonde affiche la configuration lue : corrigez `base.env`, ou passez `--enterprise-subdir` si le dépôt contient réellement les deux |
| `denied: permission_denied: The token provided does not match expected scopes` | token **fine-grained** utilisé pour ghcr.io | créez un PAT **classic** avec `write:packages` et mettez-le dans `REGISTRY_TOKEN` (§5.A) |
| `unauthorized` au push | `REGISTRY_USER` ≠ propriétaire du token, ou namespace en majuscules | aligner `REGISTRY_USER` ; `REGISTRY` doit être en minuscules |
| Le VPS ne peut pas tirer l'image | serveur non authentifié au registre | `docker login ghcr.io` sur le VPS |
| Build très long | `GIT_DEPTH=0` | repasser à `GIT_DEPTH=1` |
| `wkhtmltopdf: not found` sur ARM | pas de paquet pour cette architecture | construire avec `--platform linux/amd64`, ou adapter la version dans le Dockerfile |
