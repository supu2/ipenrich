PROJECT := $(shell basename $(CURDIR))
current_dir = $(shell pwd)
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
HASH := $(shell git rev-parse HEAD)
NAMESPACE := $(PROJECT)-$(BRANCH)
ifdef REGISTRY
REGISTRY := $(REGISTRY)
else
REGISTRY := localhost:5001
endif


# HELP
# This will output the help for each task
.PHONY: help

help: ## This help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help

binfolder:
	mkdir -p $(HOME)/.local/bin/
	cat $(HOME)/.bashrc  | grep -qF ".local/bin/"  || echo 'export PATH=$$PATH:$$HOME/.local/bin/' >> $(HOME)/.bashrc 
	
kubectx: 
	kubectl config use-context kind-kind

# Build the container
build-container: ## Build the container
	docker build -t $(PROJECT):$(BRANCH) .

push-container: test-cst ## Push container to local registry
	docker tag $(PROJECT):$(BRANCH) $(REGISTRY)/$(PROJECT):$(BRANCH) 
	docker push $(REGISTRY)/$(PROJECT):$(BRANCH)

run-container: ## Run container for the test
	docker run -i -t -p 8000:8000 --rm --name="$(PROJECT)" $(PROJECT):$(BRANCH)

stop-container: ## Stop and remove a running container
	docker stop $(PROJECT); docker rm $(PROJECT) 

clean: ## Clean container 
	docker stop $(PROJECT); docker rm $(PROJECT); docker rmi $(PROJECT):$(BRANCH)

install-kind: binfolder ## kind minimal kubernetes for local development
	curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.14.0/kind-linux-amd64 ;\
	chmod +x ./kind ;\
	mv ./kind $(HOME)/.local/bin/kind 

install-kubectl: binfolder ## Install kubectl 
	curl -LO "https://dl.k8s.io/release/v1.24.2/bin/linux/amd64/kubectl" && \
	chmod +x kubectl && mv kubectl $(HOME)/.local/bin/kubectl

install-helm: binfolder ## Install helm
	curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

install-cst: binfolder ## Install container structure test 
	curl -LO https://storage.googleapis.com/container-structure-test/latest/container-structure-test-linux-amd64 && \
	chmod +x container-structure-test-linux-amd64 && mv container-structure-test-linux-amd64 $(HOME)/.local/bin/container-structure-test

deploy-app: kubectx ## Deploy application to kind kubernetes 
	helm upgrade --install -n $(NAMESPACE) --create-namespace -f helm/values.yaml $(PROJECT) ./helm \
	--set image.tag=$(BRANCH) \
	--set image.repository=$(REGISTRY)/$(PROJECT) \
	--set serviceMonitor.enabled=true \
	--set ingress.enabled=true \
	--set image.pullPolicy=Always
deploy-cluster:  ## Deploy kind cluster with local registry
	sh -c cluster/cluster-local-registry.sh
deploy-ingress: kubectx ## Deploy nginx ingress controller
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
deploy-metricserver: kubectx ## Deploy metric server for enable HPA. 
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
	helm upgrade --install metrics-server -n kube-system metrics-server/metrics-server --set args[0]=--kubelet-insecure-tls 
deploy-opa: kubectx ## Deploy open policy agent
	kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.8/deploy/gatekeeper.yaml
deploy-prometheus: kubectx ## Deploy prometheus operator
	kubectl create -f https://github.com/prometheus-operator/prometheus-operator/raw/v0.57.0/bundle.yaml
	kubectl apply -f cluster/prometheus.yaml

delete-app: kubectx ## Delete application from kind kubernetes 
	helm uninstall -n $(NAMESPACE) $(PROJECT)
delete-cluster:  kubectx ## Destroy kind cluter
	kind delete  cluster   
delete-ingress: kubectx ## Delete nginx ingress controller
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
delete-metricserver: kubectx ## Delete metric server 
	helm uninstall -n kube-system metrics-server 
delete-opa: kubectx ## Deploy open policy agent
	kubectl delete -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.8/deploy/gatekeeper.yaml
delete-prometheus: kubectx ## Delete prometheus operator
	kubectl delete -f https://github.com/prometheus-operator/prometheus-operator/raw/v0.57.0/bundle.yaml
	kubectl apply -f cluster/prometheus.yaml


perform-test: ## Performance test, expected requests per second bigger than 10000
	docker run --add-host=chart-example.local:172.17.0.1 --rm jordi/ab -c 100 -n 10000 http://chart-example.local/?ip=1.1.1.1 
	curl chart-example.local:80/metrics
test-app: kubectx ## Test deployed app
	helm test -n $(PROJECT)-$(BRANCH) $(PROJECT)
test-cst: ## Test container structure
	container-structure-test test --image $(PROJECT):$(BRANCH) \
	--config test/cst.yaml
