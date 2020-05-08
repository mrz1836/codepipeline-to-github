## Stage or environment for the application
ifndef STAGE_NAME
override STAGE_NAME=production
endif

## Tags for the application in AWS
ifndef AWS_TAGS
override AWS_TAGS="Stage=$(STAGE_NAME) Product=integration"
endif

## Default S3 bucket (already exists) to store distribution files
ifndef S3_BUCKET
override S3_BUCKET=cloudformation-distribution-raw-files
endif

## Cloud formation stack name
ifndef STACK_NAME
override STACK_NAME=codepipeline-to-github
endif

## S3 prefix to store the distribution files
ifndef S3_PREFIX
override S3_PREFIX=$(STACK_NAME)
endif

## Default region for the application
ifndef AWS_REGION
override AWS_REGION=us-east-1
endif

## CloudFormation parameter overrides
ifndef PARAMETER_OVERRIDE
override PARAMETER_OVERRIDE="ApplicationStageName=$(STAGE_NAME) GitHubBranch=master"
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

## Check if we have the application
ifeq ($(shell command -v git),)

## Automatically detect the repo owner and repo name (for local use with Git)
REPO_NAME=$(shell basename `git rev-parse --show-toplevel`)
REPO_OWNER=$(shell git config --get remote.origin.url | sed 's/git@$(GIT_DOMAIN)://g' | sed 's/\/$(REPO_NAME).git//g')

## Set the version (for go docs)
VERSION_SHORT=$(shell git describe --tags --always --abbrev=0)
endif

## Not defined? Use default repo name
ifeq ($(REPO_NAME),)
REPO_NAME=code-pipeline-github
endif

## Not defined? Use default repo owner
ifeq ($(REPO_OWNER),)
REPO_OWNER=mrz1836
endif

## Default branch for webhooks
ifndef REPO_BRANCH
override REPO_BRANCH=master
endif

## Set the distribution folder
ifndef DISTRIBUTIONS_DIR
override DISTRIBUTIONS_DIR=./dist
endif

## Set the release folder
ifndef RELEASES_DIR
override RELEASES_DIR=./releases
endif

.PHONY: test lint clean release lambda deploy

all: test ## Run lint, test and vet

bench:  ## Run all benchmarks in the Go application
	@go test -bench ./... -benchmem -v

build: ## Build the lambda function as a compiled application
	@go build -o releases/$(STATUS_BINARY)/$(STATUS_BINARY) .

clean: ## Remove previous builds and any test cache data
	@go clean -cache -testcache -i -r
	@if [ -d $(DISTRIBUTIONS_DIR) ]; then rm -r $(DISTRIBUTIONS_DIR); fi
	@if [ -d $(RELEASES_DIR) ]; then rm -r $(RELEASES_DIR); fi

clean-mods: ## Remove all the Go mod cache
	@go clean -modcache

coverage: ## Shows the test coverage
	@go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out

deploy: ## Build, prepare and deploy
	@$(MAKE) package
	@sam deploy \
        --template-file $(TEMPLATE_PACKAGED) \
        --stack-name $(STACK_NAME)  \
        --region $(AWS_REGION) \
        --parameter-overrides ApplicationName=$(STACK_NAME) \
        ApplicationStageName=$(STAGE_NAME) \
        ApplicationBucket=$(S3_BUCKET) \
        GitHubOwner=$(REPO_OWNER) \
        GitHubRepo=$(REPO_NAME) \
        GitHubBranch=$(REPO_BRANCH) \
        ApplicationEnvironmentEncryptionKeyID=/$(STAGE_NAME)/global/kms_key_id \
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
	@if [ "$(shell command -v golint)" = "" ]; then go get -u golang.org/x/lint/golint; fi
	@golint

package: ## Process the CF template and prepare for deployment
	@$(MAKE) lambda
	@sam package \
        --template-file $(TEMPLATE_RAW)  \
        --output-template-file $(TEMPLATE_PACKAGED) \
        --s3-bucket $(S3_BUCKET) \
        --s3-prefix $(S3_PREFIX) \
        --region $(AWS_REGION);

release: ## Full production release (creates release in Github)
	@goreleaser --rm-dist
	@$(MAKE) godocs

release-test: ## Full production test release (everything except deploy)
	@goreleaser --skip-publish --rm-dist

release-snap: ## Test the full release (build binaries)
	@goreleaser --snapshot --skip-publish --rm-dist

run: ## Fires the lambda function (IE: run event=started)
	@$(MAKE) lambda
	@if [ "$(event)" == "" ]; then echo $(eval event += started); fi
	@sam local invoke StatusFunction --force-image-build -e events/$(event)-event.json --template $(TEMPLATE_RAW)

save-param: ## Saves a parameter in SSM
	# Example: save-param param_name='test' param_value='This is a test'
	@test "$(param_value)"
	@test "$(param_name)"
	@aws ssm put-parameter --name "$(param_name)" --value "$(param_value)" --type String --overwrite

save-param-encrypted: ## Saves an encrypted value as a parameter in SSM
	# Example: save-param-encrypted param_name='test' param_value='This is a test' kms_key_id=b329...
	@test "$(param_value)"
	@test "$(param_name)"
	@test $(kms_key_id)
	@aws ssm put-parameter \
       --type String  \
       --overwrite  \
       --name "$(param_name)" \
       --value $(shell aws kms encrypt  \
                  --output text \
                  --query CiphertextBlob \
                  --key-id $(kms_key_id) \
                  --plaintext "$(param_value)") \

create-secret: ## Creates an secret into AWS SecretsManager
	# Example: create-secret name='production/test' description='This is a test' secret_value='{\"Key\":\"my_key\",\"Another\":\"value\"}' kms_key_id=b329...
	@test "$(name)"
	@test "$(description)"
	@test "$(secret_value)"
	@test $(kms_key_id)
	@aws secretsmanager create-secret \
		--name "$(name)" \
		--description "$(description)" \
		--kms-key-id $(kms_key_id) \
		--secret-string "$(secret_value)" \

update-secret: ## Updates an existing secret in AWS SecretsManager
	# Example: update-secret name='production/test' secret_value='{\"Key\":\"my_key\",\"Another\":\"value\"}'
	@test "$(name)"
	@test "$(secret_value)"
	aws secretsmanager update-secret \
		--secret-id "$(name)" \
		--secret-string "$(secret_value)" \

save-token: ## Helper for saving a new Github token to Secrets Manager
	# Example: save-token token=12345... kms_key_id=b329... STAGE_NAME=production
	@test $(token)
	@test $(kms_key_id)
	@$(MAKE) create-secret \
          name=$(STAGE_NAME)/github \
          description='Github access token for status updates' \
          secret_value="{\"status_personal_token\":\"$(token)\"}" \
          kms_key_id=$(kms_key_id)  \

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
	@test $(STACK_NAME)
	@aws cloudformation delete-stack --stack-name $(STACK_NAME)

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

update-releaser:  ## Update the goreleaser application
	@brew update
	@brew upgrade goreleaser

vet: ## Run the Go vet application
	@go vet -v ./...