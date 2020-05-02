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

// GithubPayload is the data payload to send Github
type GithubPayload struct {
	Context     string `json:"context"`
	Description string `json:"description"`
	State       string `json:"state"`
	TargetURL   string `json:"target_url"`
}

// ProcessEvent is triggered by a CloudWatch event rule
func ProcessEvent(ev event) error {

	fmt.Println("test deployment 1")

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

	// Create a new AWS session
	awsSession := session.Must(session.NewSession())

	// Start a new CodePipeline service
	pipeline := codepipeline.New(awsSession)
	res, err := pipeline.GetPipelineExecution(&codepipeline.GetPipelineExecutionInput{
		PipelineExecutionId: aws.String(ev.Detail.ExecutionID),
		PipelineName:        aws.String(ev.Detail.Pipeline),
	})
	if err != nil {
		return err
	} else if res == nil {
		return fmt.Errorf("missing pipeline execution")
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
		return nil
	}

	// Set the commit
	commit := aws.StringValue(sourceArtifact.RevisionId)

	// Parse the revision URL
	var revisionURL *url.URL
	if revisionURL, err = url.Parse(aws.StringValue(sourceArtifact.RevisionUrl)); err != nil {
		return err
	} else if revisionURL == nil {
		return fmt.Errorf("missing %s: %s", sourceArtifactName, "RevisionUrl")
	}

	// Set the status based on the pipeline status
	pipelineStatus := aws.StringValue(res.PipelineExecution.Status)
	var githubStatus string
	switch pipelineStatus {
	case "InProgress":
		githubStatus = "pending"
	case "Succeeded":
		githubStatus = "success"
	default:
		githubStatus = "failure"
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
	if err = json.NewEncoder(&b).Encode(GithubPayload{
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
	client := &http.Client{}
	var response *http.Response
	if response, err = client.Do(req); err != nil {
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

// Start the lambda event handler
func main() {
	lambda.Start(ProcessEvent)
}
