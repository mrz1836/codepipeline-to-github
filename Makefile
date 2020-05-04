## Tags for the application in AWS
ifndef AWS_TAGS
override AWS_TAGS="Stage=production Product=integration"
endif

## Default S3 bucket (already exists) to store distribution files
ifndef S3_BUCKET
override S3_BUCKET=cloudformation-distribution-raw-files
endif

## Default region for the application
ifndef AWS_REGION
override AWS_REGION=us-east-1
endif

## Raw cloud formation template for the application
ifndef TEMPLATE_RAW
override TEMPLATE_RAW=application.yaml
endif

## Packaged cloud formation template
ifndef TEMPLATE_PACKAGED
override TEMPLATE_PACKAGED=packaged.yaml
endif

## Function: status (binary name)
ifndef STATUS_BINARY
override STATUS_BINARY=status
endif

## Package directory name
ifndef PACKAGE_NAME
override PACKAGE_NAME=status
endif

## Default Repo Domain
GIT_DOMAIN=github.com

## Automatically detect the repo owner and repo name
REPO_NAME=$(shell basename `git rev-parse --show-toplevel`)
REPO_OWNER=$(shell git config --get remote.origin.url | sed 's/git@$(GIT_DOMAIN)://g' | sed 's/\/$(REPO_NAME).git//g')

## Cloud formation stack name
ifndef STACK_NAME
override STACK_NAME=$(REPO_NAME)
endif

## S3 prefix to store the distribution files
ifndef S3_PREFIX
override S3_PREFIX=$(STACK_NAME)
endif

## Set the version (for go docs)
VERSION_SHORT=$(shell git describe --tags --always --abbrev=0)

## Set the distribution folder
ifndef DISTRIBUTIONS_DIR
override DISTRIBUTIONS_DIR=./dist
endif

.PHONY: test lint clean release lambda

all: test ## Run multiple pre-configured commands at once

bench:  ## Run all benchmarks in the Go application
	@cd $(PACKAGE_NAME) && go test -bench ./... -benchmem -v

build: ## Build the lambda function as a compiled application
	@cd $(PACKAGE_NAME) && go build -o ../releases/$(STATUS_BINARY)/$(STATUS_BINARY) status.go

clean: ## Remove previous builds and any test cache data
	@go clean -cache -testcache -i -r
	@rm -f $(TEMPLATE_PACKAGED) status/$(STATUS_BINARY)
	@if [ -d $(DISTRIBUTIONS_DIR) ]; then rm -r $(DISTRIBUTIONS_DIR); fi

clean-mods: ## Remove all the Go mod cache
	@go clean -modcache

coverage: ## Shows the test coverage
	@cd $(PACKAGE_NAME) && go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out

deploy: ## Build, prepare and deploy
	@$(MAKE) package
	@sam deploy \
        --template-file $(TEMPLATE_PACKAGED) \
        --stack-name $(STACK_NAME)  \
        --region $(AWS_REGION) \
        --capabilities "CAPABILITY_IAM" \
        --tags $(AWS_TAGS) \
        --no-fail-on-empty-changeset \
        --no-confirm-changeset

godocs: ## Sync the latest tag with GoDocs
	@curl https://proxy.golang.org/$(GIT_DOMAIN)/$(REPO_OWNER)/$(REPO_NAME)/@v/$(VERSION_SHORT).info

help: ## Show all commands available
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

lambda: ## Build a compiled version to deploy to Lambda
	@$(MAKE) test
	GOOS=linux GOARCH=amd64 $(MAKE) build

lint: ## Run the Go lint application
	@cd $(PACKAGE_NAME) && golint

package: ## Process the CF template and prepare for deployment
	@$(MAKE) lambda
	@sam package \
        --template-file $(TEMPLATE_RAW)  \
        --output-template-file $(TEMPLATE_PACKAGED) \
        --s3-bucket $(S3_BUCKET) \
        --s3-prefix $(S3_PREFIX) \
        --region $(AWS_REGION)

release: ## Full production release (creates release in Github)
	@goreleaser --rm-dist
	@$(MAKE) godocs

release-test: ## Full production test release (everything except deploy)
	@goreleaser --skip-publish --rm-dist

release-snap: ## Test the full release (build binaries)
	@goreleaser --snapshot --skip-publish --rm-dist

run-status: ## Fires the lambda function (IE: run-status event=started)
	@$(MAKE) lambda
	if [ "$(event)" == "" ]; then \
  		@echo $(eval event += started); \
	fi
	@sam local invoke StatusFunction --force-image-build -e status/events/$(event)-event.json --template $(TEMPLATE_RAW)

save-token: ## Saves the token to the parameter store (IE: save-token token=YOUR_TOKEN)
	@test $(token)
	@aws ssm put-parameter --name /github/personal_access_token --value $(token) --type String

tag: ## Generate a new tag and push (IE: tag version=0.0.0)
	@test $(version)
	@git tag -a v$(version) -m "Pending full release..."
	@git push origin v$(version)
	@git fetch --tags -f

tag-remove: ## Remove a tag if found (IE: tag-remove version=0.0.0)
	@test $(version)
	@git tag -d v$(version)
	@git push --delete origin v$(version)
	@git fetch --tags

tag-update: ## Update an existing tag to current commit (IE: tag-update version=0.0.0)
	@test $(version)
	@git push --force origin HEAD:refs/tags/v$(version)
	@git fetch --tags -f

teardown: ## Deletes the entire stack
	@aws cloudformation delete-stack --stack-name $(STACK_NAME)

test: ## Runs vet, lint and ALL tests
	@$(MAKE) vet
	@$(MAKE) lint
	@cd $(PACKAGE_NAME) && go test ./... -v

test-short: ## Runs vet, lint and tests (excludes integration tests)
	@$(MAKE) vet
	@$(MAKE) lint
	@cd $(PACKAGE_NAME) && go test ./... -v -test.short

update:  ## Update all project dependencies
	@cd $(PACKAGE_NAME) && go get -u ./... && go mod tidy

update-releaser:  ## Update the goreleaser application
	@brew update
	@brew upgrade goreleaser

vet: ## Run the Go vet application
	@cd $(PACKAGE_NAME) && go vet -v ./...