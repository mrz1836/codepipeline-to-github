package main

import (
	"fmt"
	"os"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/codepipeline"
	"github.com/aws/aws-sdk-go/service/codepipeline/codepipelineiface"
	"github.com/aws/aws-sdk-go/service/kms"
	"github.com/aws/aws-sdk-go/service/kms/kmsiface"
)

// TestProcessEvent will test the ProcessEvent() method
func TestProcessEvent(t *testing.T) {

	// Create a new AWS session
	if awsSession == nil {
		awsSession = session.Must(session.NewSession(&aws.Config{
			Region: aws.String("us-east-1"),
		}))
	}

	t.Run("missing event detail", func(t *testing.T) {
		if err := ProcessEvent(event{}); err == nil {
			t.Fatal("error failed to trigger with an invalid request")
		}
	})

	t.Run("missing param execution-id", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "",
			}}
		if err := ProcessEvent(ev); err == nil {
			t.Fatal("error failed to trigger with an invalid request")
		}
	})

	t.Run("missing param pipeline", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "12345678",
			}}
		if err := ProcessEvent(ev); err == nil {
			t.Fatal("error failed to trigger with an invalid request")
		}
	})

	t.Run("missing pipeline execution", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "12345678",
				Pipeline:    "12345678",
			}}
		_ = os.Setenv("GITHUB_ACCESS_TOKEN", "1234567")
		if err := ProcessEvent(ev); err == nil {
			t.Fatal("error failed to trigger with an invalid request")
		}
	})

	t.Run("required key AWS_REGION missing value", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "12345678",
				Pipeline:    "12345678",
			}}
		_ = os.Setenv("GITHUB_ACCESS_TOKEN", "1234567")
		err := ProcessEvent(ev)
		if err == nil {
			t.Fatal("expected error")
		} else if err.Error() != "required key AWS_REGION missing value" {
			t.Fatal("error expected was not the same")
		}
	})

	t.Run("required key APPLICATION_STAGE_NAME missing value", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "12345678",
				Pipeline:    "12345678",
			}}
		_ = os.Setenv("GITHUB_ACCESS_TOKEN", "1234567")
		_ = os.Setenv("AWS_REGION", "us-east-1")
		err := ProcessEvent(ev)
		if err == nil {
			t.Fatal("expected error")
		} else if err.Error() != "required key APPLICATION_STAGE_NAME missing value" {
			t.Fatal("error expected was not the same")
		}
	})

	t.Run("ValidationException: ExecutionID", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "12345678",
				Pipeline:    "12345678",
			}}
		_ = os.Setenv("GITHUB_ACCESS_TOKEN", "1234567")
		_ = os.Setenv("AWS_REGION", "us-east-1")
		_ = os.Setenv("APPLICATION_STAGE_NAME", "testing")
		err := ProcessEvent(ev)
		if err == nil {
			t.Fatal("error was expected")
		} /*else if !strings.Contains(err.Error(), "ValidationException: 1 validation error detected") {
			t.Fatal("error message expected does not match", err.Error())
		}*/
	})

	t.Run("PipelineNotFoundException: The account with id", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "a5ef215c-43b4-4513-b97f-1829f642e0b1",
				Pipeline:    "12345678",
			}}
		_ = os.Setenv("GITHUB_ACCESS_TOKEN", "1234567")
		_ = os.Setenv("AWS_REGION", "us-east-1")
		_ = os.Setenv("APPLICATION_STAGE_NAME", "testing")
		err := ProcessEvent(ev)
		if err == nil {
			t.Fatal("error was expected")
		} /* else if !strings.Contains(err.Error(), "PipelineNotFoundException: The account with id") {
			t.Fatal("error message expected does not match", err.Error())
		}*/
	})

	// todo: test loading configuration

	// todo: test extracting the github information from pipeline
}

// Mocking kms client
type mockKmsClient struct {
	kmsiface.KMSAPI
}

// Decrypt is used for mocking a decryption of a KMS key
func (m *mockKmsClient) Decrypt(input *kms.DecryptInput) (*kms.DecryptOutput, error) {

	// Invalid input
	if len(input.CiphertextBlob) == 0 {
		return nil, fmt.Errorf("missing text to encrypt")
	}

	output := &kms.DecryptOutput{
		Plaintext: []byte(" some-encrypted-text\n"),
	}
	return output, nil
}

