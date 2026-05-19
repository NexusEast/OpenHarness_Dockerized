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

update-oh: ## Rebuild OH image and recreate containers
	./update-oh.sh

update-deployer: ## Update this wrapper repo (git pull --ff-only)
	./update-deployer.sh

uninstall: ## Remove containers and shims (keep user data)
	./uninstall.sh

shims: ## (Re)install host shims to ~/.local/bin
	./scripts/install-shims.sh --repo $(CURDIR)

build: ## Build the docker image only (sandbox image; UID/GID baked at build time)
	docker build -t openharness-dockerized:latest \
	  --build-arg SANDBOX_UID=1000 --build-arg SANDBOX_GID=1000 \
	  ./docker

.PHONY: help deploy list status restart update-oh update-deployer uninstall shims build
