// shazam — Chasm installer
//
// Usage:
//
//	shazam [prefix]          install chasm to prefix/bin  (default: ~/.local)
//	shazam --prefix /usr/local
//	shazam version
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	chasmVersion = "0.3.0"
	extName      = "chasm.chasm-language-0.1.0"
)

func main() {
	prefix, showVersion := parseArgs()
	if showVersion {
		fmt.Printf("shazam %s\n", chasmVersion)
		return
	}
	if err := install(prefix); err != nil {
		fatalf("%v\n", err)
	}
}

func parseArgs() (prefix string, version bool) {
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "version", "--version", "-v":
			version = true
		case "--prefix":
			if i+1 < len(args) {
				i++
				prefix = args[i]
			}
		case "help", "--help", "-h":
			usage()
			os.Exit(0)
		default:
			if !strings.HasPrefix(args[i], "--") {
				prefix = args[i]
			}
		}
	}
	return
}

func install(prefix string) error {
	repoRoot, err := repoDir()
	if err != nil {
		return err
	}

	binDir, err := resolveBinDir(prefix)
	if err != nil {
		return err
	}

	fmt.Printf("chasm %s\n", chasmVersion)
	fmt.Printf("repo:   %s\n", repoRoot)
	fmt.Printf("target: %s\n\n", binDir)

	// Require Go.
	goPath, err := exec.LookPath("go")
	if err != nil {
		return fmt.Errorf("'go' not found in PATH\n  Install Go from https://go.dev/dl/ then re-run shazam")
	}
	fmt.Printf("go:     %s\n\n", goPath)

	// Build the CLI, baking in the repo root so it works from any directory.
	fmt.Println("building chasm...")
	if err := os.MkdirAll(binDir, 0755); err != nil {
		return fmt.Errorf("cannot create %s: %w", binDir, err)
	}
	cliSrc := filepath.Join(repoRoot, "cmd", "cli")
	cliDst := filepath.Join(binDir, "chasm")
	ldflags := fmt.Sprintf("-X main.defaultChasmHome=%s", repoRoot)
	build := exec.Command("go", "build", "-ldflags", ldflags, "-o", cliDst, cliSrc)
	build.Stdout = os.Stdout
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		return fmt.Errorf("build failed: %w", err)
	}
	fmt.Printf("  installed %s\n\n", cliDst)

	// Install editor extensions.
	installExtensions(repoRoot)

	// PATH check.
	checkPath(binDir)

	fmt.Printf("\nDone!  Try: chasm run examples/hello/hello.chasm\n")
	fmt.Println("Restart Cursor / VS Code to activate the Chasm extension.")
	return nil
}

// ---------------------------------------------------------------------------
// Editor extensions
// ---------------------------------------------------------------------------

func installExtensions(repoRoot string) {
	extSrc := filepath.Join(repoRoot, "editors", "vscode")
	if _, err := os.Stat(extSrc); err != nil {
		return
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return
	}

	targets := []struct{ dir, reg string }{
		{filepath.Join(home, ".cursor", "extensions"), filepath.Join(home, ".cursor", "extensions", "extensions.json")},
		{filepath.Join(home, ".vscode", "extensions"), filepath.Join(home, ".vscode", "extensions", "extensions.json")},
	}

	for _, t := range targets {
		if _, err := os.Stat(t.dir); err != nil {
			continue
		}
		dst := filepath.Join(t.dir, extName)
		if err := installExtension(extSrc, dst, t.reg); err == nil {
			fmt.Printf("  extension → %s\n", dst)
		}
	}
}

