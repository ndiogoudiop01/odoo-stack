# Déployer un client sur Coolify

Procédure complète, du dépôt vide au site en HTTPS. Comptez 15 minutes la
première fois, 5 minutes ensuite.

---

## 0. Préparer le serveur (une seule fois)

Sur le VPS OVH, Coolify est déjà installé et gère Traefik + Let's Encrypt.
Vérifiez seulement :

* **Servers → votre serveur → Proxy** : Traefik démarré, ports 80/443 ouverts.
* **Storage** : au moins 20 Go libres par client Odoo (base + filestore + images).
* **Swap** : 2 Go de swap évitent les OOM lors des `make upgrade M=all`.

### Accès au dépôt privé Odoo Enterprise

Le dossier `enterprise/` est un **submodule git** pointant sur
`github.com/odoo/enterprise`. Pour que Coolify puisse le cloner :

1. Coolify → **Keys & Tokens → Private Keys** → générer une clé SSH.
2. Ajouter la clé publique comme **Deploy key** sur le dépôt du client *et*
   s'assurer que le compte GitHub lié a accès à `odoo/enterprise`.
3. Dans la ressource : **Source → Private Key** → sélectionner cette clé.

> **Si Coolify ne clone pas les submodules** (selon la version), deux solutions :
> * cocher *Submodules* dans les options de la source si disponible ;
> * sinon, garder `enterprise/` hors git et le monter en volume : voir
>   « Variante sans submodule » en bas de page.

---

## 1. Pousser le dépôt du client

```bash
cd clients/acme
git remote add origin git@github.com:votre-org/odoo-acme.git
git push -u origin main
```

Le dépôt doit être **privé** (il contient le pointeur vers Enterprise et votre
code métier). Le `.env` et `COOLIFY-ENV.txt` ne sont pas poussés : c'est voulu.

---

## 2. Créer la ressource Coolify

**Project → New Resource → Docker Compose**

| Champ | Valeur |
|---|---|
| Source | votre dépôt GitHub privé |
| Branch | `main` |
| Base Directory | `/` |
| Docker Compose Location | `/docker-compose.yml` |
| Build Pack | Docker Compose |

Coolify lit le fichier et détecte les 4 services : `db`, `odoo`, `proxy`,
`backup`.

---

## 3. Variables d'environnement

Onglet **Environment Variables → Developer view** : collez tel quel le contenu
de `clients/acme/COOLIFY-ENV.txt`.

Cochez **Is Secret** (ou « Locked ») pour :

```
DB_PASSWORD
ODOO_MASTER_PASSWORD
BACKUP_ENC_PASSPHRASE
```

> **Ne collez jamais** les variables `HTTP_PORT`, `PG_PORT`, `PROXY_PORT`,
> `DEBUGPY_PORT` : elles ne servent qu'au développement local et publieraient
> des ports sur le VPS.

---

## 4. Domaine et SSL

Onglet **Domains** → service **`proxy`** → `https://erp.acme.sn`.

Coolify renseigne alors automatiquement la variable magique
`SERVICE_FQDN_PROXY_80`, génère les labels Traefik et demande le certificat
Let's Encrypt.

Côté DNS (LWS, OVH, Cloudflare…) :

```
Type  Nom            Valeur
A     erp.acme.sn    <IP publique du VPS>
```

Avec Cloudflare, mettez l'enregistrement en **DNS only** (nuage gris) le temps
de l'émission du certificat.

---

## 5. Premier déploiement

**Deploy**. Le premier build prend 3 à 6 minutes (téléchargement de l'image
Odoo et des dépendances Python).

Suivez **Logs → odoo** ; le démarrage est correct quand vous voyez :

```
odoo.service.server: HTTP service (werkzeug) running on 0.0.0.0:8069
```

Puis ouvrez `https://erp.acme.sn/web/database/manager`, créez la base avec le
**nom exact** de `DB_NAME` (sinon `DB_FILTER` la masquera) et le master password.

Une fois la base créée, vérifiez que `LIST_DB=False` est bien actif : le
gestionnaire de bases doit devenir inaccessible.

---

## 6. Déploiements suivants

```bash
git add -A && git commit -m "feat(ventes): …" && git push
```

Coolify rebuild et redémarre automatiquement. Après un changement de modèle ou
de vue, mettez le module à jour depuis le **Terminal** de la ressource :

```bash
odoo --config=/etc/odoo/odoo.conf -d acme_prod -u acme_ventes --stop-after-init --no-http
```

ou, si vous avez le dépôt sur le serveur :

```bash
make upgrade M=acme_ventes
```

### Zéro downtime

Coolify propose **Rolling update** dans les paramètres de la ressource.
Attention : Odoo ne supporte pas deux versions de schéma simultanément. Pour une
mise à jour qui touche la base, préférez une courte fenêtre d'arrêt
(`stop → upgrade → start`), c'est plus sûr qu'un rolling update.

---

## 7. Vérifications post-déploiement

| Test | Attendu |
|---|---|
| `https://erp.acme.sn` | page de connexion, cadenas vert |
| Chat interne / notifications temps réel | fonctionne → le websocket passe bien par nginx |
| `https://erp.acme.sn/web/database/manager` | inaccessible (`LIST_DB=False`) |
| **Logs → backup** | « sauvegarde quotidienne planifiée à 2h00 » |
| Import d'un fichier de 50 Mo | passe (limite nginx à 512 Mo) |

---

## 8. Problèmes fréquents

| Symptôme | Cause | Solution |
|---|---|---|
| `502 Bad Gateway` pendant 2-3 min | Odoo démarre encore | attendre ; le healthcheck a un `start_period` de 120 s |
| Notifications figées, chat qui ne se met pas à jour | websocket non routé | vérifier que le domaine pointe sur le service **`proxy`**, pas sur `odoo` |
| `enterprise/` vide dans le conteneur | submodule non cloné par Coolify | voir la variante ci-dessous |
| `FATAL: password authentication failed` | `DB_PASSWORD` modifié après création du volume | le mot de passe est figé dans le volume PG : le restaurer, ou recréer le volume et restaurer une sauvegarde |
| Base absente du sélecteur | `DB_FILTER` ne correspond pas | aligner `DB_NAME` et `DB_FILTER` |
| Certificat non émis | DNS non propagé ou proxy Cloudflare actif | vérifier l'enregistrement A, passer en DNS only |
| Build « no space left on device » | images intermédiaires | `docker system prune -af --volumes` (attention aux volumes en cours d'usage) |

---

## Variante sans submodule (si Coolify ne clone pas les submodules)

Cloner une seule fois le code Enterprise sur le VPS, et le monter en lecture
seule dans tous les clients de cette version :

```bash
# sur le VPS, une fois par version
sudo mkdir -p /opt/odoo-enterprise
sudo git clone --depth 1 -b 19.0 git@github.com:odoo/enterprise.git \
     /opt/odoo-enterprise/19.0
```

Puis, dans la ressource Coolify, ajouter un **Volume Mount** au service `odoo` :

```
/opt/odoo-enterprise/19.0  ->  /mnt/enterprise   (read only)
```

et retirer la ligne `COPY --chown=odoo:odoo enterprise /mnt/enterprise` du
`Dockerfile` du client. Mise à jour du code Enterprise :

```bash
cd /opt/odoo-enterprise/19.0 && sudo git pull
```

Avantage : quelques gigaoctets économisés par client et une seule mise à jour
pour tous. Inconvénient : l'image n'est plus autonome et le serveur porte un
état à maintenir.
