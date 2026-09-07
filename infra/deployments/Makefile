# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

.EXPORT_ALL_VARIABLES:

# Load the repository-root .env. Assigning with `?=` rather than `include` is
# deliberate: an included file overrides exported shell variables, which would
# silently beat a caller's own AWS_PROFILE-aligned exports.
_REPO_ROOT := $(dir $(lastword $(MAKEFILE_LIST)))../..
_dotenv_key = $(firstword $(subst =, ,$(1)))
ifneq ($(wildcard $(_REPO_ROOT)/.env),)
  $(foreach l,$(shell sed -e '/^[[:space:]]*\#/d' -e '/^[[:space:]]*$$/d' -e 's/^export[[:space:]]*//' $(_REPO_ROOT)/.env),\
    $(eval $(call _dotenv_key,$(l)) ?= $(patsubst $(call _dotenv_key,$(l))=%,%,$(l))))
endif
export

# --- Variables ---
ECR_REGISTRY ?= $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
ENVIRONMENT ?= dev
CONTAINER_RUNTIME ?= docker
IMAGE_TAG ?= $(shell grep '^version' $(SHARED_CODE_PATH)/pyproject.toml 2>/dev/null | head -1 | sed 's/.*= *"//;s/"//')
IMAGE_PLATFORM ?= linux/amd64
DEPLOYMENT ?=
PLAN_FILE = local-plan.tfplan

# Shared copy-intermediate-to-output image
SHARED_STEP = copy-intermediate-to-output
SHARED_CODE_PATH = ../../code/shared/$(SHARED_STEP)
SHARED_REPO_NAME = shared-$(SHARED_STEP)
SHARED_IMAGE_NAME = $(ECR_REGISTRY)/$(SHARED_REPO_NAME)
VENV_DIR = .venv
PYTHON ?= python3.12

# Pin build tooling so `unit-tests-shared` is reproducible in CI/CD
# and a compromised upstream release cannot slip in via a fresh install.
PIP_VERSION ?= 24.2
POETRY_VERSION ?= 1.8.3

# Guard per target rather than at assignment so `help` and `unit-tests-shared`
# stay usable without credentials.
_REQUIRE_AWS_ENV = \
	if [ -z "$(AWS_ACCOUNT_ID)" ]; then echo "ERROR: Set AWS_ACCOUNT_ID in .env or environment"; exit 1; fi; \
	if [ -z "$(AWS_REGION)" ]; then echo "ERROR: Set AWS_REGION in .env or environment"; exit 1; fi

.PHONY: help all deploy-account-setup deploy-shared unit-tests-shared build-shared push-shared update-parameter-store-shared _check-deployment tofu-init tofu-plan tofu-apply tofu-destroy

help: ## Show this help message
	@echo "Account setup — deploy the pipeline platform infrastructure"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-25s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  DEPLOYMENT         OpenTofu deployment directory (default: account-setup)"
	@echo "  ENVIRONMENT        Environment (default: dev)"
	@echo "  CONTAINER_RUNTIME  Container runtime (default: docker; alternatives: finch, podman)"
	@echo "  IMAGE_TAG          Image tag for shared step (default: from pyproject.toml)"
	@echo ""
	@echo "First-time setup (state bucket does not yet exist):"
	@echo "  1. Ensure account-setup/terraform.tf has 'backend \"s3\" {}' commented out."
	@echo "  2. make deploy-account-setup                         # creates the state bucket locally"
	@echo "  3. Uncomment 'backend \"s3\" {}' in account-setup/terraform.tf."
	@echo "  4. make deploy-account-setup                         # migrates state into the S3 bucket"
	@echo "  5. make deploy-shared                                # test/build/push the shared image"
	@echo ""
	@echo "Steady state (state bucket exists, backend uncommented):"
	@echo "  make all"
	@echo ""
	@echo "For pipeline deployments, use the top-level Makefile:"
	@echo "  cd ../.. && make tofu-apply DEPLOYMENT=end-to-end"

# =============================================================================
# One-command setup — for steady state (backend "s3" {} is already uncommented
# and the state bucket already exists). For first-time bootstrap of a fresh
# account, see the two-pass procedure in `make help` and account-setup/README.md.
# =============================================================================

