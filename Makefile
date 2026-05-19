SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

deploy: ## Run the interactive deploy wizard
	./deploy.sh

list: ## List all OH instances
	./scripts/oh-ctl.sh list

status: ## Show container status
	./status.sh

restart: ## Restart default instance
	./restart.sh

update: ## Rebuild image and recreate containers
	./update.sh

uninstall: ## Remove containers and shims (keep user data)
	./uninstall.sh

shims: ## (Re)install host shims to ~/.local/bin
	./scripts/install-shims.sh --repo $(CURDIR)

build: ## Build the docker image only
	docker build -t openharness-dockerized:latest \
	  --build-arg HOST_UID=$$(id -u) --build-arg HOST_GID=$$(id -g) \
	  --build-arg HOST_USER=$$(id -un) --build-arg HOST_HOME=$$HOME \
	  ./docker

.PHONY: help deploy list status restart update uninstall shims build
