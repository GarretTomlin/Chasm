// cmd/cli/diag_pbt_test.go — property-based tests for rich-compiler-errors
// Feature: rich-compiler-errors
//
// Tests the diagnostic infrastructure logic (implemented in Go to mirror
// the Chasm implementations in compiler/sema.chasm).
// Run with: go test ./cmd/cli/ -run TestPBT_P -v
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"

	"pgregory.net/rapid"
)

// ---------------------------------------------------------------------------
// Go mirrors of the Chasm diagnostic functions
// ---------------------------------------------------------------------------

type Diagnostic struct {
	Code     string
	Category string
	File     string
	Line     int
	Col      int
	Message  string
	Snippet  string
	Caret    string
	Help     string
}

type DiagCollector struct {
	Diags  []Diagnostic
	CountV []int // single-element slice acting as mutable reference
}

func makeDiagCollector() DiagCollector {
	return DiagCollector{Diags: make([]Diagnostic, 0, 256), CountV: []int{0}}
}

func diagEmit(dc DiagCollector, d Diagnostic) DiagCollector {
	n := dc.CountV[0]
	if n < 256 {
		dc.Diags = append(dc.Diags, d)
		dc.CountV[0]++
	}
	return dc
}

func extractSnippet(src string, line int) string {
	if line <= 0 {
		return ""
	}
	curLine := 1
	start := 0
	for i := 0; i < len(src); i++ {
		if src[i] == '\n' {
			if curLine == line {
				return src[start:i]
			}
			curLine++
			start = i + 1
		}
	}
	if curLine == line {
		return src[start:]
	}
	return ""
}

func makeCaret(col, length int) string {
	if length < 1 {
		length = 1
	}
	spaces := strings.Repeat(" ", col-1)
	carets := strings.Repeat("^", length)
	return spaces + carets
}

func renderDiagnostic(d Diagnostic) string {
	lineS := fmt.Sprintf("%d", d.Line)
	gutter := " " + lineS + " "
	blankG := strings.Repeat(" ", len(gutter))
	nl := "\n"
	header := "error[" + d.Code + "]: " + d.Category + nl
	arrow := "  --> " + d.File + ":" + lineS + ":" + fmt.Sprintf("%d", d.Col) + nl
	sep1 := blankG + "|" + nl
	codeLn := gutter + "| " + d.Snippet + nl
	caretL := blankG + "|   " + d.Caret + nl
	sep2 := blankG + "|" + nl
	result := header + arrow + sep1 + codeLn + caretL + sep2
	if len(d.Help) > 0 {
		result += blankG + "= help: " + d.Help + nl
	}
	return result
}

func levenshtein(a, b string) int {
	la, lb := len(a), len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}
	prev := make([]int, lb+1)
	curr := make([]int, lb+1)
	for j := 0; j <= lb; j++ {
		prev[j] = j
	}
	for i := 1; i <= la; i++ {
		curr[0] = i
		for j := 1; j <= lb; j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			del := prev[j] + 1
			ins := curr[j-1] + 1
			sub := prev[j-1] + cost
			best := del
			if ins < best {
				best = ins
			}
			if sub < best {
				best = sub
			}
			curr[j] = best
		}
		prev, curr = curr, prev
	}
	return prev[lb]
}

func closestMatch(candidates []string, name string) string {
	bestDist := 3
	bestName := ""
	for _, c := range candidates {
		d := levenshtein(c, name)
		if d < bestDist {
			bestDist = d
			bestName = c
		}
	}
	if bestDist <= 2 {
		return bestName
	}
	return ""
}

// ---------------------------------------------------------------------------
// Property 1: Diagnostic accumulation is monotonic
// Validates: Requirements 1.2, 1.3
// ---------------------------------------------------------------------------

func TestPBT_P1_DiagAccumulationMonotonic(t *testing.T) {
	// Feature: rich-compiler-errors, Property 1: Diagnostic accumulation is monotonic
	rapid.Check(t, func(rt *rapid.T) {
		n := rapid.IntRange(0, 50).Draw(rt, "n")
		dc := makeDiagCollector()
		emitted := make([]Diagnostic, 0, n)
		for i := 0; i < n; i++ {
			d := Diagnostic{
				Code:    fmt.Sprintf("E%03d", rapid.IntRange(1, 8).Draw(rt, "code")),
				Message: rapid.StringMatching(`[a-z ]{1,20}`).Draw(rt, "msg"),
				Line:    rapid.IntRange(1, 1000).Draw(rt, "line"),
				Col:     rapid.IntRange(1, 80).Draw(rt, "col"),
			}
			dc = diagEmit(dc, d)
			emitted = append(emitted, d)
		}
		// Count must equal number of emissions
		if dc.CountV[0] != n {
			rt.Fatalf("expected count %d, got %d", n, dc.CountV[0])
		}
		// Each emitted diagnostic must be retrievable
		for i, want := range emitted {
			got := dc.Diags[i]
			if got.Code != want.Code || got.Message != want.Message {
				rt.Fatalf("diag[%d] mismatch: got %+v, want %+v", i, got, want)
			}
		}
	})
}

