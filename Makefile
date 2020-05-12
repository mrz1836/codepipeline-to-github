## Stage or environment for the application
ifndef APPLICATION_STAGE_NAME
	override APPLICATION_STAGE_NAME="production"
endif

## Tags for the application in AWS
ifndef AWS_TAGS
	override AWS_TAGS="Stage=$(APPLICATION_STAGE_NAME) Product=integration"
endif

## Default S3 bucket (already exists) to store distribution files
ifndef APPLICATION_BUCKET
	override APPLICATION_BUCKET="cloudformation-distribution-raw-files"
endif

## Application name (the name of the application, lowercase, no spaces)
ifndef APPLICATION_NAME
	override APPLICATION_NAME="codepipeline-to-github"
endif

## Cloud formation stack name (combines the app name with the stage for unique stacks)
ifndef APPLICATION_STACK_NAME
	override APPLICATION_STACK_NAME="$(APPLICATION_NAME)-$(APPLICATION_STAGE_NAME)"
endif

## S3 prefix to store the distribution files
ifndef APPLICATION_BUCKET_PREFIX
	override APPLICATION_BUCKET_PREFIX=$(APPLICATION_STACK_NAME)
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

## Default repository domain name
ifndef GIT_DOMAIN
	override GIT_DOMAIN=github.com
endif

## Do we have git available?
HAS_GIT := $(shell command -v git 2> /dev/null)

ifdef HAS_GIT
	## Do we have a repo?
	HAS_REPO := "$(shell git rev-parse --show-toplevel)"
	ifdef HAS_REPO
		ifeq (,$(findstring "not a git repository",$(HAS_REPO)))
			## Automatically detect the repo owner and repo name (for local use with Git)
			REPO_NAME=$(shell basename "$(HAS_REPO)")
			REPO_OWNER=$(shell git config --get remote.origin.url | sed 's/git@$(GIT_DOMAIN)://g' | sed 's/\/$(REPO_NAME).git//g')
		endif
	endif
endif

## Not defined? Use default repo name which is the application
ifeq ($(REPO_NAME),)
	REPO_NAME=$(APPLICATION_NAME)
endif

## Not defined? Use default repo owner
ifeq ($(REPO_OWNER),)
	REPO_OWNER="mrz1836"
endif

## Default branch for webhooks
ifndef REPO_BRANCH
	override REPO_BRANCH="master"
endif

## Set the distribution folder
ifndef DISTRIBUTIONS_DIR
	override DISTRIBUTIONS_DIR=./dist
endif

## Set the release folder
ifndef RELEASES_DIR
	override RELEASES_DIR=./releases
endif

## Set the local environment variables when using "run"
ifndef LOCAL_ENV_FILE
	override LOCAL_ENV_FILE=local-env.json
endif

## Set capabilities for the sam deploy option
ifndef IAM_CAPABILITIES
	override IAM_CAPABILITIES="CAPABILITY_IAM"
endif

## Set name/location for environment encryption key id
ifndef PARAM_NAME_KMS_KEY_ID
	override PARAM_NAME_KMS_KEY_ID="/$(APPLICATION_NAME)/$(APPLICATION_STAGE_NAME)/kms_key_id"
endif

.PHONY: test lint clean release lambda deploy

all: test ## Run lint, test and vet

bench:  ## Run all benchmarks in the Go application
	@go test -bench ./... -benchmem -v

build: ## Build the lambda function as a compiled application
	@go build -o releases/$(STATUS_BINARY)/$(STATUS_BINARY) .

clean: ## Remove previous builds, test cache, and packaged releases
	@go clean -cache -testcache -i -r
	@if [ -d $(DISTRIBUTIONS_DIR) ]; then rm -r $(DISTRIBUTIONS_DIR); fi
	@if [ -d $(RELEASES_DIR) ]; then rm -r $(RELEASES_DIR); fi
	@rm -rf $(TEMPLATE_PACKAGED)

clean-mods: ## Remove all the Go mod cache
	@go clean -modcache

coverage: ## Shows the test coverage
	@go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out

create-env-key: ## Creates a new key in KMS for a new stage
	@ #Example: make create-env-key description="keys to encrypt environment variables"
	@test $(APPLICATION_STAGE_NAME)
	@$(eval kms_key_id := $(shell aws kms create-key --description "Used to encrypt environment variables for $(APPLICATION_NAME)" --query 'KeyMetadata.KeyId' --output text))
	@aws kms create-alias --alias-name "alias/$(APPLICATION_NAME)/$(APPLICATION_STAGE_NAME)" --target-key-id $(kms_key_id)
	@$(MAKE) save-param param_name="$(PARAM_NAME_KMS_KEY_ID)" param_value=$(kms_key_id)
	@echo "Saved parameter: $(PARAM_NAME_KMS_KEY_ID) with key id: $(kms_key_id)"

create-secret: ## Creates an secret into AWS SecretsManager
	@# Example: make create-secret name='production/test' description='This is a test' secret_value='{\"Key\":\"my_key\",\"Another\":\"value\"}' kms_key_id=b329...
	@test "$(name)"
	@test "$(description)"
	@test "$(secret_value)"
	@test $(kms_key_id)
	@aws secretsmanager create-secret \
		--name "$(name)" \
		--description "$(description)" \
		--kms-key-id $(kms_key_id) \
		--secret-string "$(secret_value)"

decrypt: ## Decrypts data using a KMY Key ID (awscli v2)
	@# Example: make decrypt decrypt_value=AQICAHgrSMx+3O7...
	@test "$(decrypt_value)"
	@aws kms decrypt --ciphertext-blob "$(decrypt_value)" --output text --query Plaintext | base64 --decode

