package main

import (
	"bytes"
	"image"
	"os"
	"testing"

	"github.com/HugoSmits86/nativewebp"
)

// Encodes the PNG named by WA_TEST_PNG as a 512px WebP next to it, so the
// result can be checked with a real decoder (sips).
func TestStickerEncode(t *testing.T) {
	path := os.Getenv("WA_TEST_PNG")
	if path == "" {
		t.Skip("WA_TEST_PNG not set")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := nativewebp.Encode(&buf, scaleSquare(src, 512), nil); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".webp", buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}