// ---------------------------------------------------------------------------
// Property 2: Snippet extraction round-trip
// Validates: Requirements 4.2, 4.3, 4.4
// ---------------------------------------------------------------------------

func TestPBT_P2_SnippetExtractionRoundTrip(t *testing.T) {
	// Feature: rich-compiler-errors, Property 2: Snippet extraction round-trip
	rapid.Check(t, func(rt *rapid.T) {
		// Generate 1–10 lines of text (no embedded newlines in each line)
		numLines := rapid.IntRange(1, 10).Draw(rt, "numLines")
		lines := make([]string, numLines)
		for i := range lines {
			lines[i] = rapid.StringMatching(`[a-zA-Z0-9 _]{0,30}`).Draw(rt, fmt.Sprintf("line%d", i))
		}
		src := strings.Join(lines, "\n")
		// Pick a valid line index
		lineIdx := rapid.IntRange(1, numLines).Draw(rt, "lineIdx")
		got := extractSnippet(src, lineIdx)
		want := lines[lineIdx-1]
		if got != want {
			rt.Fatalf("extractSnippet(src, %d) = %q, want %q\nsrc=%q", lineIdx, got, want, src)
		}
	})
}

// ---------------------------------------------------------------------------
// Property 3: Caret length matches token lexeme length
// Validates: Requirements 3.3, 3.4
// ---------------------------------------------------------------------------

func TestPBT_P3_CaretLengthMatchesLexeme(t *testing.T) {
	// Feature: rich-compiler-errors, Property 3: Caret length matches token lexeme length
	rapid.Check(t, func(rt *rapid.T) {
		col := rapid.IntRange(1, 80).Draw(rt, "col")
		length := rapid.IntRange(1, 40).Draw(rt, "length")
		caret := makeCaret(col, length)
		// Count the '^' characters
		caretCount := strings.Count(caret, "^")
		if caretCount != length {
			rt.Fatalf("makeCaret(%d, %d) has %d carets, want %d; got %q", col, length, caretCount, length, caret)
		}
		// Spaces before the carets must be col-1
		spaceCount := strings.Index(caret, "^")
		if spaceCount != col-1 {
			rt.Fatalf("makeCaret(%d, %d) has %d leading spaces, want %d; got %q", col, length, spaceCount, col-1, caret)
		}
	})
}

// ---------------------------------------------------------------------------
// Property 4: Rendered diagnostic contains required fields
// Validates: Requirements 3.1, 3.2
// ---------------------------------------------------------------------------

func TestPBT_P4_RenderedDiagContainsRequiredFields(t *testing.T) {
	// Feature: rich-compiler-errors, Property 4: Rendered diagnostic contains required fields
	rapid.Check(t, func(rt *rapid.T) {
		code := fmt.Sprintf("E%03d", rapid.IntRange(1, 8).Draw(rt, "code"))
		file := rapid.StringMatching(`[a-z]{1,10}\.chasm`).Draw(rt, "file")
		line := rapid.IntRange(1, 999).Draw(rt, "line")
		msg := rapid.StringMatching(`[a-z ]{1,20}`).Draw(rt, "msg")
		snippet := rapid.StringMatching(`[a-zA-Z0-9 =]{0,30}`).Draw(rt, "snippet")
		d := Diagnostic{
			Code:     code,
			Category: "test error",
			File:     file,
			Line:     line,
			Col:      1,
			Message:  msg,
			Snippet:  snippet,
			Caret:    "^",
		}
		rendered := renderDiagnostic(d)
		if !strings.Contains(rendered, code) {
			rt.Fatalf("rendered output missing code %q\n%s", code, rendered)
		}
		if !strings.Contains(rendered, file) {
			rt.Fatalf("rendered output missing file %q\n%s", file, rendered)
		}
		if !strings.Contains(rendered, fmt.Sprintf("%d", line)) {
			rt.Fatalf("rendered output missing line %d\n%s", line, rendered)
		}
		if snippet != "" && !strings.Contains(rendered, snippet) {
			rt.Fatalf("rendered output missing snippet %q\n%s", snippet, rendered)
		}
	})
}

