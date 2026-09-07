###############################################################################
#  odoo-stack — pilotage du parc de clients Odoo.
#  Tapez `make` pour voir toutes les commandes.
#
#  La plupart des commandes prennent le client en paramètre :  c=<slug>
#      make up c=acme        make logs c=acme        make backup c=acme
###############################################################################
SHELL := /bin/bash
.DEFAULT_GOAL := help

CLIENTS_DIR := clients
GREEN := \033[0;32m
BLUE  := \033[0;34m
YELL  := \033[0;33m
RED   := \033[0;31m
NC    := \033[0m

define need_client
	@[ -n "$(c)" ] || { printf "$(RED)Précisez le client : make $@ c=<slug>$(NC)\n"; exit 1; }
	@[ -d "$(CLIENTS_DIR)/$(c)" ] || { printf "$(RED)Client inconnu : $(c)$(NC)\n"; exit 1; }
endef

help: ## Affiche cette aide
	@printf "\n$(BLUE)odoo-stack$(NC) — parc Odoo Enterprise multi-clients\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-16s$(NC) %s\n", $$1, $$2}'
	@printf "\n  $(YELL)Exemples :$(NC)\n"
	@printf "    make new                 # créer un nouveau client (assistant)\n"
	@printf "    make list                # lister le parc\n"
	@printf "    make dev c=acme          # démarrer acme en développement\n"
	@printf "    make module c=acme m=acme_ventes\n\n"

## --------------------------------------------------------------- Parc clients
new: ## Assistant de création d'un nouveau client
	@./new-client.sh

list: ## Liste tous les clients et leurs ports
	@bash -c 'STACK_ROOT=$(PWD); source lib/common.sh; source lib/registry.sh; registry_list'

doctor: ## Vérifie l'environnement et la cohérence du parc
	@./bin/doctor.sh

module: ## Nouveau module Odoo : make module c=acme m=acme_ventes
	@[ -n "$(c)" ] && [ -n "$(m)" ] || { printf "$(RED)Usage : make module c=<slug> m=<module>$(NC)\n"; exit 1; }
	@./bin/new-module.sh $(c) $(m) "$(t)"

## ------------------------------------------------------- Un client en particulier
up: ## Démarre un client (prod) : make up c=acme
	$(need_client)
	@$(MAKE) -C $(CLIENTS_DIR)/$(c) up

dev: ## Démarre un client en développement : make dev c=acme
	$(need_client)
	@$(MAKE) -C $(CLIENTS_DIR)/$(c) dev

down: ## Arrête un client : make down c=acme
	$(need_client)
	@$(MAKE) -C $(CLIENTS_DIR)/$(c) down

logs: ## Logs d'un client : make logs c=acme
	$(need_client)
	@$(MAKE) -C $(CLIENTS_DIR)/$(c) logs

shell: ## Shell dans le conteneur Odoo : make shell c=acme
	$(need_client)
	@$(MAKE) -C $(CLIENTS_DIR)/$(c) shell

backup: ## Sauvegarde d'un client : make backup c=acme
	$(need_client)
	@$(MAKE) -C $(CLIENTS_DIR)/$(c) backup

## ------------------------------------------------------------ Tout le parc
status-all: ## État de tous les clients
	@for d in $(CLIENTS_DIR)/*/; do \
		[ -f "$$d/docker-compose.yml" ] || continue; \
		printf "\n$(BLUE)== %s ==$(NC)\n" "$$(basename $$d)"; \
		(cd "$$d" && docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null) || true; \
	done

backup-all: ## Sauvegarde immédiate de tous les clients
	@for d in $(CLIENTS_DIR)/*/; do \
		[ -f "$$d/docker-compose.yml" ] || continue; \
		printf "\n$(BLUE)== %s ==$(NC)\n" "$$(basename $$d)"; \
		(cd "$$d" && $(MAKE) --no-print-directory backup) || printf "$(RED)échec$(NC)\n"; \
	done

pull-all: ## git pull sur tous les dépôts clients
	@for d in $(CLIENTS_DIR)/*/; do \
		[ -d "$$d/.git" ] || continue; \
		printf "$(BLUE)%-20s$(NC) " "$$(basename $$d)"; \
		(cd "$$d" && git pull --ff-only 2>&1 | tail -1) || true; \
	done

.PHONY: help new list doctor module up dev down logs shell backup status-all backup-all pull-all
