.PHONY: test lint

bench:  ## Run all benchmarks in the Go application
	@go test -bench ./... -benchmem -v

clean-mods: ## Remove all the Go mod cache
	@go clean -modcache

coverage: ## Shows the test coverage
	@go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out

godocs: ## Sync the latest tag with GoDocs
	@test $(GIT_DOMAIN)
	@test $(REPO_OWNER)
	@test $(REPO_NAME)
	@test $(VERSION_SHORT)
	@curl https://proxy.golang.org/$(GIT_DOMAIN)/$(REPO_OWNER)/$(REPO_NAME)/@v/$(VERSION_SHORT).info

lint: ## Run the Go lint application
	@if [ "$(shell command -v golint)" = "" ]; then go get -u golang.org/x/lint/golint; fi
	@golint

test: ## Runs vet, lint and ALL tests
	@$(MAKE) vet
	@$(MAKE) lint
	@go test ./... -v

test-short: ## Runs vet, lint and tests (excludes integration tests)
	@$(MAKE) vet
	@$(MAKE) lint
	@go test ./... -v -test.short

test-travis: ## Runs tests via Travis (also exports coverage)
	@$(MAKE) vet
	@$(MAKE) lint
	@go test ./... -race -coverprofile=coverage.txt -covermode=atomic

update:  ## Update all project dependencies
	@go get -u ./... && go mod tidy

vet: ## Run the Go vet application
	@go vet -v ./...