decrypt-deprecated: ## Decrypts data using a KMY Key ID (awscli v1)
	@# Example: make decrypt decrypt_value=AQICAHgrSMx+3O7...
	@test "$(decrypt_value)"
	@echo $(decrypt_value) | base64 --decode >> tempfile
	@aws kms decrypt --ciphertext-blob fileb://tempfile --output text --query Plaintext | base64 --decode
	@rm -rf tempfile

deploy: ## Build, prepare and deploy
	@$(MAKE) package
	@sam deploy \
        --template-file $(TEMPLATE_PACKAGED) \
        --stack-name $(APPLICATION_STACK_NAME)  \
        --region $(AWS_REGION) \
        --parameter-overrides ApplicationName=$(APPLICATION_NAME) \
        ApplicationStackName=$(APPLICATION_STACK_NAME) \
        ApplicationStageName=$(APPLICATION_STAGE_NAME) \
        ApplicationBucket=$(APPLICATION_BUCKET) \
        ApplicationBucketPrefix=$(APPLICATION_BUCKET_PREFIX) \
        RepoOwner=$(REPO_OWNER) \
        RepoName=$(REPO_NAME) \
        RepoBranch=$(REPO_BRANCH) \
        EncryptionKeyId=$(PARAM_NAME_KMS_KEY_ID) \
        --capabilities $(IAM_CAPABILITIES) \
        --tags $(AWS_TAGS) \
        --no-fail-on-empty-changeset \
        --no-confirm-changeset

encrypt: ## Encrypts data using a KMY Key ID (awscli v2)
	@# Example make encrypt kms_key_id=b329... encrypt_value=YourSecret
	@test $(kms_key_id)
	@test "$(encrypt_value)"
	@aws kms encrypt --output text --query CiphertextBlob --key-id $(kms_key_id) --plaintext "$(shell echo "$(encrypt_value)" | base64)"

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
        --s3-bucket $(APPLICATION_BUCKET) \
        --s3-prefix $(APPLICATION_BUCKET_PREFIX) \
        --region $(AWS_REGION)

release: ## Full production release (creates release in Github)
	@goreleaser --rm-dist
	@$(MAKE) godocs

release-test: ## Full production test release (everything except deploy)
	@goreleaser --skip-publish --rm-dist

release-snap: ## Test the full release (build binaries)
	@goreleaser --snapshot --skip-publish --rm-dist

run: ## Fires the lambda function (IE: run event=started)
	@$(MAKE) lambda
	@if [ "$(event)" = "" ]; then echo $(eval event += started); fi
	@sam local invoke StatusFunction \
		--force-image-build \
		-e events/$(event)-event.json \
		--template $(TEMPLATE_RAW) \
		--env-vars $(LOCAL_ENV_FILE)

save-param: ## Saves a plain-text string parameter in SSM
	@# Example: make save-param param_name='test' param_value='This is a test'
	@test "$(param_value)"
	@test "$(param_name)"
	@aws ssm put-parameter --name "$(param_name)" --value "$(param_value)" --type String --overwrite

save-param-encrypted: ## Saves an encrypted string value as a parameter in SSM
	@# Example: make save-param-encrypted param_name='test' param_value='This is a test' kms_key_id=b329...
	@test "$(param_value)"
	@test "$(param_name)"
	@test $(kms_key_id)
	@aws ssm put-parameter \
       --type String  \
       --overwrite  \
       --name "$(param_name)" \
       --value "$(shell $(MAKE) encrypt kms_key_id=$(kms_key_id) encrypt_value="$(param_value)")"

save-secrets: ## Helper for saving Github token(s) to Secrets Manager (extendable for more secrets)
	@# Example: make save-secrets token=12345... kms_key_id=b329... (Optional) APPLICATION_STAGE_NAME=production
	@test $(token)
	@test $(kms_key_id)
	@$(eval existing_secret := $(shell aws secretsmanager describe-secret --secret-id "$(APPLICATION_STAGE_NAME)/$(APPLICATION_NAME)" --output text))
	@$(eval token_encrypted := $(shell $(MAKE) encrypt kms_key_id=$(kms_key_id) encrypt_value="$(token)"))
	@if [ '$(existing_secret)' = "" ]; then\
		echo "Creating a new secret..."; \
		$(MAKE) create-secret \
			name="$(APPLICATION_STAGE_NAME)/$(APPLICATION_NAME)" \
			description="Sensitive credentials for $(APPLICATION_NAME):$(APPLICATION_STAGE_NAME)" \
			secret_value='{\"github_personal_token\":\"$(token)\",\"github_personal_token_encrypted\":\"$(token_encrypted)\"}' \
			kms_key_id=$(kms_key_id);  \
	else\
		echo "Updating an existing secret..."; \
		$(MAKE) update-secret \
            name="$(APPLICATION_STAGE_NAME)/$(APPLICATION_NAME)" \
        	secret_value='{\"github_personal_token\":\"$(token)\",\"github_personal_token_encrypted\":\"$(token_encrypted)\"}'; \
	fi

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
	@test $(APPLICATION_STACK_NAME)
	@aws cloudformation delete-stack --stack-name $(APPLICATION_STACK_NAME)

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

update-secret: ## Updates an existing secret in AWS SecretsManager
	@# Example: make update-secret name='production/test' secret_value='{\"Key\":\"my_key\",\"Another\":\"value\"}'
	@test "$(name)"
	@test "$(secret_value)"
	@aws secretsmanager update-secret \
		--secret-id "$(name)" \
		--secret-string "$(secret_value)"

vet: ## Run the Go vet application
	@go vet -v ./...