# Déployer Odoo **Enterprise** sur Coolify depuis vos dépôts GitHub

Runbook complet, de zéro à l'instance en HTTPS. Écrit pour le cas courant :

* les sources viennent de **vos** dépôts GitHub (pas d'`odoo/odoo`) ;
* elles proviennent des archives **Sources** d'odoo.com → **pas d'`odoo-bin`** ;
* le code est rangé dans un **sous-dossier** portant le numéro de version ;
* **un seul VPS** → on se passe complètement de registre d'images.

Durée : ~30 min la première fois, dont 15 de build.

---

## 0. Ce que doivent contenir vos deux dépôts

| Dépôt | Contenu attendu | Repère de validité |
|---|---|---|
| `<owner>/odoo` | sources **Community** de la version cible | `odoo/release.py` + `odoo/addons/base/` |
| `<owner>/entreprise` | modules **Enterprise** de la MÊME version | des dossiers avec `__manifest__.py` |

Peu importe que le code soit à la racine ou dans un sous-dossier (`19.0/`, `src/`…) :
la racine réelle est détectée automatiquement.

> **Les deux doivent être à la même version.** Un core 18.0 avec des addons
> Enterprise 19.0 ne démarrera pas : Odoo vérifie la version de chaque module.

### `odoo-bin` absent : normal, et déjà traité

L'archive Sources d'odoo.com est produite par `setup.py sdist` — le lanceur y est
`setup/odoo`, pas `odoo-bin`. Le build le gère seul :

1. si `odoo-bin` existe → utilisé tel quel ;
2. sinon si `setup/odoo` existe → repris comme lanceur ;
3. sinon → un lanceur équivalent est généré :

```python
#!/usr/bin/env python3
import odoo
if __name__ == "__main__":
    odoo.cli.main()
```

L'image expose toujours `/opt/odoo/odoo-bin`. Et **Enterprise n'a jamais
d'`odoo-bin`** : c'est un jeu de modules, pas un serveur — on n'en cherche pas.

---

## 1. Vérifier les dépôts (2 min, avant tout build)

```bash
cd /opt/odoo-stack
./base-images/build.sh 19.0          # crée base-images/base.env, puis s'arrête
```

Éditez `base-images/base.env` :

```bash
GITHUB_OWNER=ndiogoudiop01
ODOO_REPO=odoo                  # nom du dépôt SEUL, pas l'URL
ENTERPRISE_REPO=entreprise      # orthographe exacte (entreprise ≠ enterprise)
REGISTRY=ghcr.io/ndiogoudiop01  # non utilisé en mode local, mais requis
IMAGE_NAME=odoo
GITHUB_TOKEN=                   # VIDE si les dépôts sont publics
REGISTRY_TOKEN=                 # vide : on ne publie pas
GIT_DEPTH=1
```

Puis la sonde :

```bash
./base-images/build.sh 19.0 enterprise --probe
```

Elle doit afficher, pour chaque dépôt : joignable, branche présente, et où se
trouve le code. Trois messages attendus et **normaux** :

* `archive « Sources » détectée (pas d'odoo-bin, c'est normal)` ;
* `racine Odoo : « 19.0 »` ;
* `premier module -> 19.0/account_accountant` côté Enterprise.

Si la branche n'a pas le nom de la version :

```bash
./base-images/build.sh 19.0 enterprise --probe \
    --odoo-branch main --enterprise-branch 19.0
```

---

## 2. Construire l'image de base — sans registre

C'est ici qu'on évite tout le sujet des tokens GHCR : **on ne publie pas**.

```bash
./base-images/build.sh 19.0 enterprise --local
```

15 à 20 minutes au premier build (compilation des dépendances Python).
Le build échoue volontairement si Odoo ne s'importe pas ou si le module `base`
est absent — une image cassée ne sort jamais du build.

À la fin :

```
Image construite LOCALEMENT sur ce serveur (aucun registre) :
    ghcr.io/ndiogoudiop01/odoo:19.0-enterprise
```

Le nom garde la forme d'une référence de registre, mais l'image **n'y est pas** :
elle vit dans le démon Docker du VPS. Coolify utilise ce même démon, donc il la
trouvera en `FROM`. Vérifiez :

```bash
docker images | grep odoo
docker run --rm --entrypoint cat ghcr.io/ndiogoudiop01/odoo:19.0-enterprise /opt/SOURCES.txt
```

`SOURCES.txt` vous donne les dépôts, branches, sous-dossiers et **commits exacts**
embarqués : c'est votre traçabilité en cas de support.

> Passez à `--push` seulement le jour où vous aurez un second serveur.
> Il faudra alors un PAT **classic** avec `write:packages` (voir
> `docs/BASE-IMAGES.md` §5) — les tokens fine-grained sont refusés par ghcr.io.

---

## 3. Créer le client

```bash
./new-client.sh --name "DGlow" --slug dglow \
                --version 19.0 --edition enterprise \
                --domain erp.dglow.sn --db dglow_prod \
                --platform coolify --workers 4
```

L'assistant génère `clients/dglow/` — dépôt git initialisé, secrets aléatoires,
variables Traefik de Coolify, et `DEPLOY-ENV.txt` à coller dans l'interface.

Vérifiez que l'image de base pointée est bien celle construite :

```bash
grep ODOO_BASE_IMAGE clients/dglow/.env
# ODOO_BASE_IMAGE=ghcr.io/ndiogoudiop01/odoo:19.0-enterprise
```

Test en local avant de pousser (facultatif mais recommandé) :

```bash
cd clients/dglow && make dev && make logs
```

---

## 4. Pousser le dépôt du client

```bash
cd /opt/odoo-stack/clients/dglow
git remote add origin git@github.com:ndiogoudiop01/odoo-dglow.git
git push -u origin main
```

Le `.env` et `DEPLOY-ENV.txt` ne partent pas — c'est voulu, ils contiennent les
mots de passe.

> `Repository not found` sur SSH = la clé du VPS n'est pas enregistrée sur le
> compte, ou le nom du dépôt est erroné. `ssh -T git@github.com` doit répondre
> `Hi ndiogoudiop01!`.

---

## 5. Créer la ressource Coolify

**Project → New Resource → Docker Compose**

| Champ | Valeur |
|---|---|
| Source | `ndiogoudiop01/odoo-dglow` |
| Branch | `main` |
| Base Directory | `/` |
| Docker Compose Location | `/docker-compose.yml` |

Coolify détecte les 4 services : `db`, `odoo`, `proxy`, `backup`.

### Variables d'environnement

**Environment Variables → Developer view** → collez `clients/dglow/DEPLOY-ENV.txt`.

Contrôlez ces lignes, ce sont celles qui cassent le déploiement quand elles
manquent :

```
CLIENT_SLUG=dglow                                   # nomme l'image ET les routeurs Traefik
ODOO_BASE_IMAGE=ghcr.io/ndiogoudiop01/odoo:19.0-enterprise
DOMAIN=erp.dglow.sn
TRAEFIK_NETWORK=coolify
TRAEFIK_ENTRYPOINT_HTTP=http
TRAEFIK_ENTRYPOINT_HTTPS=https
TRAEFIK_CERTRESOLVER=letsencrypt
```

Marquez secrets : `DB_PASSWORD`, `ODOO_MASTER_PASSWORD`, `BACKUP_ENC_PASSPHRASE`.

**Ne collez pas** `HTTP_PORT`, `PG_PORT`, `PROXY_PORT`, `DEBUGPY_PORT` : réservés
au développement local, ils publieraient des ports sur le VPS.

### Domaine

Ce compose porte **ses propres labels Traefik**, construits depuis `DOMAIN`.
Ne saisissez **rien** dans l'onglet *Domains* de Coolify : vous créeriez un
second routeur en conflit.

DNS :

```
Type  Nom            Valeur
A     erp.dglow.sn   <IP du VPS>
```

Cloudflare : laissez en **DNS only** (nuage gris) le temps du certificat.

### Déployer

**Deploy**. Ne cochez **pas** « pull latest images » : l'image de base n'existe
dans aucun registre, Coolify échouerait avec `pull access denied`.

Le build ne dure que ~1 minute — l'image de base contient déjà Odoo, seule la
couche client (vos addons + config) est construite.

---

## 6. Créer la base et vérifier

**Logs → odoo**, démarrage correct quand apparaît :

```
odoo.service.server: HTTP service (werkzeug) running on 0.0.0.0:8069
```

Ouvrez `https://erp.dglow.sn/web/database/manager`, créez la base avec le **nom
exact** de `DB_NAME` (sinon `DB_FILTER` la masquera) et le master password de
`DEPLOY-ENV.txt`.

| Test | Attendu |
|---|---|
| `https://erp.dglow.sn` | page de connexion, cadenas vert |
| `http://erp.dglow.sn` | redirection 301 vers HTTPS |
| Apps → chercher « Comptabilité » | les modules **Enterprise** apparaissent |
| Chat interne / notifications | temps réel (websocket via nginx) |
| `/web/database/manager` après création | inaccessible (`LIST_DB=False`) |
| Logs → backup | « sauvegarde quotidienne planifiée à 2h00 » |

**Le test qui compte pour Enterprise** : dans Apps, retirez le filtre par défaut
et cherchez `account_accountant` ou `helpdesk`. S'ils sont absents, l'`addons_path`
n'inclut pas Enterprise :

```bash
# terminal de la ressource Coolify
cat /etc/odoo/odoo.conf | grep addons_path
ls /opt/odoo-enterprise | head
```

`addons_path` doit commencer par `/opt/odoo-enterprise`.

---

## 7. Le quotidien ensuite

```bash
git push origin main          # Coolify rebuild automatiquement
make upgrade M=mon_module     # après un changement de vue ou de modèle
make backup                   # sauvegarde immédiate
```

Nouvelle version du core (vous avez mis à jour vos dépôts) :

```bash
cd /opt/odoo-stack
./base-images/build.sh 19.0 enterprise --local     # reconstruit l'image
cd clients/dglow && make backup && make rebuild && make upgrade M=all
```

---

## 8. Erreurs déjà rencontrées, et leur cause

| Message | Cause réelle |
|---|---|
| `odoo-bin absent` dans la sonde | archive Sources d'odoo.com — normal, lanceur généré |
| `403 Write access to repository not granted` | un token est présenté sur un dépôt **public** → videz `GITHUB_TOKEN` |
| `denied: The token provided does not match expected scopes` | PAT fine-grained sur ghcr.io → il faut un PAT **classic**, ou restez en `--local` |
| `pull access denied for <slug>-odoo` | `docker compose up` sans `--build`, ou « pull latest images » coché |
| `pull access denied for odoo-odoo` | `CLIENT_SLUG` absent des variables : l'image et les routeurs Traefik prennent le nom par défaut |
| `destination path already exists` | `ODOO_REPO` et `ENTERPRISE_REPO` pointent le même dépôt |
| `Repository not found` sur `git push` | clé SSH du VPS non enregistrée, ou nom de dépôt erroné |
