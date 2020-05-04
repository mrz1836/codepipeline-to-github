# CodePipeline -> Lambda -> Github
> Update a GitHub pull request status via CodePipeline events

[![Go](https://img.shields.io/badge/Go-1.14.xx-blue.svg)](https://golang.org/)
[![Build Status](https://travis-ci.com/mrz1836/lambda-codepipeline-github.svg?branch=master&v=1)](https://travis-ci.com/mrz1836/lambda-codepipeline-github)
[![Report](https://goreportcard.com/badge/github.com/mrz1836/lambda-codepipeline-github?style=flat&v=1)](https://goreportcard.com/report/github.com/mrz1836/lambda-codepipeline-github)
[![codecov](https://codecov.io/gh/mrz1836/lambda-codepipeline-github/branch/master/graph/badge.svg?v=1)](https://codecov.io/gh/mrz1836/lambda-codepipeline-github)
[![Release](https://img.shields.io/github/release-pre/mrz1836/lambda-codepipeline-github.svg?style=flat&v=1)](https://github.com/mrz1836/lambda-codepipeline-github/releases)

## Table of Contents
- [Installation](#installation)
- [Documentation](#documentation)
- [Examples & Tests](#examples--tests)
- [Code Standards](#code-standards)
- [Maintainers](#maintainers)
- [Contributing](#contributing)
- [License](#license)

## Installation

#### Prerequisites
- [An AWS account](https://aws.amazon.com/)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/installing.html)
- [Golang](https://golang.org/doc/install)
- [Docker](https://docs.docker.com/install)
- [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install-mac.html)


**1)** Clone or [go get](https://golang.org/doc/articles/go_command.html) the files locally
```shell script
go get github.com/mrz1818/lambda-codeship-github/...
cd $GOPATH/src/github.com/mrz1818/lambda-codeship-github
```

**2)** Test your local installation (executes the [`status`](status/status.go) function)
```shell script
make run-status
```   

### Deployment & Hosting
This repository has CI integration using [AWS CodePipeline](https://aws.amazon.com/codepipeline/).

Deploying to the `master` branch will automatically sync the code to [AWS Lambda](https://aws.amazon.com/lambda/).

Any changes to the environment via the [AWS CloudFormation template](application.yaml) will be applied.

The actual build process can be found in the [buildspec.yml](buildspec.yml) file.

<details>
<summary><strong><code>Create New Hosting Environment (AWS)</code></strong></summary>

This will create a new [AWS CloudFormation](https://aws.amazon.com/cloudformation/) stack with:
- (1) [Lambda](https://aws.amazon.com/lambda/) Function(s)
- (1) [CloudWatch Event Rule](https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/Create-CloudWatch-Events-Rule.html) to subscribe to Pipeline events
- (1) [CloudWatch LogGroups](https://aws.amazon.com/cloudwatch/) for Lambda Function(s)
- (1) [CodePipeline](https://aws.amazon.com/codepipeline/) with multiple stages to deploy the application from Github
- (1) [CodePipeline Webhook](https://aws.amazon.com/codepipeline/) to receive Github notifications from a specific `branch:name`
- (1) [CodeBuild Project(s)](https://docs.aws.amazon.com/codebuild/latest/userguide/create-project.html) to test, build and deploy the app
- (2) [Service Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-service.html) for working with CodeBuild and CodePipeline

**NOTE:** Requires an existing S3 bucket for artifacts and sam-cli deployments (located in the [Makefile](Makefile))

**1)** Add your Github token to [SSM](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)
```shell script
make save-token token=YOUR_TOKEN
```

**2)** One command will build, test, package and deploy the application to AWS. 
After initial deployment, updating the function is as simple as committing to Github.
```shell script
make deploy
``` 

If you make any adjustments to the command above, update the [buildspec](buildspec.yml) file accordingly.  
</details>

<details>
<summary><strong><code>Tear Down Hosting Environment (AWS)</code></strong></summary>

Remove the Stack(s)
```shell script
make teardown
```   
</details>

<details>
<summary><strong><code>Lambda Logging</code></strong></summary>

View all the logs in [AWS CloudWatch](https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups) via log groups:
```text
/aws/lambda/<app_name>-<stage_name>-<function_name>
```
</details>

## Documentation
You can view the generated [documentation here](https://pkg.go.dev/github.com/mrz1836/lambda-codepipeline-github?tab=subdirectories).

Run the status function with different [events](events)
```shell script
make run-status event=failed
``` 

<details>
<summary><strong><code>Library Deployment</code></strong></summary>

[goreleaser](https://github.com/goreleaser/goreleaser) for easy binary or library deployment to Github and can be installed via: `brew install goreleaser`.

The [.goreleaser.yml](.goreleaser.yml) file is used to configure [goreleaser](https://github.com/goreleaser/goreleaser).

Use `make release-snap` to create a snapshot version of the release, and finally `make release` to ship to production.
</details>

<details>
<summary><strong><code>Makefile Commands</code></strong></summary>

View all `makefile` commands
```shell script
make help
```

List of all current commands:
```text
all                            Run multiple pre-configured commands at once
bench                          Run all benchmarks in the Go application
build                          Build the lambda function as a compiled application
clean                          Remove previous builds and any test cache data
clean-mods                     Remove all the Go mod cache
coverage                       Shows the test coverage
deploy                         Build, prepare and deploy
godocs                         Sync the latest tag with GoDocs
help                           Show all commands available
lambda                         Build a compiled version to deploy to Lambda
lint                           Run the Go lint application
package                        Process the CF template and prepare for deployment
release                        Full production release (creates release in Github)
release-test                   Full production test release (everything except deploy)
release-snap                   Test the full release (build binaries)
run-status                     Fires the lambda function (IE: run-status event=started)
save-token                     Saves the token to the parameter store (IE: save-token token=YOUR_TOKEN)
tag                            Generate a new tag and push (IE: tag version=0.0.0)
tag-remove                     Remove a tag if found (IE: tag-remove version=0.0.0)
tag-update                     Update an existing tag to current commit (IE: tag-update version=0.0.0)
teardown                       Deletes the entire stack
test                           Runs vet, lint and ALL tests
test-short                     Runs vet, lint and tests (excludes integration tests)
update                         Update all project dependencies
update-releaser                Update the goreleaser application
vet                            Run the Go vet application
```
</details>

## Examples & Tests
All unit tests run via [Travis CI](https://travis-ci.org/mrz1836/lambda-codepipeline-github) and uses [Go version 1.14.x](https://golang.org/doc/go1.14). View the [deployment configuration file](.travis.yml).

Run all tests (including integration tests)
```shell script
make test
```

## Code Standards
Read more about this Go project's [code standards](CODE_STANDARDS.md).

## Maintainers

| [<img src="https://github.com/mrz1836.png" height="50" alt="MrZ" />](https://github.com/mrz1836) |
|:---:|
| [MrZ](https://github.com/mrz1836) |

## Contributing

View the [contributing guidelines](CONTRIBUTING.md) and follow the [code of conduct](CODE_OF_CONDUCT.md).

Support the development of this project 🙏

[![Donate](https://img.shields.io/badge/donate-bitcoin-brightgreen.svg)](https://mrz1818.com/?tab=tips&af=lambda-codepipeline-github)

### Credits
This application would not be possible without the work provided in these repositories: 
- [CPLiakas's SAM Golang Example](https://github.com/cpliakas/aws-sam-golang-example) 
- [InfoPark's Github Status](https://github.com/infopark/lambda-codepipeline-github-status)
- [Jenseickmeyer's Commit Status Bot](https://github.com/jenseickmeyer/github-commit-status-bot) 
- [Rowanu's SAM Golang Starter](https://github.com/rowanu/sam-golang-starter) 

## License

![License](https://img.shields.io/github/license/mrz1836/lambda-codepipeline-github.svg?style=flat&v=1)
