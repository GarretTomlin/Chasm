// chasmup — Chasm installer
//
// Install with:
//
//	go install github.com/garrettomlin/chasm/cmd/chasmup@latest
//
// Then run:
//
//	chasmup install
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const version = "0.1.0"
const repo = "https://github.com/garrettomlin/chasm"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	switch os.Args[1] {
	case "install":
		prefix := ""
		if len(os.Args) >= 3 {
			prefix = os.Args[2]
		}
		if err := install(prefix); err != nil {
			fatalf("install failed: %v\n", err)
		}
	case "version", "--version":
		fmt.Printf("chasmup %s\n", version)
	case "help", "--help", "-h":
		usage()
	default:
		fatalf("unknown command %q — run 'chasmup help'\n", os.Args[1])
	}
}

func install(prefix string) error {
	// Resolve install directory.
	binDir, err := resolveBinDir(prefix)
	if err != nil {
		return err
	}

	// Require Zig.
	zigPath, err := exec.LookPath("zig")
	if err != nil {
		return fmt.Errorf("zig not found in PATH\n  Install Zig from https://ziglang.org/download/ (0.15+)")
	}
	fmt.Printf("zig:    %s\n", zigPath)
	fmt.Printf("target: %s\n\n", binDir)

	// Find or clone the source.
	srcDir, err := findOrCloneSource()
	if err != nil {
		return err
	}

	// Build.
	fmt.Println("building chasm (ReleaseFast)...")
	build := exec.Command("zig", "build", "-Doptimize=ReleaseFast")
	build.Dir = srcDir
	build.Stdout = os.Stdout
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		return fmt.Errorf("zig build failed: %w", err)
	}

	// Install binaries.
	if err := os.MkdirAll(binDir, 0755); err != nil {
		return fmt.Errorf("cannot create %s: %w", binDir, err)
	}
	for _, name := range []string{"chasm", "chasm-lsp"} {
		src := filepath.Join(srcDir, "zig-out", "bin", name)
		dst := filepath.Join(binDir, name)
		if runtime.GOOS == "windows" {
			src += ".exe"
			dst += ".exe"
		}
		if err := copyFile(src, dst); err != nil {
			return fmt.Errorf("installing %s: %w", name, err)
		}
		fmt.Printf("  installed %s\n", dst)
	}

	// Install editor extensions.
	installExtensions(srcDir)

	// PATH check.
	fmt.Println()
	checkPath(binDir)

	fmt.Printf("\nDone!  Run: chasm --version\n")
	return nil
}

func findOrCloneSource() (string, error) {
	// 1. If we're running from inside the repo, use it directly.
	exe, err := os.Executable()
	if err == nil {
		// Walk up looking for build.zig
		dir := filepath.Dir(exe)
		for i := 0; i < 6; i++ {
			if _, err := os.Stat(filepath.Join(dir, "build.zig")); err == nil {
				return dir, nil
			}
			dir = filepath.Dir(dir)
		}
	}

	// 2. Check $CHASM_SRC.
	if src := os.Getenv("CHASM_SRC"); src != "" {
		if _, err := os.Stat(filepath.Join(src, "build.zig")); err == nil {
			fmt.Printf("using CHASM_SRC=%s\n", src)
			return src, nil
		}
	}

	// 3. Clone into a temp directory.
	fmt.Printf("cloning %s...\n", repo)
	tmp, err := os.MkdirTemp("", "chasm-src-*")
	if err != nil {
		return "", err
	}
	clone := exec.Command("git", "clone", "--depth=1", repo, tmp)
	clone.Stdout = os.Stdout
	clone.Stderr = os.Stderr
	if err := clone.Run(); err != nil {
		return "", fmt.Errorf("git clone failed: %w\n  Set CHASM_SRC=/path/to/chasm-repo if you have it locally", err)
	}
	return tmp, nil
}

func installExtensions(srcDir string) {
	extSrc := filepath.Join(srcDir, "editors", "vscode")
	if _, err := os.Stat(extSrc); err != nil {
		return // no editor extension in this build
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return
	}

	targets := []string{
		filepath.Join(home, ".cursor", "extensions"),
		filepath.Join(home, ".vscode", "extensions"),
	}

	extFiles := []string{"package.json", "language-configuration.json"}
	syntaxFiles := []string{filepath.Join("syntaxes", "chasm.tmLanguage.json")}

	for _, extDir := range targets {
		if _, err := os.Stat(extDir); err != nil {
			continue // editor not installed
		}
		dst := filepath.Join(extDir, "chasm.chasm-language-0.1.0")
		_ = os.MkdirAll(filepath.Join(dst, "syntaxes"), 0755)

		ok := true
		for _, f := range extFiles {
			if err := copyFile(filepath.Join(extSrc, f), filepath.Join(dst, f)); err != nil {
				ok = false
			}
		}
		for _, f := range syntaxFiles {
			if err := copyFile(filepath.Join(extSrc, f), filepath.Join(dst, f)); err != nil {
				ok = false
			}
		}
		if iconSrc := filepath.Join(extSrc, "icon.png"); fileExists(iconSrc) {
			_ = copyFile(iconSrc, filepath.Join(dst, "icon.png"))
		}

		if ok {
			fmt.Printf("  extension → %s\n", dst)
		}
	}
}

func resolveBinDir(prefix string) (string, error) {
	if prefix != "" {
		return filepath.Join(prefix, "bin"), nil
	}
	// Default: ~/.local/bin on Unix, %LOCALAPPDATA%\chasm\bin on Windows.
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
	path := os.Getenv("PATH")
	for _, p := range filepath.SplitList(path) {
		if p == binDir {
			return
		}
	}
	shell := filepath.Base(os.Getenv("SHELL"))
	fmt.Printf("NOTE: %s is not in your PATH.\n\n", binDir)
	switch shell {
	case "fish":
		fmt.Printf("  Add it:\n    echo 'fish_add_path %s' >> ~/.config/fish/config.fish\n", binDir)
	case "zsh":
		fmt.Printf("  Add it:\n    echo 'export PATH=\"$PATH:%s\"' >> ~/.zshrc && source ~/.zshrc\n", binDir)
	default:
		fmt.Printf("  Add it:\n    echo 'export PATH=\"$PATH:%s\"' >> ~/.bashrc && source ~/.bashrc\n", binDir)
	}
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0755)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return !errors.Is(err, os.ErrNotExist)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "chasmup: "+format, args...)
	os.Exit(1)
}

func usage() {
	fmt.Print(strings.TrimSpace(`
chasmup — Chasm installer

Usage:
  chasmup install [prefix]   build and install chasm + chasm-lsp
                             default prefix: ~/.local  (Unix)
                                             %LOCALAPPDATA%\chasm  (Windows)
  chasmup version            print chasmup version

Examples:
  chasmup install                  # install to ~/.local/bin
  chasmup install /usr/local       # install system-wide
  CHASM_SRC=~/dev/chasm chasmup install  # use local source tree

Environment:
  CHASM_SRC   path to a local Chasm source tree (skips git clone)
`) + "\n")
}