all: deploy-account-setup deploy-shared ## Deploy account-setup then test/build/push the shared image (steady state)

deploy-account-setup: ## Deploy the account-setup infrastructure
	$(MAKE) tofu-apply DEPLOYMENT=account-setup

# =============================================================================
# Infrastructure — deploy OpenTofu (default: account-setup)
# =============================================================================


_check-deployment:
	@if [ -z "$(DEPLOYMENT)" ]; then echo "ERROR: DEPLOYMENT is required. Usage: make <target> DEPLOYMENT=<path>"; exit 1; fi

tofu-init: _check-deployment ## Initialize OpenTofu for DEPLOYMENT
	@$(_REQUIRE_AWS_ENV)
	cd $(DEPLOYMENT) && tofu init -backend-config=env/$(ENVIRONMENT)/backend.tfvars --reconfigure --upgrade

tofu-plan: tofu-init ## Plan OpenTofu changes for DEPLOYMENT
	@echo "Planning $(DEPLOYMENT)"
	cd $(DEPLOYMENT) && tofu plan --var-file env/$(ENVIRONMENT)/inputs.tfvars -out=$(PLAN_FILE)

tofu-apply: tofu-plan ## Apply OpenTofu changes for DEPLOYMENT
	@echo "Applying $(DEPLOYMENT)"
	cd $(DEPLOYMENT) && tofu apply $(PLAN_FILE)

tofu-destroy: tofu-init ## Destroy OpenTofu resources for DEPLOYMENT
	@echo "Destroying $(DEPLOYMENT)"
	cd $(DEPLOYMENT) && tofu destroy -var-file env/$(ENVIRONMENT)/inputs.tfvars

# =============================================================================
# Shared image — copy-intermediate-to-output
# =============================================================================

deploy-shared: unit-tests-shared build-shared push-shared update-parameter-store-shared ## Full shared image pipeline: test, build, push, update SSM

unit-tests-shared: ## Run unit tests for the shared step (isolated in a Python venv)
	@echo "Running unit tests for shared/$(SHARED_STEP)"
	cd $(SHARED_CODE_PATH) && \
	$(PYTHON) -m venv $(VENV_DIR) && \
	. $(VENV_DIR)/bin/activate && \
	python -m pip install --upgrade "pip==$(PIP_VERSION)" "poetry==$(POETRY_VERSION)" && \
	poetry config virtualenvs.create false --local && \
	poetry install && \
	poetry run pytest --cov --cov-fail-under=0 --cov-report=term-missing

build-shared: ## Build the shared copy-intermediate-to-output image
	@$(_REQUIRE_AWS_ENV)
	@echo "Building shared image: $(SHARED_IMAGE_NAME):$(IMAGE_TAG)"
	$(CONTAINER_RUNTIME) build --platform $(IMAGE_PLATFORM) -t $(SHARED_IMAGE_NAME):$(IMAGE_TAG) $(SHARED_CODE_PATH)
	$(CONTAINER_RUNTIME) tag $(SHARED_IMAGE_NAME):$(IMAGE_TAG) $(SHARED_IMAGE_NAME):latest

push-shared: ## Push the shared copy-intermediate-to-output image to ECR
	@$(_REQUIRE_AWS_ENV)
	@echo "Pushing shared image: $(SHARED_IMAGE_NAME):$(IMAGE_TAG)"
	aws ecr get-login-password --region $(AWS_REGION) | $(CONTAINER_RUNTIME) login --username AWS --password-stdin $(ECR_REGISTRY)
	$(CONTAINER_RUNTIME) push $(SHARED_IMAGE_NAME):$(IMAGE_TAG)
	$(CONTAINER_RUNTIME) push $(SHARED_IMAGE_NAME):latest

update-parameter-store-shared: ## Update SSM parameter with shared image tag
	@$(_REQUIRE_AWS_ENV)
	@echo "Updating SSM parameter for shared/$(SHARED_STEP) with tag $(IMAGE_TAG)"
	aws ssm put-parameter --name "/pipelines/$(SHARED_REPO_NAME)" --value "$(IMAGE_TAG)" --type "String" --overwrite
