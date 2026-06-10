// Package dockerignore_equivalency verifies that our Nim isExcluded()
// implementation matches moby/patternmatcher.MatchesOrParentMatches()
// exactly.
//
// testcases.json is the single source of truth.  This file verifies
// each case against the canonical Go implementation; the companion Nim
// program check_nim.nim verifies the same cases against our Nim
// implementation.  Any divergence between the two is a bug.
package dockerignore_equivalency

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/moby/patternmatcher"
)

type testCase struct {
	Comment  string   `json:"comment"`
	Patterns []string `json:"patterns"`
	Path     string   `json:"path"`
	Expected bool     `json:"expected"`
}

func loadCases(t *testing.T) []testCase {
	t.Helper()
	data, err := os.ReadFile("testcases.json")
	if err != nil {
		t.Fatalf("could not read testcases.json: %v", err)
	}
	var cases []testCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatalf("could not parse testcases.json: %v", err)
	}
	return cases
}

// TestEquivalency runs every case in testcases.json through
// moby/patternmatcher.MatchesOrParentMatches and checks the result
// against the expected field.
//
// A failure here means either:
//   - the expected field in testcases.json is wrong (fix the JSON), or
//   - moby/patternmatcher changed its behavior (update expected + Nim).
func TestEquivalency(t *testing.T) {
	cases := loadCases(t)
	for _, tc := range cases {
		tc := tc
		t.Run(tc.Comment, func(t *testing.T) {
			pm, err := patternmatcher.New(tc.Patterns)
			if err != nil {
				t.Fatalf("patternmatcher.New(%q): %v", tc.Patterns, err)
			}
			got, err := pm.MatchesOrParentMatches(tc.Path)
			if err != nil {
				t.Fatalf("MatchesOrParentMatches(%q): %v", tc.Path, err)
			}
			if got != tc.Expected {
				t.Errorf(
					"patterns=%q path=%q: got %v, want %v",
					tc.Patterns, tc.Path, got, tc.Expected,
				)
			}
		})
	}
}
