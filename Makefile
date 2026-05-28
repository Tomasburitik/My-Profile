.DEFAULT_GOAL := help
SHELL := /bin/bash
PYTHON := python3.11
VENV := .venv

# ─── Colors ──────────────────────────────────────────────
BOLD  := \033[1m
GREEN := \033[32m
BLUE  := \033[34m
RESET := \033[0m

# ─── Help ────────────────────────────────────────────────
.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "  $(BOLD)NeuroClaim — Development Commands$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─── Setup ───────────────────────────────────────────────
.PHONY: install
install: ## Create venv and install all dependencies
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -e ".[dev,eval]"
	$(VENV)/bin/pre-commit install
	@echo "$(GREEN)✓ Installation complete$(RESET)"

.PHONY: install-prod
install-prod: ## Install production dependencies only
	pip install -e "."

# ─── Code Quality ────────────────────────────────────────
.PHONY: lint
lint: ## Run ruff linter
	$(VENV)/bin/ruff check src/ tests/

.PHONY: lint-fix
lint-fix: ## Run ruff with auto-fix
	$(VENV)/bin/ruff check --fix src/ tests/

.PHONY: format
format: ## Format code with black + isort
	$(VENV)/bin/black src/ tests/
	$(VENV)/bin/isort src/ tests/

.PHONY: typecheck
typecheck: ## Run mypy strict type checking
	$(VENV)/bin/mypy src/ --strict

.PHONY: check
check: lint typecheck ## Run all code quality checks

# ─── Tests ───────────────────────────────────────────────
.PHONY: test
test: ## Run full test suite with coverage
	$(VENV)/bin/pytest tests/ \
		--cov=src \
		--cov-report=term-missing \
		--cov-report=html:htmlcov \
		-v

.PHONY: test-unit
test-unit: ## Run unit tests only (fast)
	$(VENV)/bin/pytest tests/unit/ -v -x

.PHONY: test-integration
test-integration: ## Run integration tests (requires services)
	$(VENV)/bin/pytest tests/integration/ -v --timeout=120

.PHONY: test-behavioral
test-behavioral: ## Run ML behavioral/invariance tests
	$(VENV)/bin/pytest tests/behavioral/ -v

.PHONY: test-load
test-load: ## Run load tests with Locust
	$(VENV)/bin/locust -f tests/load/locustfile.py \
		--host=http://localhost:8000 \
		--users=100 \
		--spawn-rate=10 \
		--run-time=60s \
		--headless

# ─── Development ─────────────────────────────────────────
.PHONY: dev
dev: ## Start development stack (API + DB + Qdrant)
	docker compose -f docker/docker-compose.dev.yml up -d
	@echo "$(GREEN)✓ Services started$(RESET)"
	@echo "  API:       http://localhost:8000"
	@echo "  Docs:      http://localhost:8000/docs"
	@echo "  Grafana:   http://localhost:3000"
	@echo "  Qdrant UI: http://localhost:6333/dashboard"

.PHONY: dev-down
dev-down: ## Stop development stack
	docker compose -f docker/docker-compose.dev.yml down

.PHONY: logs
logs: ## Follow API logs
	docker compose -f docker/docker-compose.dev.yml logs -f api

.PHONY: shell
shell: ## Open Python shell with project context
	$(VENV)/bin/ipython -i scripts/shell_context.py

# ─── Database ────────────────────────────────────────────
.PHONY: migrate
migrate: ## Run database migrations
	$(VENV)/bin/alembic upgrade head

.PHONY: migration
migration: ## Create new migration (usage: make migration msg="add claims table")
	$(VENV)/bin/alembic revision --autogenerate -m "$(msg)"

.PHONY: db-reset
db-reset: ## Reset database (DEV only!)
	$(VENV)/bin/alembic downgrade base
	$(VENV)/bin/alembic upgrade head

# ─── Model Operations ────────────────────────────────────
.PHONY: eval
eval: ## Run model evaluation suite
	$(VENV)/bin/python scripts/evaluate.py \
		--config configs/eval.yaml \
		--output reports/eval_latest.json

.PHONY: index
index: ## Index policy documents into Qdrant
	$(VENV)/bin/python scripts/index_documents.py \
		--source data/policies/ \
		--config configs/rag.yaml

.PHONY: benchmark
benchmark: ## Run RAG strategy benchmark
	$(VENV)/bin/python scripts/benchmark_rag.py \
		--strategies bm25,semantic,hybrid,hybrid_rerank \
		--dataset data/eval/rag_benchmark.jsonl

# ─── Docker ──────────────────────────────────────────────
.PHONY: build
build: ## Build production Docker image
	docker build \
		-f docker/Dockerfile \
		-t neuroclaim:$(shell git rev-parse --short HEAD) \
		-t neuroclaim:latest \
		.

.PHONY: run
run: build ## Build and run production container locally
	docker run --rm \
		-p 8000:8000 \
		--env-file .env \
		neuroclaim:latest

# ─── Kubernetes ──────────────────────────────────────────
.PHONY: deploy-staging
deploy-staging: ## Deploy to staging cluster
	helm upgrade --install neuroclaim ./k8s/helm/neuroclaim \
		--namespace staging \
		--set image.tag=$(shell git rev-parse --short HEAD) \
		--values k8s/values/staging.yaml \
		--wait

.PHONY: status
status: ## Show production deployment status
	kubectl get pods -n production -l app=neuroclaim
	kubectl top pods -n production -l app=neuroclaim

# ─── Utilities ───────────────────────────────────────────
.PHONY: clean
clean: ## Remove build artifacts and caches
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
	find . -type d -name "*.egg-info" -exec rm -rf {} +
	rm -rf .pytest_cache .mypy_cache .ruff_cache htmlcov dist build

.PHONY: docs
docs: ## Build and serve documentation locally
	$(VENV)/bin/mkdocs serve

.PHONY: release
release: ## Create a new release (usage: make release v=2.2.0)
	git tag -a v$(v) -m "Release v$(v)"
	git push origin v$(v)
	@echo "$(GREEN)✓ Release v$(v) created$(RESET)"
