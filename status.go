/*
Package main is the CodePipeline status event receiver

More information: https://github.com/mrz1836/codepipeline-to-github
*/
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"strings"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/codepipeline"
	"github.com/aws/aws-sdk-go/service/codepipeline/codepipelineiface"
	"github.com/aws/aws-sdk-go/service/kms"
	"github.com/aws/aws-sdk-go/service/kms/kmsiface"
	"github.com/kelseyhightower/envconfig"
)

// Application defaults
const (
	sourceArtifactName = "SourceCode"
	stageTesting       = "testing"
	stageProduction    = "production"
)

// event is what is emitted by CloudWatch
type event struct {
	Detail    *detail  `json:"detail"`
	Resources []string `json:"resources"`
}

// detail is the custom event information
type detail struct {
	ExecutionID string `json:"execution-id"`
	State       string `json:"state"`
	Pipeline    string `json:"pipeline"`
}

// payload is the data payload to send Github
type payload struct {
	Context     string `json:"context"`
	Description string `json:"description"`
	State       string `json:"state"`
	TargetURL   string `json:"target_url"`
}

// configuration is for the application's configuration settings
type configuration struct {
	AWSRegion         string `required:"true" split_words:"true" envconfig:"AWS_REGION"`
	GithubAccessToken string `required:"true" split_words:"true" envconfig:"GITHUB_ACCESS_TOKEN"`
	Stage             string `required:"true" split_words:"true" envconfig:"APPLICATION_STAGE_NAME"`
}

// Local application variables
var (
	awsSession *session.Session
	config     configuration
)

// ProcessEvent is triggered by a CloudWatch event rule
func ProcessEvent(ev event) error {

	// Check for required parameters
	if ev.Detail != nil {
		fmt.Printf("Incoming Event Details: %+v\n", ev.Detail)
	} else {
		return errors.New("missing param event.detail")
	}
	if len(ev.Detail.ExecutionID) == 0 {
		return errors.New("missing event param execution-id")
	}
	if len(ev.Detail.Pipeline) == 0 {
		return errors.New("missing event param pipeline")
	}

	// Create a new KMS session
	kmsSvc := kms.New(awsSession)

	// Load the configuration
	if err := loadConfiguration(kmsSvc); err != nil {
		return err
	}

	// Start a new CodePipeline service
	pipeline := codepipeline.New(awsSession)

	// Get the commit info from the pipeline execution
	commit, githubStatus, revisionURL, err := getCommit(ev.Detail.Pipeline, ev.Detail.ExecutionID, pipeline)
	if err != nil {
		return err
	} else if revisionURL == nil {
		return errors.New("unable to find the revision url, possibly missing source artifacts")
	}

	// Break apart the components
	parts := strings.Split(revisionURL.Path, "/")
	owner := parts[1]
	repo := parts[2]

	// Setup the links
	deepLink := fmt.Sprintf(
		"https://%s.console.aws.amazon.com/codesuite/codepipeline/pipelines/%s/executions/%s",
		config.AWSRegion, ev.Detail.Pipeline, ev.Detail.ExecutionID)
	githubURL := fmt.Sprintf("https://api.github.com/repos/%s/%s/statuses/%s", owner, repo, commit)

	// Create the Github payload
	var b bytes.Buffer
	if err = json.NewEncoder(&b).Encode(payload{
		Context:   "continuous-integration/codepipeline",
		State:     githubStatus,
		TargetURL: deepLink,
	}); err != nil {
		return err
	}

	// Create the request
	var req *http.Request
	if req, err = http.NewRequest(http.MethodPost, githubURL, &b); err != nil {
		return err
	}

	// Set the headers
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "token "+config.GithubAccessToken)
	req.Header.Set("Content-Type", "application/json; charset=utf-8")

	// Fire the request
	var response *http.Response
	if response, err = http.DefaultClient.Do(req); err != nil {
		return err
	}
	defer func() {
		_ = response.Body.Close()
	}()

	// Check for success
	if response.StatusCode != http.StatusCreated {
		resBody, _ := ioutil.ReadAll(response.Body)
		return fmt.Errorf("unexpected response from GitHub, code: %d body: %s", response.StatusCode, string(resBody))
	}

	return nil
}

