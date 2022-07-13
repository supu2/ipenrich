PROJECT := $(shell basename $(CURDIR))
current_dir = $(shell pwd)
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
HASH := $(shell git rev-parse HEAD)
NAMESPACE := $(PROJECT)-$(BRANCH)
PROJECT_URL := https://github.com/supu2/ipenrich
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
	@echo "Please add domain record in hosts file"
	@echo 'sudo echo "172.17.0.1 grafana.chart-example.local \n 172.17.0.1 chart-example.local" >> /etc/hosts' 

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
run-pipeline: kubectx ## Run tekton pipeline
	@echo "--- Create Tekton Pipeline" 
	kubectl apply -n $(NAMESPACE) -f pipeline/pipeline.yaml
	@echo "--- Create parameterized Tekton PipelineRun yaml" 
	tkn  p list -n $(NAMESPACE)
	tkn pipeline start pipeline -n $(NAMESPACE) \
	--workspace name=shared-workspace,subPath=$(PROJECT),claimName=shared-workspace-pvc  \
	--param IMAGE=$(REGISTRY)/$(PROJECT) \
	--param CI_COMMIT_BRANCH=$(BRANCH) \
	--param CI_PROJECT_NAME=$(PROJECT) \
	--param CI_PROJECT_URL=$(PROJECT_URL) \
	--param CI_PROJECT_PATH=$(PROJECT)-$(BRANCH) \
	--param DOCKERFILE="Dockerfile"  \
	--param DOCKERCONTEXT="." \
	--param HELMFOLDER="helm" \
	--param TRIVY_IMAGE_PATH="." \
	--dry-run \
	--output yaml > pipelinerun.yml
	@echo "--- Trigger PipelineRun in Tekton / K8s" && sleep 5
	$(eval PIPELINE_RUN_NAME = $(shell kubectl create -f pipelinerun.yml -n $(NAMESPACE) --output=jsonpath='{.metadata.name}' ))
	@echo "--- Show Tekton PipelineRun logs"  && echo $(PIPELINE_RUN_NAME)
	tkn pipelinerun logs $(PIPELINE_RUN_NAME) -n $(NAMESPACE) --follow
	@echo "--- Check if Tekton PipelineRun Failed & exit GitLab Pipeline accordingly"
	tkn pipelinerun describe -n $(NAMESPACE) $(PIPELINE_RUN_NAME)
	$(eval result = $(shell kubectl get pipelineruns -n $(NAMESPACE) $(PIPELINE_RUN_NAME) --output=jsonpath='{.status.conditions[*].reason}'))
	@echo $(result)| grep Failed && exit 1 || exit 0
	kubectl delete pipelineruns -n $(NAMESPACE) $(PIPELINE_RUN_NAME) 



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

install-tkn: binfolder ## Install tkn cli
	curl -LO https://github.com/tektoncd/cli/releases/download/v0.24.0/tkn_0.24.0_Linux_x86_64.tar.gz
	tar xvzf tkn_0.24.0_Linux_x86_64.tar.gz -C $(HOME)/.local/bin/ tkn && rm  tkn_0.24.0_Linux_x86_64.tar.gz
	chmod +x $(HOME)/.local/bin/tkn
install-cst: binfolder ## Install container structure test 
	curl -LO https://storage.googleapis.com/container-structure-test/latest/container-structure-test-linux-amd64 && \
	chmod +x container-structure-test-linux-amd64 && mv container-structure-test-linux-amd64 $(HOME)/.local/bin/container-structure-test

deploy-app: kubectx ## Deploy application to kind kubernetes 
	helm upgrade --install -n $(NAMESPACE) --create-namespace -f helm/values.yaml $(PROJECT) ./helm \
	--set image.tag=$(BRANCH) \
	--set image.repository=$(REGISTRY)/$(PROJECT) \
	--set serviceMonitor.enabled=true \
	--set ingress.enabled=true \
	--set prometheusRule.enabled=true \
	--set image.pullPolicy=Always
deploy-cluster:  ## Deploy kind cluster with local registry
	sh -c cluster/cluster-local-registry.sh
deploy-loki: kubectx  ## Deploy loki stack with grafana
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	helm upgrade --install loki --namespace=loki-stack grafana/loki-stack --create-namespace \
	--set grafana.enabled=true \
	--set grafana.ingress.enabled=true \
	--set grafana.ingress.hosts[0]=grafana.chart-example.local \
	--set grafana.datasources."datasources\.yaml".apiVersion=1 \
	--set grafana.datasources."datasources\.yaml".datasources[0].name=Prometheus \
	--set grafana.datasources."datasources\.yaml".datasources[0].type=prometheus \
	--set grafana.datasources."datasources\.yaml".datasources[0].url=http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090 \
	--set grafana.datasources."datasources\.yaml".datasources[0].access=proxy 
	@echo -n "User: admin password: "
	@kubectl get secret --namespace loki-stack loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode  
	@echo "\nGrafana url: http://grafana.chart-example.local" 
deploy-ingress: kubectx ## Deploy nginx ingress controller
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
deploy-tekton: kubectx ## Deploy tekton 
	kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
deploy-tekton-tasks: kubectx ## Deploy tekton ci tasks
	kubectl apply -f pipeline/tasks/
deploy-metricserver: kubectx ## Deploy metric server for enable HPA. 
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
	helm upgrade --install metrics-server -n kube-system metrics-server/metrics-server --set args[0]=--kubelet-insecure-tls 
deploy-opa: kubectx ## Deploy open policy agent
	kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.8/deploy/gatekeeper.yaml
deploy-prometheus: kubectx ## Deploy prometheus operator
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install prometheus  -n monitoring --create-namespace prometheus-community/kube-prometheus-stack \
	--set defaultRules.create=false \
	--set grafana.enabled=false \
	--set kubeApiServer.enabled=false \
	--set kubelet.enabled=false \
	--set kubeControllerManager.enabled=false \
	--set coreDns.enabled=false \
	--set kubeEtcd.enabled=false \
	--set kubeScheduler.enabled=false \
	--set kubeProxy.enabled=false \
	--set nodeExporter.enabled=false 



delete-app: kubectx ## Delete application from kind kubernetes 
	helm uninstall -n $(NAMESPACE) $(PROJECT)
delete-cluster:  kubectx ## Destroy kind cluter
	kind delete  cluster   
delete-loki: kubectx ## Delete loki stack
	helm uninstall -n loki-stack loki
delete-ingress: kubectx ## Delete nginx ingress controller
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
delete-tekton: kubectx ## Deploy tekton 
	kubectl delete --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
delete-metricserver: kubectx ## Delete metric server 
	helm uninstall -n kube-system metrics-server 
delete-opa: kubectx ## Deploy open policy agent
	kubectl delete -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.8/deploy/gatekeeper.yaml
delete-prometheus: kubectx ## Delete prometheus operator
	helm uninstall prometheus -n monitoring


perform-test: ## Performance test, expected requests per second bigger than 10000
	docker run --add-host=chart-example.local:172.17.0.1 --rm jordi/ab -c 100 -n 100000 http://chart-example.local/?ip=1.1.1.1 
	curl chart-example.local:80/metrics
test-app: kubectx ## Test deployed app
	helm test -n $(PROJECT)-$(BRANCH) $(PROJECT)
test-cst: ## Test container structure
	container-structure-test test --image $(PROJECT):$(BRANCH) \
	--config test/cst.yaml
