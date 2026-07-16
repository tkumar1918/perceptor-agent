# Perceptor VM agent — convenience wrapper around docker compose.
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## First-time setup (asks for the 3 values, writes .env, starts it)
	@./install.sh

snapshot: ## (Re)install the periodic process-snapshot timer — needs root
	@./install.sh --snapshot-only

up: ## Start (or apply .env / config.alloy changes)
	docker compose up -d

down: ## Stop the agent
	docker compose down

logs: ## Follow the agent logs
	docker compose logs -f agent

status: ## Show container + resource usage
	@docker compose ps
	@docker stats --no-stream perceptor-agent 2>/dev/null || true

update: ## Pull the latest agent version and restart
	git pull --ff-only && docker compose pull && docker compose up -d

.PHONY: help install snapshot up down logs status update
