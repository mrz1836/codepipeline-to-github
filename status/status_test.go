package main

import (
	"os"
	"testing"
)

// TestProcessEvent will test the ProcessEvent() method
func TestProcessEvent(t *testing.T) {
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

	t.Run("missing or invalid Github token", func(t *testing.T) {
		ev := event{
			Detail: &detail{
				ExecutionID: "12345678",
				Pipeline:    "12345678",
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
}
