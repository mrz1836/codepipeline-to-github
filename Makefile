## Set the binary name
CUSTOM_BINARY_NAME := status

# Common makefile commands & variables between projects
include .make/common.mk

# Common Golang makefile commands & variables between projects
include .make/go.mk

# Common aws commands & variables between projects
include .make/aws.mk

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
	override APPLICATION_STACK_NAME=$(subst _,-,"$(APPLICATION_NAME)-$(APPLICATION_STAGE_NAME)")
endif

## Application feature name (if it's a feature branch of a stage) (feature="some-feature")
ifdef APPLICATION_FEATURE_NAME
	override APPLICATION_STACK_NAME=$(subst _,-,"$(APPLICATION_NAME)-$(APPLICATION_STAGE_NAME)-$(APPLICATION_FEATURE_NAME)")
endif

## S3 prefix to store the distribution files
ifndef APPLICATION_BUCKET_PREFIX
	override APPLICATION_BUCKET_PREFIX=$(APPLICATION_STACK_NAME)
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

## Set the release folder
ifndef RELEASES_DIR
	override RELEASES_DIR=./releases
endif

## Package directory name
ifndef PACKAGE_NAME
	override PACKAGE_NAME=$(BINARY_NAME)
endif

## Set the local environment variables when using "run"
ifndef LOCAL_ENV_FILE
	override LOCAL_ENV_FILE=local-env.json
endif

.PHONY: clean lambda deploy

build: ## Build the lambda function as a compiled application
	@go build -o $(RELEASES_DIR)/$(PACKAGE_NAME)/$(BINARY_NAME) .

clean: ## Remove previous builds, test cache, and packaged releases
	@go clean -cache -testcache -i -r
	@if [ -d $(DISTRIBUTIONS_DIR) ]; then rm -r $(DISTRIBUTIONS_DIR); fi
	@if [ -d $(RELEASES_DIR) ]; then rm -r $(RELEASES_DIR); fi
	@rm -rf $(TEMPLATE_PACKAGED)

deploy: ## Build, prepare and deploy
	@$(MAKE) lambda
	@$(MAKE) package
	@SAM_CLI_TELEMETRY=0 sam deploy \
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
        EncryptionKeyId="$(shell $(MAKE) env-key-location \
				app=$(APPLICATION_NAME) \
				stage=$(APPLICATION_STAGE_NAME))" \
        --capabilities $(IAM_CAPABILITIES) \
        --tags $(AWS_TAGS) \
        --no-fail-on-empty-changeset \
        --no-confirm-changeset

lambda: ## Build a compiled version to deploy to Lambda
	@$(MAKE) test
	GOOS=linux GOARCH=amd64 $(MAKE) build

release:: ## Runs common.release and then runs godocs
	@$(MAKE) godocs

run: ## Fires the lambda function (run event=started)
	@$(MAKE) lambda
	@if [ "$(event)" = "" ]; then echo $(eval event += started); fi
	@SAM_CLI_TELEMETRY=0 sam local invoke StatusFunction \
		--force-image-build \
		-e events/$(event)-event.json \
		--template $(TEMPLATE_RAW) \
		--env-vars $(LOCAL_ENV_FILE)

save-secrets: ## Helper for saving Github token(s) to Secrets Manager (extendable for more secrets)
	@# Example: make save-secrets github_token=12345... kms_key_id=b329... stage=<stage>
	@test $(github_token)
	@test $(kms_key_id)
	@$(eval github_token_encrypted := $(shell $(MAKE) encrypt kms_key_id=$(kms_key_id) encrypt_value="$(github_token)"))
	@$(eval secret_value := $(shell echo '{' \
		'\"github_personal_token\":\"$(github_token)\"' \
		',\"github_personal_token_encrypted\":\"$(github_token_encrypted)\"' \
		'}'))
	@$(eval existing_secret := $(shell aws secretsmanager describe-secret --secret-id "$(APPLICATION_STAGE_NAME)/$(APPLICATION_NAME)" --output text))
	@if [ '$(existing_secret)' = "" ]; then\
		echo "Creating a new secret..."; \
		$(MAKE) create-secret \
			name="$(APPLICATION_STAGE_NAME)/$(APPLICATION_NAME)" \
			description="Sensitive credentials for $(APPLICATION_NAME):$(APPLICATION_STAGE_NAME)" \
			secret_value='$(secret_value)' \
			kms_key_id=$(kms_key_id);  \
	else\
		echo "Updating an existing secret..."; \
		$(MAKE) update-secret \
            name="$(APPLICATION_STAGE_NAME)/$(APPLICATION_NAME)" \
        	secret_value='$(secret_value)'; \
	fi