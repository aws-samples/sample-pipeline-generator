# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

.EXPORT_ALL_VARIABLES:

# Load an optional .env. Assigning with `?=` rather than `include` is deliberate:
# an included file overrides exported shell variables, which would silently beat
# a caller's own AWS_PROFILE-aligned exports.
_dotenv_key = $(firstword $(subst =, ,$(1)))
ifneq ($(wildcard .env),)
  $(foreach l,$(shell sed -e '/^[[:space:]]*\#/d' -e '/^[[:space:]]*$$/d' -e 's/^export[[:space:]]*//' .env),\
    $(eval $(call _dotenv_key,$(l)) ?= $(patsubst $(call _dotenv_key,$(l))=%,%,$(l))))
endif
export

EXAMPLES_DIR ?= examples
INFRA_MODULES_DIR ?= infra/modules
TESTS_DIR ?= tests

ECR_REGISTRY ?= $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE_TAG ?=
IMAGE_PLATFORM ?= linux/amd64
ENVIRONMENT ?= dev
CONTAINER_RUNTIME ?= docker
PLAN_FILE = local-plan.tfplan

# Pin build tooling so `setup` / `checkov-check` are reproducible in CI
# and a compromised upstream release cannot slip in via a fresh install.
# CHECKOV_VERSION must be recent enough that its `rustworkx` dependency
# ships prebuilt wheels for the local Python (3.13 needs checkov >= 3.2.480
# roughly; older pins force a from-source rustworkx build and require Rust).
POETRY_VERSION ?= 1.8.3
CHECKOV_VERSION ?= 3.2.510
PIP_VERSION ?= 24.2
PRE_COMMIT_VERSION ?= 4.0.1

# One venv per tool: poetry and checkov pin conflicting `packaging` versions and
# corrupt each other when installed together.
TOOLS_VENV ?= .venv-tools
TOOLS_BIN = $(TOOLS_VENV)/bin
CHECKOV_VENV ?= .venv-checkov
CHECKOV_BIN = $(CHECKOV_VENV)/bin

# Only the AWS-facing targets need these; guarding here instead of with
# `$(error)` at assignment keeps `help` and the local test targets usable
# without credentials.
_REQUIRE_AWS_ENV = \
	if [ -z "$(AWS_ACCOUNT_ID)" ]; then echo "ERROR: Set AWS_ACCOUNT_ID in .env or environment"; exit 1; fi; \
	if [ -z "$(AWS_REGION)" ]; then echo "ERROR: Set AWS_REGION in .env or environment"; exit 1; fi

# --- Derived Variables (require DIR) ---
# DIR format for code targets: <pipeline>/<step> or <pipeline>/code/<step>
# DEPLOYMENT format for infra targets: <pipeline> (e.g., my-pipeline)
# Resource naming convention (matches OpenTofu): <pipeline>-<environment>-<step>
ifneq ($(MAKECMDGOALS),help)
  ifdef DIR
    # Normalize: strip '/code/' segment so my-pipeline/code/simple_step -> my-pipeline/simple_step
    NORMALIZED_DIR := $(subst /code/,/,$(DIR))
    DEPLOYMENT := $(firstword $(subst /, ,$(NORMALIZED_DIR)))
    STEP := $(lastword $(subst /, ,$(NORMALIZED_DIR)))
    REPO_NAME := $(DEPLOYMENT)-$(ENVIRONMENT)-$(STEP)
    IMAGE_NAME = $(ECR_REGISTRY)/$(REPO_NAME)
    # Resolve IMAGE_TAG from pyproject.toml if not explicitly provided
    ifeq ($(IMAGE_TAG),)
      IMAGE_TAG := $(shell grep '^version' $(EXAMPLES_DIR)/$(DIR)/pyproject.toml 2>/dev/null | head -1 | sed 's/.*= *"//;s/"//')
    endif
  endif
  ifdef DEPLOYMENT
    # DEPLOYMENT can be set directly for infra targets
  else ifdef DIR
    DEPLOYMENT := $(firstword $(subst /, ,$(DIR)))
  endif
endif

.PHONY: help setup unit-tests build-image push-image push-image-local check-image-version update-parameter-store \
        tofu-init tofu-plan checkov-check tofu-apply tofu-destroy \
        build-all-images check-all-image-versions push-all-images-local update-all-parameter-stores deploy-all-images \
        deploy deploy-image \
        tools-venv unit-tests-all integration-tests checkov-install checkov-modules checkov-examples checkov-all \
        pre-commit-checks verify

