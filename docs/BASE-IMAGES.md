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

## 1. Prérequis GitHub

Un **fine-grained personal access token** avec, sur les deux dépôts :

```
Repository access : <owner>/odoo  et  <owner>/enterprise
Permissions       : Contents → Read-only
```

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained.

> Un token *classic* avec le scope `repo` fonctionne aussi, mais il donne accès à
> tous vos dépôts : préférez le fine-grained.

---

## 2. Configuration (une fois)

```bash
./base-images/build.sh 19.0          # crée base-images/base.env puis s'arrête
```

Éditez `base-images/base.env` :

```bash
GITHUB_OWNER=odooAfia          # compte qui héberge vos dépôts
ODOO_REPO=odoo                 # nom du dépôt core
ENTERPRISE_REPO=enterprise     # nom du dépôt enterprise
REGISTRY=ghcr.io/odooafia      # destination des images
IMAGE_NAME=odoo
GITHUB_TOKEN=github_pat_...    # le token de l'étape 1
GIT_DEPTH=1                    # clone superficiel : rapide et léger
```

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

## 5. Publier et autoriser le VPS

```bash
# Poste de développement — publication
docker login ghcr.io -u odooAfia            # mot de passe = le PAT
./base-images/build.sh 19.0 enterprise --push

# VPS — autorisation de tirer l'image
docker login ghcr.io -u odooAfia
```

Coolify et Dokploy réutilisent le `~/.docker/config.json` du serveur : un seul
`docker login` suffit pour tous les clients. Vous pouvez aussi déclarer un
**Registry** dans l'UI de la plateforme.

Sur GHCR, une image publiée est **privée par défaut**. Pour permettre à plusieurs
serveurs de la tirer sans partager votre PAT : GitHub → Packages → le package →
*Manage Actions access* / *Package settings*.

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
| `Remote branch 19.0 not found` | la branche n'existe pas dans ce dépôt | `--probe` liste les branches ; utiliser `--odoo-branch` / `--enterprise-branch` |
| `failed to compute cache key: "/src/odoo/requirements.txt": not found` | ancienne version du Dockerfile | mettre à jour : le build normalise désormais l'arborescence et produit `/src/requirements.txt` |
| `racine Odoo introuvable (aucun odoo-bin)` | le code est dans un sous-dossier, ou le dépôt n'est pas un fork d'Odoo | `--probe` puis `--odoo-subdir <chemin>` |
| `aucun module Enterprise trouvé` | modules dans un sous-dossier | `--probe` puis `--enterprise-subdir <chemin>` |
| `requirements.txt introuvable` | fork partiel du core | ajouter un `requirements.txt` à la racine du fork (copiable depuis `odoo/odoo` à la même version) |
| `odoo-bin absent` dans la sonde | archive Sources d'odoo.com (normal) ou dépôt Enterprise (normal) | rien à faire : le build génère le lanceur |
| `module « base » introuvable` | source du core incomplète | vérifier la présence de `odoo/addons/base` dans le dépôt |
| `clone échoué` après « branche présente » | disque plein, Git LFS, ou coupure réseau | la sonde affiche l'erreur git et l'espace disque ; `docker system prune -af` libère souvent le nécessaire |
| `denied: permission_denied` au push | pas connecté à ghcr.io, ou PAT sans `write:packages` | `docker login ghcr.io` avec un PAT qui a `write:packages` |
| Le VPS ne peut pas tirer l'image | serveur non authentifié au registre | `docker login ghcr.io` sur le VPS |
| Build très long | `GIT_DEPTH=0` | repasser à `GIT_DEPTH=1` |
| `wkhtmltopdf: not found` sur ARM | pas de paquet pour cette architecture | construire avec `--platform linux/amd64`, ou adapter la version dans le Dockerfile |
