# Déployer un client sur Dokploy

Procédure complète, du dépôt vide au site en HTTPS. 15 minutes la première fois,
5 minutes ensuite.

---

## 0. Préparer le serveur (une seule fois)

```bash
# Le réseau Traefik de Dokploy doit exister (il est créé à l'installation)
docker network ls | grep dokploy-network

# Autoriser le serveur à tirer vos images de base privées
docker login ghcr.io -u <votre-compte-github>     # mot de passe = le PAT
```

Vérifiez aussi dans Dokploy → **Settings → Server** : ports 80/443 ouverts, et au
moins 20 Go libres par client Odoo.

> Astuce : 2 Go de swap évitent les OOM lors d'un `make upgrade M=all`.

---

## 1. Pousser le dépôt du client

```bash
cd clients/lodge
git remote add origin git@github.com:votre-org/odoo-lodge.git
git push -u origin main
```

Dépôt **privé**. Le `.env` et `DEPLOY-ENV.txt` ne partent pas : c'est voulu.

Pour que Dokploy puisse cloner un dépôt privé : Dokploy → **Settings → Git** →
connecter le compte GitHub (GitHub App), ou ajouter une clé SSH de déploiement.
Aucun submodule à cloner — le code Odoo est déjà dans l'image de base.

---

## 2. Créer l'application

**Project → Create Service → Compose**

| Champ | Valeur |
|---|---|
| Source Type | GitHub (ou Git provider) |
| Repository | `votre-org/odoo-lodge` |
| Branch | `main` |
| Compose Path | `./docker-compose.yml` |
| Compose Type | `docker-compose` |

---

## 3. Variables d'environnement

Onglet **Environment** → collez le contenu de `clients/lodge/DEPLOY-ENV.txt`.

Vérifiez que ces trois lignes correspondent bien à Dokploy :

```
TRAEFIK_NETWORK=dokploy-network
TRAEFIK_ENTRYPOINT_HTTP=web
TRAEFIK_ENTRYPOINT_HTTPS=websecure
TRAEFIK_CERTRESOLVER=letsencrypt
```

> **Ne collez pas** `HTTP_PORT`, `PG_PORT`, `PROXY_PORT`, `DEBUGPY_PORT` : ils ne
> servent qu'au développement local et publieraient des ports sur le VPS.

---

## 4. Domaine et SSL

Ce compose porte **ses propres labels Traefik**, générés à partir de `DOMAIN`.
Vous n'avez donc **rien à saisir dans l'onglet Domains** de Dokploy — et il ne
faut pas le faire, sous peine de créer un second routeur en conflit.

Il suffit que `DOMAIN=erp.lodge.sn` soit dans les variables d'environnement.

Côté DNS (LWS, OVH, Cloudflare…) :

```
Type  Nom             Valeur
A     erp.lodge.sn    <IP publique du VPS>
```

Avec Cloudflare, laissez l'enregistrement en **DNS only** (nuage gris) le temps
de l'émission du certificat.

> Si vous préférez laisser Dokploy gérer le domaine depuis son UI : saisissez-le
> sur le service `proxy`, port `80`, et retirez le bloc `labels:` du service
> `proxy` dans `docker-compose.yml`. Un seul des deux mécanismes à la fois.

---

## 5. Premier déploiement

**Deploy**. Le build ne prend que ~1 minute : l'image de base contient déjà Odoo,
seule la couche client est construite.

Suivez **Logs → odoo** ; le démarrage est correct quand vous voyez :

```
odoo.service.server: HTTP service (werkzeug) running on 0.0.0.0:8069
```

Ouvrez ensuite `https://erp.lodge.sn/web/database/manager`, créez la base avec le
**nom exact** de `DB_NAME` (sinon `DB_FILTER` la masquera) et le master password
issu de `DEPLOY-ENV.txt`.

Une fois la base créée, `LIST_DB=False` rend le gestionnaire inaccessible :
c'est le comportement attendu.

---

## 6. Déploiements suivants

```bash
git add -A && git commit -m "feat(pos): …" && git push
```

Dokploy rebuild et redémarre (activez **Auto Deploy** pour le faire au push).
Après un changement de modèle ou de vue, mettez le module à jour depuis le
terminal de l'application :

```bash
odoo --config=/etc/odoo/odoo.conf -d lodge_prod -u lodge_pos --stop-after-init --no-http
```

Pour récupérer une nouvelle image de base : **Redeploy** avec l'option de pull des
images, ou en SSH `make pull-base && make rebuild`.

---

## 7. Vérifications post-déploiement

| Test | Attendu |
|---|---|
| `https://erp.lodge.sn` | page de connexion, cadenas vert |
| `http://erp.lodge.sn` | redirection 301 vers HTTPS |
| Chat interne / notifications | temps réel → le websocket passe bien par nginx |
| `/web/database/manager` | inaccessible (`LIST_DB=False`) |
| **Logs → backup** | « sauvegarde quotidienne planifiée à 2h00 » |
| Import d'un fichier de 50 Mo | passe (limite nginx à 512 Mo) |

---

## 8. Problèmes fréquents

| Symptôme | Cause | Solution |
|---|---|---|
| `network dokploy-network not found` | nom du réseau erroné | `docker network ls`, corriger `TRAEFIK_NETWORK` |
| 404 de Traefik | le conteneur `proxy` n'est pas sur le réseau Traefik | vérifier `traefik.docker.network` et `TRAEFIK_NETWORK` |
| Certificat non émis | entrypoint ou certresolver erroné | comparer avec la config Traefik de Dokploy (`websecure` / `letsencrypt`) |
| Deux routeurs en conflit | domaine saisi **à la fois** dans l'UI et dans les labels | n'en garder qu'un |
| `pull access denied` sur l'image de base | serveur non authentifié à ghcr.io | `docker login ghcr.io` sur le VPS |
| `502 Bad Gateway` pendant 2-3 min | Odoo démarre | attendre ; `start_period` du healthcheck = 120 s |
| Notifications figées | websocket non routé | le domaine doit viser le service **`proxy`**, jamais `odoo` |
| `FATAL: password authentication failed` | `DB_PASSWORD` changé après création du volume | restaurer l'ancien, ou recréer le volume et restaurer une sauvegarde |

---

## 9. Différences Dokploy / Coolify

Le `docker-compose.yml` est **identique** ; seules trois variables changent.

| | Coolify | Dokploy | Docker nu |
|---|---|---|---|
| `TRAEFIK_NETWORK` | `coolify` | `dokploy-network` | `traefik` |
| `TRAEFIK_ENTRYPOINT_HTTP` | `http` | `web` | `web` |
| `TRAEFIK_ENTRYPOINT_HTTPS` | `https` | `websecure` | `websecure` |

`./new-client.sh --platform coolify|dokploy|docker` les renseigne automatiquement.
Migrer un client d'une plateforme à l'autre revient donc à changer trois lignes
d'environnement et à redéployer.