help: ## Show this help message
	@echo "Build, test, deploy code and infrastructure"
	@echo ""
	@echo "Run every target from the repository root."
	@echo ""
	@echo "Quality gates (no AWS credentials required):"
	@echo "  unit-tests-all          Run pytest for every example step"
	@echo "  checkov-modules         Checkov scan of the platform OpenTofu modules"
	@echo "  pre-commit-checks       Run all pre-commit hooks on all files"
	@echo "  verify                  unit-tests-all + checkov-modules + pre-commit-checks"
	@echo ""
	@echo "Quality gates (AWS credentials required):"
	@echo "  checkov-examples        Checkov scan of every example tofu plan"
	@echo "  checkov-all             checkov-modules + checkov-examples"
	@echo "  integration-tests       Run the tests/integration suite against deployed pipelines"
	@echo ""
	@echo "Code targets (require DIR=<pipeline>/<step>):"
	@echo "  unit-tests              Run pytest on a step"
	@echo "  build-image             Build Docker image"
	@echo "  push-image              Push image to ECR (CI/CD)"
	@echo "  push-image-local        Build and push image locally"
	@echo "  check-image-version     Check if tag exists in ECR"
	@echo "  update-parameter-store  Update SSM with image tag"
	@echo ""
	@echo "Deploy (require DEPLOYMENT=<pipeline>):"
	@echo "  deploy                  Full deploy: infra (plan+checkov+apply) + all images"
	@echo ""
	@echo "Batch targets (require DEPLOYMENT=<pipeline>, operate on all steps with a Dockerfile):"
	@echo "  build-all-images        Build all container images in the deployment"
	@echo "  check-all-image-versions  Check if tags already exist in ECR"
	@echo "  push-all-images-local   Build and push all images locally"
	@echo "  update-all-parameter-stores  Update SSM for all images"
	@echo "  deploy-all-images       Full pipeline: build, check, push, update SSM for all"
	@echo ""
	@echo "Infra targets (require DEPLOYMENT=<pipeline>):"
	@echo "  tofu-init               Initialize OpenTofu"
	@echo "  tofu-plan               Plan OpenTofu changes"
	@echo "  checkov-check           Plan + Checkov security scan"
	@echo "  tofu-apply              Apply OpenTofu changes"
	@echo "  tofu-destroy            Destroy OpenTofu-managed resources"
	@echo ""
	@echo "Variables:"
	@echo "  DIR          <pipeline>/<step> for code targets"
	@echo "  DEPLOYMENT   <pipeline> for infra targets"
	@echo "  ENVIRONMENT  Environment (default: dev)"
	@echo "  IMAGE_TAG    Docker image tag (default: from pyproject.toml)"
	@echo "  SFN_ARN      Step Function ARN for a single integration test"
	@echo "  PIPELINE     Pipeline name to scope integration-tests to one suite"

# --- Code Targets ---

setup:
	python3 -m pip install "poetry==$(POETRY_VERSION)"

unit-tests: setup
	@echo "Run Python unit tests for $(DIR)"
	cd $(EXAMPLES_DIR)/$(DIR) && \
	python3 -m poetry config virtualenvs.create true && poetry install && \
	python3 -m poetry run pytest --cov --cov-fail-under=0 --cov-report=term-missing --cov-report=xml:.reports/coverage.xml

build-image:
	@$(_REQUIRE_AWS_ENV)
	@echo "Build image for $(DIR) in $(IMAGE_NAME):$(IMAGE_TAG)"
	$(CONTAINER_RUNTIME) build --platform $(IMAGE_PLATFORM) -t $(IMAGE_NAME):$(IMAGE_TAG) $(EXAMPLES_DIR)/$(DIR)
	@echo "Retag image $(IMAGE_NAME):$(IMAGE_TAG) to $(IMAGE_NAME):latest"
	$(CONTAINER_RUNTIME) tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest

push-image:
	@$(_REQUIRE_AWS_ENV)
	@echo "Push image $(DIR)"
	$(CONTAINER_RUNTIME) push $(IMAGE_NAME):$(IMAGE_TAG)
	$(CONTAINER_RUNTIME) push $(IMAGE_NAME):latest

