PROJECT = $(shell basename $(CURDIR))
current_dir = $(shell pwd)
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
HASH := $(shell git rev-parse HEAD)


# HELP
# This will output the help for each task
.PHONY: help

help: ## This help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help

test1:
	echo $(PROJECT) $(current_dir) $(BRANCH) $(HASH)
# Build the container
buildcontainer: ## Build the container
	docker build -t $(PROJECT) .

pushcontainer: ## Push container to local registry
	docker tag $(PROJECT) localhost:5001/$(PROJECT);\
	docker push localhost:5001/$(PROJECT)

runcontainer: ## Run container for the test
	docker run -i -t --rm --name="$(PROJECT)" $(PROJECT)

stopcontainer: ## Stop and remove a running container
	docker stop $(PROJECT); docker rm $(PROJECT) 

clean: ## Clean container 
	docker stop $(PROJECT); docker rm $(PROJECT); docker rmi $(PROJECT) 

installkind: ## kind minimal kubernetes for local development
	curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.14.0/kind-linux-amd64 ;\
	chmod +x ./kind ;\
	mv ./kind /some-dir-in-your-PATH/kind 

deploycluster: ## Deploy kind cluster with local registry
	sh -c cluster/cluster-local-registry.sh
deletecluster: ## Destroy kind cluter
	kind delete  cluster   

deployopa: ## Deploy open policy agent
	kubectl config use-context kind-kind
	kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.8/deploy/gatekeeper.yaml
deleteopa: ## Deploy open policy agent
	kubectl config use-context kind-kind
	kubectl delete -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.8/deploy/gatekeeper.yaml

deployingress: ## Deploy nginx ingress controller
	kubectl config use-context kind-kind
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
deleteingress: ## Delete nginx ingress controller
	kubectl config use-context kind-kind
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

deployapp: ## Deploy application to kind kubernetes 
	kubectl config use-context kind-kind
	helm upgrade --install -f $(PROJECT)/values.yaml $(PROJECT) ./$(PROJECT)
deleteapp: ## Delete application from kind kubernetes 
	kubectl config use-context kind-kind
	helm uninstall $(PROJECT)
testapp: ## Test deployed app
	kubectl config use-context kind-kind
	helm test $(PROJECT)

deployprometheus: ## Deploy prometheus operator
	kubectl config use-context kind-kind
	kubectl create -f https://github.com/prometheus-operator/prometheus-operator/raw/v0.57.0/bundle.yaml
	kubectl apply -f cluster/prometheus.yaml
deleteprometheus: ## Delete prometheus operator
	kubectl config use-context kind-kind
	kubectl delete -f https://github.com/prometheus-operator/prometheus-operator/raw/v0.57.0/bundle.yaml
	kubectl apply -f cluster/prometheus.yaml

deploymetricserver: ## Deploy metric server for enable HPA. 
	kubectl config use-context kind-kind
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
	helm upgrade --install metrics-server -n kube-system metrics-server/metrics-server --set args[0]=--kubelet-insecure-tls 
deletemetricserver: ## Delete metric server 
	kubectl config use-context kind-kind
	helm uninstall -n kube-system metrics-server 

performtest: ## Performance test 
	docker run --add-host=chart-example.local:172.17.0.1 --rm jordi/ab -v 2 http://chart-example.local/enrich?ip=1.1.1.1