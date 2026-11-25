# Developer entry points. `make help` lists them.
TAG ?= local-$(shell date +%Y%m%d%H%M%S)
BACKEND  := weather-backend:$(TAG)
FRONTEND := weather-frontend:$(TAG)
TF_LOCAL := terraform -chdir=infra/local
# Cluster kubeconfig lives outside the repo (it holds the admin key).
export KUBECONFIG := $(HOME)/.kube/kind-weather

.PHONY: help test images local-up local-down local-collect

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

test: ## Run backend unit tests and Terraform mocked tests
	cd app/backend && .venv/bin/python -m pytest -q
	terraform -chdir=infra/terraform test

images: ## Build both images with a unique tag
	docker build -t $(BACKEND) app/backend
	docker build -t $(FRONTEND) app/frontend

local-up: images ## Create kind cluster + platform + app (UI on http://127.0.0.1:8088)
	$(TF_LOCAL) init -input=false -upgrade=false
	$(TF_LOCAL) apply -input=false -auto-approve -var 'images={backend="$(BACKEND)",frontend="$(FRONTEND)"}'
	$(MAKE) local-collect

local-collect: ## Run the collector once now instead of waiting for the schedule
	kubectl -n weather create job --from=cronjob/weather-collector collect-$(shell date +%s)

local-down: ## Destroy the local cluster and everything in it
	kind delete cluster --name weather
	rm -f infra/local/terraform.tfstate infra/local/terraform.tfstate.backup
