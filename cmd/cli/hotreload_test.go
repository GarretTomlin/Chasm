package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
	"testing"
)

var testDylibPath = tmpPath("chasm_script_test.dylib")

func TestSharedLibFlags(t *testing.T) {
	var scriptExt string
	var sharedFlags []string

	switch runtime.GOOS {
	case "darwin":
		scriptExt = ".dylib"
		sharedFlags = []string{"-dynamiclib", "-undefined", "dynamic_lookup"}
	case "windows":
		scriptExt = ".dll"
		sharedFlags = []string{"-shared"}
	default:
		scriptExt = ".so"
		sharedFlags = []string{"-shared", "-fPIC"}
	}

	if !strings.HasSuffix("chasm_script_123"+scriptExt, scriptExt) {
		t.Errorf("expected %s extension", scriptExt)
	}

	wantFlag := "-dynamiclib"
	if runtime.GOOS != "darwin" {
		wantFlag = "-shared"
	}
	found := false
	for _, f := range sharedFlags {
		if f == wantFlag {
			found = true
		}
	}
	if !found {
		t.Errorf("expected %s in flags, got %v", wantFlag, sharedFlags)
	}
}

func TestSentinelWrittenAfterDylib(t *testing.T) {
	sentinel := tmpPath("chasm_reload_ready")
	_ = os.Remove(sentinel)

	if err := writeReloadSentinel(testDylibPath); err != nil {
		t.Fatalf("writeReloadSentinel: %v", err)
	}

	data, err := os.ReadFile(sentinel)
	if err != nil {
		t.Fatalf("sentinel should exist after write: %v", err)
	}
	if string(data) != testDylibPath {
		t.Errorf("sentinel content = %q, want %q", string(data), testDylibPath)
	}

	_ = os.Remove(sentinel)
	if _, err := os.Stat(sentinel); err == nil {
		t.Errorf("sentinel should be absent after consumption")
	}
}

func TestSentinelConsumedExactlyOnce(t *testing.T) {
	sentinel := tmpPath("chasm_reload_ready")
	_ = os.Remove(sentinel)

	for n := 1; n <= 20; n++ {
		consumed := 0
		for i := 0; i < n; i++ {
			dylib := tmpPath(fmt.Sprintf("chasm_script_%d.dylib", i))
			if err := writeReloadSentinel(dylib); err != nil {
				t.Fatalf("write sentinel: %v", err)
			}
			if _, err := os.Stat(sentinel); err == nil {
				_ = os.Remove(sentinel)
				consumed++
			}
		}
		if consumed != n {
			t.Errorf("n=%d: expected %d consumptions, got %d", n, n, consumed)
		}
		if _, err := os.Stat(sentinel); err == nil {
			t.Errorf("n=%d: sentinel should be absent after all consumptions", n)
		}
	}
}

func TestEngineNotRestartedOnRecompile(t *testing.T) {
	sentinel := tmpPath("chasm_reload_ready")
	_ = os.Remove(sentinel)

	for i := 0; i < 10; i++ {
		dylib := tmpPath(fmt.Sprintf("chasm_script_%d.dylib", i))
		if err := writeReloadSentinel(dylib); err != nil {
			t.Fatalf("cycle %d: writeReloadSentinel: %v", i, err)
		}
		if _, err := os.Stat(sentinel); err != nil {
			t.Errorf("cycle %d: sentinel should exist after successful compile", i)
		}
		_ = os.Remove(sentinel)
	}
}