push-image-local: build-image
	@echo "Push image $(DIR)"
	aws ecr get-login-password --region $(AWS_REGION) | $(CONTAINER_RUNTIME) login --username AWS --password-stdin $(ECR_REGISTRY)
	$(CONTAINER_RUNTIME) push $(IMAGE_NAME):$(IMAGE_TAG)
	$(CONTAINER_RUNTIME) push $(IMAGE_NAME):latest

check-image-version:
	@$(_REQUIRE_AWS_ENV)
	@echo "Check if tag $(IMAGE_TAG) already exist for image $(DIR)"
	@aws ecr get-login-password --region $(AWS_REGION) | $(CONTAINER_RUNTIME) login --username AWS --password-stdin $(ECR_REGISTRY)
	@if aws ecr describe-images \
		--repository-name $(REPO_NAME) \
		--image-ids imageTag=$(IMAGE_TAG) \
		--region $(AWS_REGION) \
		--output json > /dev/null 2>&1; \
	then \
		echo "✓ Image tag $(IMAGE_TAG) exists in ECR repository $(IMAGE_NAME), update the version in pyproject.toml"; \
		exit 1; \
	else \
		echo "✗ Image tag $(IMAGE_TAG) NOT found in ECR repository $(IMAGE_NAME), well done!"; \
	fi

update-parameter-store:
	@$(_REQUIRE_AWS_ENV)
	@echo "Updating SSM parameter for $(DIR) with tag $(IMAGE_TAG)"
	aws ssm put-parameter --name "/pipelines/$(REPO_NAME)" --value "$(IMAGE_TAG)" --type "String" --overwrite --no-cli-pager

deploy-image: check-image-version push-image-local update-parameter-store
	@echo ""
	@echo "✓ Image $(IMAGE_NAME) with tag $(IMAGE_TAG) deployed successfully"

# --- Infra Targets ---

tofu-init:
	cd $(EXAMPLES_DIR)/$(DEPLOYMENT)/infra && \
	tofu init -backend-config=../env/$(ENVIRONMENT)/backend.tfvars --reconfigure --upgrade

tofu-plan: tofu-init
	@echo "Planning deployment $(DEPLOYMENT)"
	cd $(EXAMPLES_DIR)/$(DEPLOYMENT)/infra && \
	tofu plan --var-file ../env/$(ENVIRONMENT)/inputs.tfvars -out=$(PLAN_FILE) && \
	tofu show -json $(PLAN_FILE) > $(PLAN_FILE).json

checkov-check: tofu-plan checkov-install
	$(CHECKOV_BIN)/checkov --framework terraform_plan --config-file $(EXAMPLES_DIR)/.checkov.yaml \
		--repo-root-for-plan-enrichment $(EXAMPLES_DIR)/$(DEPLOYMENT)/infra \
		-f $(EXAMPLES_DIR)/$(DEPLOYMENT)/infra/$(PLAN_FILE).json

tofu-apply: checkov-check
	@echo "Apply deployment $(DEPLOYMENT)"
	cd $(EXAMPLES_DIR)/$(DEPLOYMENT)/infra && \
	tofu apply $(PLAN_FILE)

tofu-destroy: tofu-init
	@echo "Destroying deployment $(DEPLOYMENT)"
	cd $(EXAMPLES_DIR)/$(DEPLOYMENT)/infra && \
	tofu destroy --var-file ../env/$(ENVIRONMENT)/inputs.tfvars

# --- Batch Image Targets (operate on all steps with a Dockerfile) ---

