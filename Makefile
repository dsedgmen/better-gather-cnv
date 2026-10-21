IMAGE_REGISTRY ?= quay.io
IMAGE_TAG ?= latest
GINKGO_JUNIT_REPORT ?= report.xml

# MUST_GATHER_IMAGE needs to be passed explicitly to avoid accidentally pushing to kubevirt/must-gather
check-image-env:
ifndef MUST_GATHER_IMAGE
	$(error MUST_GATHER_IMAGE is not set.)
endif

IMAGE_NAME = $(IMAGE_REGISTRY)/$(MUST_GATHER_IMAGE):$(IMAGE_TAG)

build: check-image-env docker-multi-arch

# check
check:
	shellcheck -a -e SC2016 -e SC2317 --source-path=./collection-scripts collection-scripts/*

docker-build: check-image-env
	docker build -t ${IMAGE_NAME} -f Dockerfile.quay .

docker-push: check-image-env
	docker push ${IMAGE_NAME}

docker-build-%: check-image-env
	docker build --platform="linux/$*" -t ${IMAGE_NAME}-$* -f Dockerfile.quay .

docker-push-%: check-image-env docker-build-%
	docker push ${IMAGE_NAME}-$*

docker-multi-arch: docker-push-amd64 docker-push-arm64 docker-push-s390x
	docker manifest rm ${IMAGE_NAME} || true
	docker manifest create ${IMAGE_NAME} ${IMAGE_NAME}-amd64 ${IMAGE_NAME}-arm64 ${IMAGE_NAME}-s390x
	docker manifest push ${IMAGE_NAME}

test-build:
	(cd tests; go test -c -o must-gather.test .)

test: test-build
	tests/must-gather.test --ginkgo.label-filter=level:product --ginkgo.junit-report=${GINKGO_JUNIT_REPORT} --ginkgo.v

.PHONY: build docker-build docker-push docker-multi-arch test-build test

# ---------------------------------------------------------------------------
# better-gather-cnv additions
# ---------------------------------------------------------------------------

LOCALBIN ?= $(shell pwd)/tmp/bin
BATS ?= $(LOCALBIN)/bats
SHELLCHECK ?= $(LOCALBIN)/shellcheck
CNV_SCRIPT_DIRS := collection-scripts/ hack/ tests/

# BASE has no default on purpose. This image adds only shell scripts, so all
# of its CVE exposure comes from whatever it is layered on, and
# quay.io/kubevirt/must-gather:latest has not been rebuilt since July. Pass
# the image your cluster advertises, or build a current one with image-base.
BASE ?=
OVERLAY_IMAGE ?= better-gather-cnv:latest
BASE_IMAGE ?= better-gather-cnv-base:latest
MAX_BASE_AGE_DAYS ?= 60

.PHONY: tools-from-packages
tools-from-packages:
	./hack/tools-from-packages.sh

$(LOCALBIN)/%:
	./hack/tools-from-packages.sh $*

.PHONY: bats-test
bats-test: $(BATS)
	$(BATS) tests/*.bats

.PHONY: bats-lint
bats-lint: $(SHELLCHECK)
# -e SC2016,SC2317 matches upstream's own `check` target: the collection
# scripts deliberately use single-quoted expressions for remote shells.
# -e SC2329 as well: several functions here are invoked indirectly, through
# `xargs ... sh -c`, which shellcheck cannot see.
# vendor/ is third-party Go tooling that happens to contain shell scripts.
# Unlike upstream's `collection-scripts/*` glob, the shebang test also keeps
# incident_metrics.conf -- a config file, not a script -- out of the lint.
	find $(CNV_SCRIPT_DIRS) -type f -not -path '*/vendor/*' \
		-exec grep -Eq '^#!.*/(env +)?(ba|da|k|z)?sh\b' {} \; \
		-exec $(SHELLCHECK) -x --source-path=./collection-scripts \
			-e SC2016 -e SC2317 -e SC2329 {} +

# NB: upstream already defines a `check` target, so these are namespaced
# rather than overriding it.
.PHONY: bats-check
bats-check: bats-lint bats-test

.PHONY: image-base
image-base:
	podman build -t $(BASE_IMAGE) -f Dockerfile.base .

.PHONY: check-base
check-base:
	@test -n "$(BASE)" || { echo "set BASE to the image your cluster advertises, or build one with make image-base"; exit 2; }
	./hack/check-base.sh --max-age $(MAX_BASE_AGE_DAYS) $(BASE)

.PHONY: image-overlay
image-overlay:
	@test -n "$(BASE)" || { echo "set BASE to the image your cluster advertises, or build one with make image-base"; exit 2; }
	podman build --build-arg BASE=$(BASE) \
		--build-arg BASE_BUILT="$$(./hack/check-base.sh --warn-only $(BASE) 2>/dev/null | sed -n 's/^built: \([0-9-]*\).*/\1/p' | grep . || echo unknown)" \
		-t $(OVERLAY_IMAGE) -f Dockerfile.overlay .