// Mocking pipeline client
type mockCodePipelineClient struct {
	codepipelineiface.CodePipelineAPI
}

// GetPipelineExecution is a mock request for codepipeline
func (m *mockCodePipelineClient) GetPipelineExecution(input *codepipeline.GetPipelineExecutionInput) (*codepipeline.GetPipelineExecutionOutput, error) {

	// Missing pipeline name
	if len(aws.StringValue(input.PipelineName)) == 0 {
		return nil, fmt.Errorf("aws will reject: missing pipeline name")
	}

	// Missing pipeline name
	if len(aws.StringValue(input.PipelineExecutionId)) == 0 {
		return nil, fmt.Errorf("aws will reject: missing execution id")
	}

	// Test nil response and no error
	if aws.StringValue(input.PipelineName) == "nil" {
		return nil, nil
	}

	// Create a valid artifact
	var artifacts []*codepipeline.ArtifactRevision

	if aws.StringValue(input.PipelineName) == "bad-artifact-name" {
		artifacts = append(artifacts, &codepipeline.ArtifactRevision{
			Name:            aws.String("InvalidArtifactName"),
			RevisionId:      aws.String("25c0c3e61c4db2c2cde8b163b3ad096875c1ce08"),
			RevisionSummary: aws.String("Some commit message"),
			RevisionUrl:     aws.String("https://github.com/mrz1836/codepipeline-to-github/commit/25c0c3e61c4db2c2cde8b163b3ad096875c1ce08"),
		})
	} else if aws.StringValue(input.PipelineName) == "bad-artifact-url" {
		artifacts = append(artifacts, &codepipeline.ArtifactRevision{
			Name:            aws.String("InvalidArtifactName"),
			RevisionId:      aws.String("25c0c3e61c4db2c2cde8b163b3ad096875c1ce08"),
			RevisionSummary: aws.String("Some commit message"),
			RevisionUrl:     aws.String("not a url"),
		})
	} else {
		artifacts = append(artifacts, &codepipeline.ArtifactRevision{
			Name:            aws.String("SourceCode"),
			RevisionId:      aws.String("25c0c3e61c4db2c2cde8b163b3ad096875c1ce08"),
			RevisionSummary: aws.String("Some commit message"),
			RevisionUrl:     aws.String("https://github.com/mrz1836/codepipeline-to-github/commit/25c0c3e61c4db2c2cde8b163b3ad096875c1ce08"),
		})
	}

	// Create a valid execution output
	output := &codepipeline.GetPipelineExecutionOutput{
		PipelineExecution: &codepipeline.PipelineExecution{
			ArtifactRevisions:   artifacts,
			PipelineExecutionId: input.PipelineExecutionId,
			PipelineName:        aws.String("some-pipeline"),
			Status:              aws.String("InProgress"),
		},
	}

	return output, nil
}

// TestGetExecutionOutput will test GetExecutionOutput()
func TestGetExecutionOutput(t *testing.T) {
	mockPipeline := &mockCodePipelineClient{}

	// Test a valid pipeline response
	response, err := getExecutionOutput("some-pipeline", "12345", mockPipeline)
	if err != nil {
		t.Fatal("error should not have occurred", err.Error())
	} else if response == nil {
		t.Fatal("response is nil and was expected to be a pointer")
	}

	// Test an invalid pipeline name
	_, err = getExecutionOutput("", "12345", mockPipeline)
	if err == nil {
		t.Fatal("error should not have occurred")
	}

	// Test an invalid exception id
	_, err = getExecutionOutput("some-pipeline", "", mockPipeline)
	if err == nil {
		t.Fatal("error should not have occurred")
	}

	// Test a nil response error
	_, err = getExecutionOutput("nil", "12345", mockPipeline)
	if err == nil {
		t.Fatal("error should not have occurred")
	}
}