# Discover all step directories containing a Dockerfile under <DEPLOYMENT>/code/
_DOCKER_STEPS = $(patsubst $(EXAMPLES_DIR)/$(DEPLOYMENT)/code/%/Dockerfile,%,$(wildcard $(EXAMPLES_DIR)/$(DEPLOYMENT)/code/*/Dockerfile))

build-all-images: ## Build all container images in DEPLOYMENT
	@if [ -z "$(DEPLOYMENT)" ]; then echo "ERROR: DEPLOYMENT is required."; exit 1; fi
	@echo "Building all images for $(DEPLOYMENT) [steps: $(_DOCKER_STEPS)]"
	@for step in $(_DOCKER_STEPS); do \
		echo ""; \
		echo "━━━ Building $$step ━━━"; \
		$(MAKE) build-image DIR=$(DEPLOYMENT)/code/$$step; \
	done

check-all-image-versions: ## Check if IMAGE_TAG already exists for all images in DEPLOYMENT
	@if [ -z "$(DEPLOYMENT)" ]; then echo "ERROR: DEPLOYMENT is required."; exit 1; fi
	@echo "Checking image versions for $(DEPLOYMENT) [steps: $(_DOCKER_STEPS)]"
	@for step in $(_DOCKER_STEPS); do \
		echo ""; \
		echo "━━━ Checking $$step ━━━"; \
		$(MAKE) check-image-version DIR=$(DEPLOYMENT)/code/$$step; \
	done

push-all-images-local: ## Build and push all images locally for DEPLOYMENT
	@if [ -z "$(DEPLOYMENT)" ]; then echo "ERROR: DEPLOYMENT is required."; exit 1; fi
	@echo "Pushing all images for $(DEPLOYMENT) [steps: $(_DOCKER_STEPS)]"
	@for step in $(_DOCKER_STEPS); do \
		echo ""; \
		echo "━━━ Pushing $$step ━━━"; \
		$(MAKE) push-image-local DIR=$(DEPLOYMENT)/code/$$step; \
	done

update-all-parameter-stores: ## Update SSM parameter for all images in DEPLOYMENT
	@if [ -z "$(DEPLOYMENT)" ]; then echo "ERROR: DEPLOYMENT is required."; exit 1; fi
	@echo "Updating SSM parameters for $(DEPLOYMENT) [steps: $(_DOCKER_STEPS)]"
	@for step in $(_DOCKER_STEPS); do \
		echo ""; \
		echo "━━━ Updating SSM for $$step ━━━"; \
		$(MAKE) update-parameter-store DIR=$(DEPLOYMENT)/code/$$step; \
	done

deploy-all-images: check-all-image-versions push-all-images-local update-all-parameter-stores ## Full pipeline: check, build, push, update SSM for all images in DEPLOYMENT
	@echo ""
	@echo "✓ All images for $(DEPLOYMENT) deployed successfully"

# --- Full Deploy (infra + images) ---

deploy: tofu-apply deploy-all-images ## Full deploy: infra (plan+checkov+apply) then build, push, and register all images
	@echo ""
	@echo "✓ $(DEPLOYMENT) fully deployed (infra + images)"

# --- Repository-wide Quality Gates ---

tools-venv:
	@test -d $(TOOLS_VENV) || python3 -m venv $(TOOLS_VENV)
	@$(TOOLS_BIN)/python -m pip install --quiet --upgrade "pip==$(PIP_VERSION)"

# Scoped to git-tracked pipelines so scratch directories like the gitignored
# my-new-pipeline cannot change what the quality gates cover.
_TRACKED_EXAMPLES = $(sort $(shell git ls-files $(EXAMPLES_DIR) 2>/dev/null | cut -d/ -f2 | grep -v '\.'))

# Steps carrying a pyproject.toml resolve dependencies through Poetry; the rest
# run against the tools venv.
_TESTABLE_STEPS = $(sort $(patsubst %/tests,%,$(wildcard $(foreach e,$(_TRACKED_EXAMPLES),$(EXAMPLES_DIR)/$(e)/code/*/tests))))

unit-tests-all: tools-venv ## Run pytest for every example step
	@$(TOOLS_BIN)/python -m pip install --quiet "poetry==$(POETRY_VERSION)" \
		-r requirements.txt
	@failed=""; \
	for step in $(_TESTABLE_STEPS); do \
		echo ""; \
		echo "━━━ Testing $$step ━━━"; \
		if [ -f "$$step/pyproject.toml" ]; then \
			( cd $$step && $(CURDIR)/$(TOOLS_BIN)/poetry config virtualenvs.create true --local >/dev/null && \
			  $(CURDIR)/$(TOOLS_BIN)/poetry install --quiet && \
			  $(CURDIR)/$(TOOLS_BIN)/poetry run pytest -q --cov --cov-fail-under=0 --cov-report=term-missing ) \
				|| failed="$$failed $$step"; \
		else \
			( cd $$step && $(CURDIR)/$(TOOLS_BIN)/pytest -q ) || failed="$$failed $$step"; \
		fi; \
	done; \
	echo ""; \
	if [ -n "$$failed" ]; then echo "✗ Failing steps:$$failed"; exit 1; fi; \
	echo "✓ All example step unit tests passed"

