package main

import (
	"os"
	"testing"
)

// Converts a CAF/Opus file named by WA_TEST_CAF into Ogg next to it, so the
// result can be checked with a real decoder (afinfo, afconvert).
func TestCAFToOgg(t *testing.T) {
	path := os.Getenv("WA_TEST_CAF")
	if path == "" {
		t.Skip("WA_TEST_CAF not set")
	}
	caf, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	ogg, err := cafOpusToOgg(caf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".ogg", ogg, 0o644); err != nil {
		t.Fatal(err)
	}
}