// loadConfiguration will decrypt any encrypted variables
func loadConfiguration(kmsSvc kmsiface.KMSAPI) (err error) {

	// Get configuration set using environment variables
	if err = envconfig.Process("", &config); err != nil {
		return
	}

	// Skip KMS on testing stage
	if config.Stage == stageTesting {
		return
	}

	// Update the Token with the decoded value or fail
	config.GithubAccessToken, err = decodeString(kmsSvc, config.GithubAccessToken)
	return
}

// getCommit will get the Github commit and revision url from an execution
func getCommit(pipelineName, executionID string, pipeline codepipelineiface.CodePipelineAPI) (commit, status string, revisionURL *url.URL, err error) {

	// Get the execution details
	var executionOutput *codepipeline.GetPipelineExecutionOutput
	if executionOutput, err = getExecutionOutput(pipelineName, executionID, pipeline); err != nil {
		return
	}

	// Find the source artifacts
	sourceArtifact := getArtifact(executionOutput)

	// No artifact to work with (this occurs if a "Release Change" event is fired)
	if sourceArtifact == nil {
		fmt.Printf("no %s found in execution: %s for pipeline: %s",
			sourceArtifactName, *executionOutput.PipelineExecution.PipelineExecutionId, *executionOutput.PipelineExecution.PipelineName)
		return
	}

	// Set the commit
	commit = aws.StringValue(sourceArtifact.RevisionId)

	// Parse the revision URL
	if revisionURL, err = url.Parse(aws.StringValue(sourceArtifact.RevisionUrl)); err != nil {
		return
	} else if revisionURL == nil {
		err = fmt.Errorf("missing %s: %s", sourceArtifactName, "RevisionUrl")
	}

	// Set the status based on the pipeline status
	switch aws.StringValue(executionOutput.PipelineExecution.Status) {
	case "InProgress":
		status = "pending"
	case "Succeeded":
		status = "success"
	default:
		status = "failure"
	}

	return
}

// decodeString uses AWS Key Management Service (AWS KMS) to decrypt environment variables.
// In order for this method to work, the function needs access to the kms:Decrypt capability.
func decodeString(kmsSvc kmsiface.KMSAPI, encryptedText string) (string, error) {

	// Decode the encryptedText
	sDec, err := base64.StdEncoding.DecodeString(encryptedText)
	if err != nil {
		return "", err
	}

	// Decrypt the decoded text
	var out *kms.DecryptOutput
	if out, err = kmsSvc.Decrypt(&kms.DecryptInput{
		CiphertextBlob: sDec,
	}); err != nil {
		return "", err
	}

	// Return a string with no leading or trailing spaces or carriage returns
	return strings.TrimSpace(strings.TrimSuffix(string(out.Plaintext), "\n")), err
}

// getExecutionOutput will return the output details of the pipeline execution
func getExecutionOutput(pipelineName, executionID string, pipeline codepipelineiface.CodePipelineAPI) (response *codepipeline.GetPipelineExecutionOutput, err error) {
	if response, err = pipeline.GetPipelineExecution(&codepipeline.GetPipelineExecutionInput{
		PipelineExecutionId: aws.String(executionID),
		PipelineName:        aws.String(pipelineName),
	}); err != nil {
		return
	} else if response == nil {
		err = fmt.Errorf("missing pipeline execution")
	}
	return
}

// getArtifact will get the artifact from a given output
func getArtifact(executionOutput *codepipeline.GetPipelineExecutionOutput) (sourceArtifact *codepipeline.ArtifactRevision) {
	for _, artifact := range executionOutput.PipelineExecution.ArtifactRevisions {
		if aws.StringValue(artifact.Name) == sourceArtifactName {
			sourceArtifact = artifact
			break
		}
	}
	return
}

// Start the lambda event handler
func main() {
	// Create a new AWS session
	if awsSession == nil {
		awsSession = session.Must(session.NewSession(&aws.Config{
			Region: aws.String(config.AWSRegion),
		}))
	}

	// Start lambda
	lambda.Start(ProcessEvent)
}