func installExtension(src, dst, regPath string) error {
	if err := os.MkdirAll(filepath.Join(dst, "syntaxes"), 0755); err != nil {
		return err
	}
	files := []string{"package.json", "language-configuration.json"}
	for _, f := range files {
		if err := copyFile(filepath.Join(src, f), filepath.Join(dst, f)); err != nil {
			return err
		}
	}
	if err := copyFile(
		filepath.Join(src, "syntaxes", "chasm.tmLanguage.json"),
		filepath.Join(dst, "syntaxes", "chasm.tmLanguage.json"),
	); err != nil {
		return err
	}
	// Optional icon.
	if iconSrc := filepath.Join(src, "icon.png"); fileExists(iconSrc) {
		_ = copyFile(iconSrc, filepath.Join(dst, "icon.png"))
	}
	return updateExtRegistry(dst, regPath)
}

func updateExtRegistry(extPath, regPath string) error {
	var exts []map[string]any
	if data, err := os.ReadFile(regPath); err == nil {
		_ = json.Unmarshal(data, &exts)
	}
	// Remove any existing chasm entry.
	filtered := exts[:0]
	for _, e := range exts {
		id := ""
		if ident, ok := e["identifier"].(map[string]any); ok {
			id, _ = ident["id"].(string)
		}
		if !strings.Contains(id, "chasm") {
			filtered = append(filtered, e)
		}
	}
	filtered = append(filtered, map[string]any{
		"identifier":       map[string]any{"id": "chasm.chasm-language"},
		"version":          "0.1.0",
		"location":         map[string]any{"$mid": 1, "fsPath": extPath, "external": "file://" + extPath, "path": extPath, "scheme": "file"},
		"relativeLocation": extName,
		"metadata":         map[string]any{"isApplicationScoped": false, "isMachineScoped": false, "isBuiltin": false, "installedTimestamp": 1773781707291},
	})
	data, err := json.MarshalIndent(filtered, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(regPath, data, 0644)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// repoDir finds the root of the Chasm repo by walking up from the executable.
func repoDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("cannot locate executable: %w", err)
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dir := filepath.Dir(exe)
	for i := 0; i < 10; i++ {
		if _, err := os.Stat(filepath.Join(dir, "bootstrap")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	// Fallback: assume shazam is run from the repo root.
	cwd, _ := os.Getwd()
	if _, err := os.Stat(filepath.Join(cwd, "bootstrap")); err == nil {
		return cwd, nil
	}
	return "", fmt.Errorf(
		"cannot locate Chasm repo root\n" +
			"  Run shazam from inside the repo, or set CHASM_HOME:\n" +
			"    CHASM_HOME=/path/to/chasm shazam",
	)
}

func resolveBinDir(prefix string) (string, error) {
	if prefix != "" {
		return filepath.Join(prefix, "bin"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot determine home directory: %w", err)
	}
	if runtime.GOOS == "windows" {
		local := os.Getenv("LOCALAPPDATA")
		if local == "" {
			local = filepath.Join(home, "AppData", "Local")
		}
		return filepath.Join(local, "chasm", "bin"), nil
	}
	return filepath.Join(home, ".local", "bin"), nil
}

func checkPath(binDir string) {
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		if p == binDir {
			return
		}
	}
	shell := filepath.Base(os.Getenv("SHELL"))
	fmt.Printf("NOTE: %s is not in your PATH.\n", binDir)
	switch shell {
	case "fish":
		fmt.Printf("  echo 'fish_add_path %s' >> ~/.config/fish/config.fish\n", binDir)
	case "zsh":
		fmt.Printf("  echo 'export PATH=\"$PATH:%s\"' >> ~/.zshrc && source ~/.zshrc\n", binDir)
	default:
		fmt.Printf("  echo 'export PATH=\"$PATH:%s\"' >> ~/.bashrc && source ~/.bashrc\n", binDir)
	}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "shazam: "+format, args...)
	os.Exit(1)
}

func usage() {
	fmt.Print(strings.TrimSpace(`
shazam — Chasm installer

Usage:
  shazam [prefix]            install to prefix/bin  (default: ~/.local/bin)
  shazam --prefix /usr/local install system-wide
  shazam version             print version

Examples:
  shazam                     # install to ~/.local/bin
  shazam /usr/local          # install to /usr/local/bin
`) + "\n")
}
