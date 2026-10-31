# Deploy helpers for the k8s manifests in this repo.
# Images are built in the service repos (../recommendations-be, ../auth-be).
#
#   make apply              # recommendations
#   make apply SVC=auth     # auth-service

SVC ?= recommendations

NS     := $(SVC)
DEPLOY := $(SVC)-service
DIR    := k8s/$(SVC)-service
KNS    := kubectl -n $(NS)

ifeq ($(wildcard $(DIR)/kustomization.yaml),)
  $(error unknown SVC "$(SVC)" -- try recommendations or auth)
endif

.DEFAULT_GOAL := help

.PHONY: help
help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: apply
apply: ## Apply manifests and wait
	kubectl apply -k $(DIR)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

# No configMapGenerator, so the ConfigMap has no name hash: editing it does not
# roll the Deployment. The restart is required, not a convenience.
.PHONY: apply-config
apply-config: ## Apply after a configmap.yaml change
	kubectl apply -k $(DIR)
	$(KNS) rollout restart deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: restart
restart: ## Bounce the pods
	$(KNS) rollout restart deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: status
status: ## Wait on the current rollout
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: rollback
rollback: ## Undo the last rollout
	$(KNS) rollout undo deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: ps
ps: ## Show pods
	@$(KNS) get pods -l app=$(DEPLOY) -o wide

.PHONY: logs
logs: ## Tail the app container
	$(KNS) logs -f deploy/$(DEPLOY) -c $(DEPLOY) --tail=100

.PHONY: logs-proxy
logs-proxy: ## Tail the cloud-sql-proxy sidecar
	$(KNS) logs -f deploy/$(DEPLOY) -c cloud-sql-proxy --tail=100

.PHONY: events
events: ## Pod events -- read this first on a failure
	@$(KNS) describe pod -l app=$(DEPLOY) | sed -n '/^Events/,$$p'

.PHONY: health
health: ## curl /api/v1/health via the LoadBalancer
	@ip=$$($(KNS) get svc $(DEPLOY) -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); \
	curl -fsS "http://$$ip/api/v1/health"; printf '\n'
