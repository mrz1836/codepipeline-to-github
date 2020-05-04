/*
Package main is the CodePipeline status event receiver
*/
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/codepipeline"
)

// Application defaults
const (
	region             = "us-east-1"
	sourceArtifactName = "SourceCode"
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

	// Set the Github Token
	githubToken := os.Getenv("GITHUB_ACCESS_TOKEN")
	if len(githubToken) == 0 {
		return errors.New("missing or invalid Github token")
	}

	// Get the commit info from the pipeline execution
	commit, githubStatus, revisionURL, err := getCommit(ev.Detail.Pipeline, ev.Detail.ExecutionID)
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
		region, ev.Detail.Pipeline, ev.Detail.ExecutionID)
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
	req.Header.Set("Authorization", "token "+githubToken)
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

// getCommit will get the Github commit and revision url from an execution
func getCommit(pipelineName, executionID string) (commit, status string, revisionURL *url.URL, err error) {

	// Create a new AWS session
	awsSession := session.Must(session.NewSession())

	// Start a new CodePipeline service
	pipeline := codepipeline.New(awsSession)

	// Get the execution details
	var res *codepipeline.GetPipelineExecutionOutput
	if res, err = pipeline.GetPipelineExecution(&codepipeline.GetPipelineExecutionInput{
		PipelineExecutionId: aws.String(executionID),
		PipelineName:        aws.String(pipelineName),
	}); err != nil {
		return
	} else if res == nil {
		err = fmt.Errorf("missing pipeline execution")
		return
	}

	// Find the source artifacts
	var sourceArtifact *codepipeline.ArtifactRevision
	for _, artifact := range res.PipelineExecution.ArtifactRevisions {
		if aws.StringValue(artifact.Name) == sourceArtifactName {
			sourceArtifact = artifact
			break
		}
	}

	// No artifact to work with (this occurs if a "Release Change" event is fired)
	if sourceArtifact == nil {
		fmt.Printf("no %s found in execution: %s for pipeline: %s",
			sourceArtifactName, *res.PipelineExecution.PipelineExecutionId, *res.PipelineExecution.PipelineName)
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
	switch aws.StringValue(res.PipelineExecution.Status) {
	case "InProgress":
		status = "pending"
	case "Succeeded":
		status = "success"
	default:
		status = "failure"
	}

	return
}

// Start the lambda event handler
func main() {
	lambda.Start(ProcessEvent)
}