// TestGetArtifact will test getting an artifact from an execution output
func TestGetArtifact(t *testing.T) {
	mockPipeline := &mockCodePipelineClient{}

	// Test a valid pipeline response
	response, err := getExecutionOutput("some-pipeline", "12345", mockPipeline)
	if err != nil {
		t.Fatal("error should not have occurred", err.Error())
	} else if response == nil {
		t.Fatal("response is nil and was expected to be a pointer")
	}

	artifact := getArtifact(response)
	if artifact == nil {
		t.Fatal("artifact was nil, expected a pointer")
	}

	// Test an invalid artifact name
	response, err = getExecutionOutput("bad-artifact-name", "12345", mockPipeline)

	artifact = getArtifact(response)
	if artifact != nil {
		t.Fatal("artifact was not nil, expected artifact to be nil")
	}

}

// TestGetCommit will test getting a commit from a pipeline execution
func TestGetCommit(t *testing.T) {
	mockPipeline := &mockCodePipelineClient{}

	// Test a valid pipeline response
	response, err := getExecutionOutput("some-pipeline", "12345", mockPipeline)
	if err != nil {
		t.Fatal("error should not have occurred", err.Error())
	} else if response == nil {
		t.Fatal("response is nil and was expected to be a pointer")
	}

	// Valid commit artifact
	commit, status, revisionURL, commitErr := getCommit("some-pipeline", "12345", mockPipeline)
	if commitErr != nil {
		t.Fatal("error occurred in getCommit", commitErr.Error())
	} else if commit != "25c0c3e61c4db2c2cde8b163b3ad096875c1ce08" {
		t.Fatal("commit value was not as expected", commit)
	} else if status != "pending" {
		t.Fatal("status value was not as expected", status)
	} else if revisionURL == nil {
		t.Fatal("url was nil, expected pointer")
	} else if revisionURL.String() != "https://github.com/mrz1836/codepipeline-to-github/commit/25c0c3e61c4db2c2cde8b163b3ad096875c1ce08" {
		t.Fatal("revisionURL value was not as expected", revisionURL.String())
	}

	// Invalid commit url
	_, _, revisionURL, commitErr = getCommit("bad-artifact-url", "12345", mockPipeline)
	if revisionURL != nil {
		t.Fatal("revisionURL should have been nil")
	} else if commitErr != nil {
		t.Fatal("error should still be nil", revisionURL, commitErr)
	}
}

// TestDecodeString will test decodeString()
func TestDecodeString(t *testing.T) {
	mockKms := &mockKmsClient{}

	// Valid decryption
	decrypted, err := decodeString(mockKms, "dGhpcyBpcyBzYW5mb3VuZHJ5IGxpbnV4IHR1dG9yaWFsCg==")
	if err != nil {
		t.Fatal("error occurred", err.Error())
	} else if decrypted != "some-encrypted-text" {
		t.Fatal("value expected was wrong", decrypted)
	}

	// Invalid base64
	_, err = decodeString(mockKms, "invalid-base-64")
	if err == nil {
		t.Fatal("error should have occurred")
	}

	// Invalid value
	_, err = decodeString(mockKms, "")
	if err == nil {
		t.Fatal("error should have occurred")
	}
}

// TestLoadConfiguration will test loadConfiguration()
func TestLoadConfiguration(t *testing.T) {
	mockKms := &mockKmsClient{}

	os.Clearenv()

	err := loadConfiguration(mockKms)
	if err == nil {
		t.Fatal("error should have occurred")
	} else if err.Error() != "required key AWS_REGION missing value" {
		t.Error("error returned was not as expected", err.Error())
	}

	_ = os.Setenv("AWS_REGION", "us-east-1")

	err = loadConfiguration(mockKms)
	if err == nil {
		t.Fatal("error should have occurred")
	} else if err.Error() != "required key GITHUB_ACCESS_TOKEN missing value" {
		t.Error("error returned was not as expected", err.Error())
	}

	_ = os.Setenv("GITHUB_ACCESS_TOKEN", "1234567")

	err = loadConfiguration(mockKms)
	if err == nil {
		t.Fatal("error should have occurred")
	} else if err.Error() != "required key APPLICATION_STAGE_NAME missing value" {
		t.Error("error returned was not as expected", err.Error())
	}

	_ = os.Setenv("APPLICATION_STAGE_NAME", "testing")
	err = loadConfiguration(mockKms)
	if err != nil {
		t.Fatal("error occurred", err.Error())
	} else if len(config.GithubAccessToken) == 0 {
		t.Fatal("missing token value")
	}
}