// ---------------------------------------------------------------------------
// Property 7: "Did you mean?" suggestion is within edit distance 2
// Validates: Requirements 9.2, 11.2
// ---------------------------------------------------------------------------

func TestPBT_P7_ClosestMatchWithinEditDistance2(t *testing.T) {
	// Feature: rich-compiler-errors, Property 7: "Did you mean?" suggestion is within edit distance 2
	rapid.Check(t, func(rt *rapid.T) {
		numCandidates := rapid.IntRange(0, 10).Draw(rt, "numCandidates")
		candidates := make([]string, numCandidates)
		for i := range candidates {
			candidates[i] = rapid.StringMatching(`[a-z_]{1,12}`).Draw(rt, fmt.Sprintf("cand%d", i))
		}
		query := rapid.StringMatching(`[a-z_]{1,12}`).Draw(rt, "query")
		result := closestMatch(candidates, query)
		if result != "" {
			dist := levenshtein(result, query)
			if dist > 2 {
				rt.Fatalf("closestMatch returned %q with distance %d > 2 from %q", result, dist, query)
			}
		}
	})
}

// ---------------------------------------------------------------------------
// helpers for integration tests (P5, P6)
// ---------------------------------------------------------------------------

// chasmBin returns the path to the installed chasm binary.
// Prefers $CHASM_BIN env var, then PATH lookup, then ~/.local/bin/chasm.
func chasmBin(t *testing.T) string {
	t.Helper()
	if v := os.Getenv("CHASM_BIN"); v != "" {
		return v
	}
	if p, err := exec.LookPath("chasm"); err == nil {
		return p
	}
	home, _ := os.UserHomeDir()
	p := home + "/.local/bin/chasm"
	if _, err := os.Stat(p); err == nil {
		return p
	}
	t.Skip("chasm binary not found; set CHASM_BIN or install chasm")
	return ""
}

// runChasm writes src to a temp file and invokes `chasm compile <file>`.
// Returns (exitCode, stderr).
func runChasm(t *testing.T, src string) (int, string) {
	t.Helper()
	f, err := os.CreateTemp("", "chasm_pbt_*.chasm")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(src); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	f.Close()

	bin := chasmBin(t)
	cmd := exec.Command(bin, "compile", f.Name())
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf
	cmd.Stdout = io.Discard
	err = cmd.Run()
	code := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		} else {
			t.Fatalf("exec chasm: %v", err)
		}
	}
	return code, stderrBuf.String()
}

// ---------------------------------------------------------------------------
// Property 5: Compiler exits non-zero iff diagnostics were emitted
// Validates: Requirements 3.6, 3.7, 13.2, 13.3
// ---------------------------------------------------------------------------

func TestPBT_P5_ExitCodeCorrectness(t *testing.T) {
	// Feature: rich-compiler-errors, Property 5: Compiler exits non-zero iff diagnostics were emitted
	rapid.Check(t, func(rt *rapid.T) {
		// Generate a unique undefined variable name (avoids collision with builtins)
		varName := "undef_" + rapid.StringMatching(`[a-z]{3,8}`).Draw(rt, "varName")
		// Wrap in a minimal function so the parser is happy
		src := fmt.Sprintf("defp test_fn() do\n  x = %s\nend\n", varName)
		code, stderr := runChasm(t, src)
		if code == 0 {
			rt.Fatalf("expected non-zero exit for source with undefined var %q, got 0\nstderr: %s", varName, stderr)
		}
		if !strings.Contains(stderr, "E001") {
			rt.Fatalf("expected E001 in stderr for undefined var %q\nstderr: %s", varName, stderr)
		}
	})
}

// ---------------------------------------------------------------------------
// Property 6: Error detection does not abort remaining checks
// Validates: Requirements 5.3, 13.1
// ---------------------------------------------------------------------------

func TestPBT_P6_NonAbortCollection(t *testing.T) {
	// Feature: rich-compiler-errors, Property 6: Error detection does not abort remaining checks
	rapid.Check(t, func(rt *rapid.T) {
		k := rapid.IntRange(2, 5).Draw(rt, "k")
		// Build k independent undefined-variable references in one function body
		var lines []string
		for i := 0; i < k; i++ {
			varName := fmt.Sprintf("undef_var_%d", i)
			lines = append(lines, fmt.Sprintf("  _r%d = %s", i, varName))
		}
		src := "defp test_fn() do\n" + strings.Join(lines, "\n") + "\nend\n"
		_, stderr := runChasm(t, src)
		count := strings.Count(stderr, "E001")
		if count < k {
			rt.Fatalf("expected at least %d E001 diagnostics, got %d\nstderr:\n%s", k, count, stderr)
		}
	})
}