# One suite per pipeline, each needing its own deployed state machine ARN.
_INTEGRATION_SUITES = end-to-end s3-parallel-first s3-parallel-middle s3-parallel-from-step

integration-tests: tools-venv ## Run the integration suite against deployed pipelines
	@$(_REQUIRE_AWS_ENV)
	@$(TOOLS_BIN)/python -m pip install --quiet -r $(TESTS_DIR)/requirements.txt
	@if [ -n "$(SFN_ARN)" ] && [ -z "$(PIPELINE)" ]; then \
		echo "ERROR: SFN_ARN requires PIPELINE=<name> so the matching suite can be selected."; exit 1; \
	fi
	@suites="$(if $(PIPELINE),$(PIPELINE),$(_INTEGRATION_SUITES))"; \
	failed=""; \
	for suite in $$suites; do \
		test_file="$(TESTS_DIR)/integration/test_$$(echo $$suite | tr '-' '_')_pipeline.py"; \
		if [ ! -f "$$test_file" ]; then echo "ERROR: no suite for '$$suite' at $$test_file"; exit 1; fi; \
		if [ -n "$(SFN_ARN)" ]; then arn="$(SFN_ARN)"; else arn="arn:aws:states:$(AWS_REGION):$(AWS_ACCOUNT_ID):stateMachine:$$suite-$(ENVIRONMENT)"; fi; \
		echo ""; \
		echo "━━━ Integration test: $$suite ($$arn) ━━━"; \
		$(TOOLS_BIN)/pytest $$test_file --sfn-arn="$$arn" -v -s --log-cli-level=INFO \
			|| failed="$$failed $$suite"; \
	done; \
	echo ""; \
	if [ -n "$$failed" ]; then echo "✗ Failing integration suites:$$failed"; exit 1; fi; \
	echo "✓ All integration suites passed"

checkov-install:
	@test -d $(CHECKOV_VENV) || python3 -m venv $(CHECKOV_VENV)
	@$(CHECKOV_BIN)/python -m pip install --quiet --upgrade "pip==$(PIP_VERSION)"
	@$(CHECKOV_BIN)/python -m pip install --quiet "checkov==$(CHECKOV_VERSION)"

checkov-modules: checkov-install ## Checkov scan of the platform OpenTofu modules
	@echo "Scanning $(INFRA_MODULES_DIR) and infra/deployments with Checkov"
	$(CHECKOV_BIN)/checkov -d $(INFRA_MODULES_DIR) --framework terraform --config-file .checkov.yaml
	$(CHECKOV_BIN)/checkov -d infra/deployments --framework terraform --config-file .checkov.yaml

# Each example is planned then scanned; a plan needs credentials and a backend.
_CHECKOV_EXAMPLES = $(sort $(patsubst $(EXAMPLES_DIR)/%/infra,%,$(wildcard $(foreach e,$(_TRACKED_EXAMPLES),$(EXAMPLES_DIR)/$(e)/infra))))

checkov-examples: checkov-install ## Plan every example and Checkov-scan the plans
	@$(_REQUIRE_AWS_ENV)
	@failed=""; \
	for example in $(_CHECKOV_EXAMPLES); do \
		echo ""; \
		echo "━━━ Checkov plan scan: $$example ━━━"; \
		$(MAKE) checkov-check DEPLOYMENT=$$example || failed="$$failed $$example"; \
	done; \
	echo ""; \
	if [ -n "$$failed" ]; then echo "✗ Failing example plan scans:$$failed"; exit 1; fi; \
	echo "✓ All example plan scans passed"

checkov-all: checkov-modules checkov-examples ## Checkov over modules and every example plan
	@echo ""
	@echo "✓ Checkov clean across modules and example plans"

pre-commit-checks: tools-venv ## Run all pre-commit hooks on all files
	@$(TOOLS_BIN)/python -m pip install --quiet "pre-commit==$(PRE_COMMIT_VERSION)"
	$(TOOLS_BIN)/pre-commit run --all-files

verify: unit-tests-all checkov-modules pre-commit-checks ## All quality gates that need no AWS credentials
	@echo ""
	@echo "✓ unit tests, Checkov (modules), and pre-commit all passed"
