
# Image URL to use all building/pushing image targets
IMG ?= milvusdb/milvus-operator:dev-latest
RELEASE_IMG ?= milvusdb/milvus-operator:latest
SIT_IMG ?= milvus-operator:sit

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"
# cert-manager 
CERT_MANAGER_MANIFEST ?= "https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

CERT_DIR = ${TMPDIR}/k8s-webhook-server/serving-certs
CSR_CONF = config/cert/csr.conf
DEV_HOOK_PATCH  = config/dev/webhook_patch.yaml

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

generate: controller-gen go-generate ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

go-generate:
	go install github.com/golang/mock/mockgen@v1.6.0
	go generate ./...

generate-client-groups:
	./hack/update-codegen.sh

fmt: ## Run go fmt against code.
	go fmt ./...

vet: ## Run go vet against code.
	go vet ./...

ENVTEST_ASSETS_DIR=$(shell pwd)/testbin
test: manifests generate fmt vet ## Run tests.
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile tmp.out; cat tmp.out | sed '/zz_generated.deepcopy.go/d' | sed '/_mock.go/d'  > cover.out

code-check: go-generate fmt vet

test-only: 
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test ./... -coverprofile tmp.out; cat tmp.out | sed '/zz_generated.deepcopy.go/d' | sed '/_mock.go/d'  > cover.out

##@ Build

build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

build-only:
	go build -o bin/manager main.go

run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

docker-build: test build ## Build docker image with the manager.
	docker build -t ${IMG} .

docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: deploy-cert-manager ## Deploy controller to the K8s cluster specified in ~/.kube/config.
#	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
#	$(KUSTOMIZE) build config/default | kubectl apply -f -
	kubectl apply -f deploy/manifests/deployment.yaml

undeploy: undeploy-cert-manager ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
#	$(KUSTOMIZE) build config/default | kubectl delete -f -
	kubectl delete -f deploy/manifests/deployment.yaml

deploy-dev: deploy-cert-manager manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/dev | kubectl apply -f -

deploy-cert-manager:
	kubectl apply -f ${CERT_MANAGER_MANIFEST}
	kubectl wait --timeout=3m --for=condition=Ready pods -l app.kubernetes.io/instance=cert-manager -n cert-manager

undeploy-cert-manager:
    kubectl delete -f ${CERT_MANAGER_MANIFEST}

deploy-manifests: manifests kustomize
	$(KUSTOMIZE) build config/default > deploy/manifests/deployment.yaml

kind-dev: kind
	sudo $(KIND) create cluster --config config/kind/kind-dev.yaml --name kind-dev

uninstall-kind-dev: kind
	sudo $(KIND) delete cluster --name kind-dev

# Install local certificate
# Required for webhook server to start
dev-cert:
	$(RM) -r $(CERT_DIR)
	mkdir -p $(CERT_DIR)
	openssl genrsa -out $(CERT_DIR)/ca.key 2048
	openssl req -x509 -new -nodes -key $(CERT_DIR)/ca.key -subj "/CN=host.docker.internal" -days 10000 -out $(CERT_DIR)/ca.crt
	openssl genrsa -out $(CERT_DIR)/tls.key 2048
	openssl req -new -SHA256 -newkey rsa:2048 -nodes -keyout $(CERT_DIR)/tls.key -out $(CERT_DIR)/tls.csr -subj "/C=CN/ST=Shanghai/L=Shanghai/O=/OU=/CN=host.docker.internal"
	openssl req -new -key $(CERT_DIR)/tls.key -out $(CERT_DIR)/tls.csr -config $(CSR_CONF)
	openssl x509 -req -in $(CERT_DIR)/tls.csr -CA $(CERT_DIR)/ca.crt -CAkey $(CERT_DIR)/ca.key -CAcreateserial -out $(CERT_DIR)/tls.crt -days 10000 -extensions v3_ext -extfile $(CSR_CONF)
	
CA64=$(shell base64 -i $(CERT_DIR)/ca.crt)
CA=$(CA64:K==)
dev-cert-apply: dev-cert
	$(RM) -r config/dev/webhook_patch_ca.yaml
	echo '- op: "add"' > config/dev/webhook_patch_ca.yaml
	echo '  path: "/webhooks/0/clientConfig/caBundle"' >> config/dev/webhook_patch_ca.yaml
	echo "  value: $(CA)" >> config/dev/webhook_patch_ca.yaml

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.6.0)

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

KIND = $(shell pwd)/bin/kind
kind: ## Download kind locally if necessary.
	$(call go-get-tool,$(KIND),sigs.k8s.io/kind@v0.11.1)

##@ system integration test
sit-prepare-images:
	docker build -t ${SIT_IMG} .
	docker pull -q milvusdb/milvus:v2.0.0-rc8-20211104-d1f4106
	docker pull -q apachepulsar/pulsar:2.7.3
	docker pull -q bitnami/etcd:3.5.0-debian-10-r24
	docker pull -q bitnami/minio:2021.10.6-debian-10-r0
	docker pull -q bitnami/minio-client:2021.9.23-debian-10-r13
	docker pull -q quay.io/jetstack/cert-manager-controller:v1.5.3
	docker pull -q quay.io/jetstack/cert-manager-webhook:v1.5.3
	docker pull -q quay.io/jetstack/cert-manager-cainjector:v1.5.3

sit-load-images:
	kind load docker-image milvusdb/milvus:v2.0.0-rc8-20211104-d1f4106
	kind load docker-image apachepulsar/pulsar:2.7.3
	kind load docker-image bitnami/etcd:3.5.0-debian-10-r24
	kind load docker-image bitnami/minio:2021.10.6-debian-10-r0
	kind load docker-image bitnami/minio-client:2021.9.23-debian-10-r13
	kind load docker-image ${SIT_IMG}
	kind load docker-image quay.io/jetstack/cert-manager-controller:v1.5.3
	kind load docker-image quay.io/jetstack/cert-manager-webhook:v1.5.3
	kind load docker-image quay.io/jetstack/cert-manager-cainjector:v1.5.3

sit-generate:
	cat deploy/manifests/deployment.yaml | sed  "s#${RELEASE_IMG}#${SIT_IMG}#g" > test/test_gen.yaml

sit-deploy: sit-load-images deploy-cert-manager sit-generate
	kubectl apply -f test/test_gen.yaml
	kubectl wait --timeout=3m --for=condition=available deployments/milvus-operator-controller-manager -n milvus-operator

sit-test: 
	./test/sit.sh

cleanup-sit:
	kubectl delete -f test/test_gen.yaml


# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef
