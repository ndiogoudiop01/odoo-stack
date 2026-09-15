# Déployer un client sur Coolify

Même dépôt, même `docker-compose.yml` que sur Dokploy : seules trois variables
d'environnement changent. Si vous connaissez déjà `docs/DOKPLOY.md`, seules les
sections 2 et 4 ci-dessous diffèrent.

---

## 0. Préparer le serveur (une seule fois)

```bash
# Le réseau Traefik de Coolify doit exister (créé à l'installation)
docker network ls | grep coolify

# Autoriser le serveur à tirer vos images de base privées
docker login ghcr.io -u <votre-compte-github>     # mot de passe = le PAT
```

Coolify → **Servers → votre serveur → Proxy** : Traefik démarré, ports 80/443
ouverts. Prévoyez 20 Go libres par client Odoo et 2 Go de swap.

Vous pouvez aussi déclarer le registre dans **Keys & Tokens → Docker Registries**
plutôt que par `docker login`.

---

## 1. Pousser le dépôt du client

```bash
cd clients/acme
git remote add origin git@github.com:votre-org/odoo-acme.git
git push -u origin main
```

Dépôt **privé**. Le `.env` et `DEPLOY-ENV.txt` ne partent pas : c'est voulu.
Coolify → **Sources** → connecter GitHub (GitHub App ou Deploy key).

Aucun submodule Odoo à cloner : le code Enterprise vit dans l'image de base
(voir `docs/BASE-IMAGES.md`). Seuls les éventuels dépôts OCA sont des submodules.

---

## 2. Créer la ressource

**Project → New Resource → Docker Compose**

| Champ | Valeur |
|---|---|
| Source | votre dépôt GitHub privé |
| Branch | `main` |
| Base Directory | `/` |
| Docker Compose Location | `/docker-compose.yml` |

Coolify détecte les 4 services : `db`, `odoo`, `proxy`, `backup`.

---

## 3. Variables d'environnement

**Environment Variables → Developer view** : collez le contenu de
`clients/acme/DEPLOY-ENV.txt`.

Vérifiez les valeurs propres à Coolify :

```
TRAEFIK_NETWORK=coolify
TRAEFIK_ENTRYPOINT_HTTP=http
TRAEFIK_ENTRYPOINT_HTTPS=https
TRAEFIK_CERTRESOLVER=letsencrypt
```

Marquez **Is Secret** sur `DB_PASSWORD`, `ODOO_MASTER_PASSWORD`,
`BACKUP_ENC_PASSPHRASE`.

> **Ne collez pas** `HTTP_PORT`, `PG_PORT`, `PROXY_PORT`, `DEBUGPY_PORT` : ils ne
> servent qu'au développement local et publieraient des ports sur le VPS.

---

## 4. Domaine et SSL

Ce compose porte **ses propres labels Traefik**, construits à partir de `DOMAIN`.
Il ne faut donc **pas** saisir de domaine dans l'onglet *Domains* de Coolify :
cela créerait un second routeur en conflit avec le nôtre.

Il suffit que `DOMAIN=erp.acme.sn` figure dans les variables d'environnement.

DNS :

```
Type  Nom            Valeur
A     erp.acme.sn    <IP publique du VPS>
```

Avec Cloudflare, restez en **DNS only** (nuage gris) le temps de l'émission du
certificat.

> **Variante « tout Coolify »** — si vous préférez laisser l'UI gérer le routage :
> retirez le bloc `labels:` du service `proxy`, ajoutez
> `- SERVICE_FQDN_PROXY_80` dans son `environment:`, et saisissez le domaine dans
> l'onglet Domains. Un seul des deux mécanismes à la fois.

---

## 5. Premier déploiement

**Deploy**. Le build dure ~1 minute (l'image de base contient déjà Odoo).

**Logs → odoo**, démarrage correct quand apparaît :

```
odoo.service.server: HTTP service (werkzeug) running on 0.0.0.0:8069
```

Puis `https://erp.acme.sn/web/database/manager` : créez la base avec le **nom
exact** de `DB_NAME` et le master password de `DEPLOY-ENV.txt`. Ensuite,
`LIST_DB=False` rend ce gestionnaire inaccessible — c'est voulu.

---

## 6. Déploiements suivants

```bash
git add -A && git commit -m "feat(ventes): …" && git push
```

Coolify rebuild et redémarre. Après un changement de modèle ou de vue, depuis le
**Terminal** de la ressource :

```bash
odoo --config=/etc/odoo/odoo.conf -d acme_prod -u acme_ventes --stop-after-init --no-http
```

Nouvelle image de base disponible : **Redeploy** en cochant le pull des images,
ou en SSH `make pull-base && make rebuild`.

### Rolling update

Coolify le propose, mais Odoo ne supporte pas deux versions de schéma en
parallèle. Pour une mise à jour qui touche la base, préférez une courte fenêtre
d'arrêt (`stop → upgrade → start`).

---

## 7. Vérifications post-déploiement

| Test | Attendu |
|---|---|
| `https://erp.acme.sn` | page de connexion, cadenas vert |
| `http://erp.acme.sn` | redirection 301 vers HTTPS |
| Chat interne / notifications | temps réel → websocket OK |
| `/web/database/manager` | inaccessible |
| **Logs → backup** | « sauvegarde quotidienne planifiée à 2h00 » |
| Import d'un fichier de 50 Mo | passe |

---

## 8. Problèmes fréquents

| Symptôme | Cause | Solution |
|---|---|---|
| `network coolify not found` | nom du réseau erroné | `docker network ls`, corriger `TRAEFIK_NETWORK` |
| 404 de Traefik | domaine saisi **aussi** dans l'onglet Domains | n'utiliser qu'un seul mécanisme de routage |
| Certificat non émis | entrypoint erroné (`websecure` au lieu de `https`) | corriger `TRAEFIK_ENTRYPOINT_HTTPS` |
| `pull access denied` sur l'image de base | serveur non authentifié à ghcr.io | `docker login ghcr.io` sur le VPS |
| `502 Bad Gateway` pendant 2-3 min | Odoo démarre | attendre (`start_period` = 120 s) |
| Notifications figées | websocket non routé | le routage doit viser `proxy`, jamais `odoo` |
| Base absente du sélecteur | `DB_FILTER` ≠ `DB_NAME` | aligner les deux |
| `FATAL: password authentication failed` | `DB_PASSWORD` changé après création du volume | restaurer l'ancien, ou recréer le volume et restaurer |
| Build « no space left on device » | images intermédiaires | `docker system prune -af` (sans `--volumes` si des stacks tournent) |
