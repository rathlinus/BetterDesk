package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/neodeskapp/neodesk/neodesk-server/ndcli"
)

// TestStartedAsNeodeskHelper is the binary started as neodesk, in a child
// process of the tests below: the arguments come from NEODESK_TEST_ARGS,
// one per line. It does nothing in a normal run.
func TestStartedAsNeodeskHelper(t *testing.T) {
	if os.Getenv("NEODESK_TEST_AS_NEODESK") != "1" {
		t.Skip("runs only as the child of the hand-over tests")
	}
	var args []string
	if a := os.Getenv("NEODESK_TEST_ARGS"); a != "" {
		args = strings.Split(a, "\n")
	}
	os.Args = append([]string{"/usr/local/bin/neodesk"}, args...)
	code, _ := startedAsCLI()
	os.Exit(code)
}

// installerCase is an option of neodesk.sh's argument loop: `--auto|-a)`.
var installerCase = regexp.MustCompile(`^\s*(-[-A-Za-z|]+)\)\s*$`)

// installerFlags are the options neodesk.sh takes, read from its argument
// loop, without --help and -h (neodesk --help is the command line's).
func installerFlags(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "install", "neodesk.sh"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	start := strings.Index(text, "\n# Parse command line arguments\n")
	if start < 0 {
		t.Fatal("neodesk.sh has no argument loop")
	}
	end := strings.Index(text[start:], "\ndone\n")
	if end < 0 {
		t.Fatal("neodesk.sh's argument loop has no end")
	}
	var flags []string
	for _, line := range strings.Split(text[start:start+end], "\n") {
		m := installerCase.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		for _, f := range strings.Split(m[1], "|") {
			if f != "--help" && f != "-h" {
				flags = append(flags, f)
			}
		}
	}
	if len(flags) < 20 {
		t.Fatalf("read only %d options from neodesk.sh: %v", len(flags), flags)
	}
	sort.Strings(flags)
	return flags
}

// fakeSetup is a folder with a neodesk-setup that writes "called" and its
// arguments, one per line, into record and exits with 7.
func fakeSetup(t *testing.T) (dir, record string) {
	t.Helper()
	dir = t.TempDir()
	record = filepath.Join(dir, "record")
	script := "#!/bin/sh\n{ echo called; for a in \"$@\"; do printf '%s\\n' \"$a\"; done; } > '" + record + "'\nexit 7\n"
	if err := os.WriteFile(filepath.Join(dir, "neodesk-setup"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir, record
}

// asNeodesk is the command that starts this binary as neodesk with args,
// finding programs only in pathDir and the system's folders.
func asNeodesk(t *testing.T, pathDir string, args ...string) *exec.Cmd {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("neodesk-setup is the Linux installer's")
	}
	if _, err := os.Stat("/usr/local/sbin/neodesk-setup"); err == nil {
		t.Skip("this machine has an installed neodesk-setup, which the binary would run")
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestStartedAsNeodeskHelper$")
	cmd.Env = append(os.Environ(), "NEODESK_TEST_AS_NEODESK=1", "NEODESK_TEST_ARGS="+strings.Join(args, "\n"),
		"PATH="+pathDir+string(os.PathListSeparator)+"/usr/bin:/bin")
	return cmd
}

// runAsNeodesk runs this binary as neodesk with args and returns its exit
// status and output.
func runAsNeodesk(t *testing.T, pathDir string, args ...string) (int, string, string) {
	t.Helper()
	cmd := asNeodesk(t, pathDir, args...)
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return 0, stdout.String(), stderr.String()
	case errors.As(err, &exit):
		return exit.ExitCode(), stdout.String(), stderr.String()
	}
	t.Fatalf("neodesk %v: %v", args, err)
	return 0, "", ""
}

// L431: neodesk is the command line, and the installer's manager is
// neodesk-setup. Every option of the installer given to neodesk goes to
// neodesk-setup with the arguments as they were, and its exit status
// comes back.
func TestTheInstallersFlagsGoToNeodeskSetup(t *testing.T) {
	dir, record := fakeSetup(t)
	for _, flag := range installerFlags(t) {
		_ = os.Remove(record)
		args := []string{flag, "two words", "--json"}
		if slices.Contains(setupNodeFlags, flag) {
			args = append(args, "--node")
		}
		code, _, stderr := runAsNeodesk(t, dir, args...)
		got, _ := os.ReadFile(record)
		want := "called\n" + strings.Join(args, "\n") + "\n"
		if code != 7 || string(got) != want {
			t.Errorf("neodesk %s: exit %d, neodesk-setup got %q, want %q (stderr %q)", flag, code, got, want, stderr)
		}
	}
}

// Everything else stays with the command line, also a bare neodesk that
// is not on a terminal.
func TestOtherCallsStayWithTheCommandLine(t *testing.T) {
	dir, record := fakeSetup(t)
	for _, args := range [][]string{{"--version"}, {"--help"}, {"devices", "--help"}, {"help"}, {}, {"--json", "--update"}} {
		_ = os.Remove(record)
		code, stdout, stderr := runAsNeodesk(t, dir, args...)
		if _, err := os.Stat(record); err == nil {
			t.Errorf("neodesk %v ran neodesk-setup", args)
		}
		if code == 7 || stdout+stderr == "" {
			t.Errorf("neodesk %v: exit %d, nothing from the command line", args, code)
		}
	}
}

// Where neodesk-setup is missing (the Docker image, Windows, a build of
// its own), an option of the installer ends with a message that names it
// and a non-zero exit.
func TestAnInstallerFlagWithoutNeodeskSetupSaysSo(t *testing.T) {
	empty := t.TempDir()
	for _, flag := range []string{"--update", "--reset-password", "-a"} {
		code, stdout, stderr := runAsNeodesk(t, empty, flag)
		if code == 0 || !strings.Contains(stderr, "neodesk-setup") || strings.Contains(stderr, "goroutine") {
			t.Errorf("neodesk %s without neodesk-setup: exit %d\nstdout %q\nstderr %q", flag, code, stdout, stderr)
		}
	}
}

// A bare `sudo neodesk` in a terminal opened the installer's menu, and
// still does: as root, with standard input and output on a terminal, it
// runs neodesk-setup without arguments.
func TestABareSudoNeodeskOnATerminalOpensTheMenu(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root")
	}
	scriptPath, err := exec.LookPath("script")
	if err != nil {
		t.Skip("needs script(1) for a terminal")
	}
	dir, record := fakeSetup(t)
	inner := asNeodesk(t, dir)
	// script(1) gives the child a terminal of its own; -e passes its exit on
	cmd := exec.Command(scriptPath, "-qec", "'"+inner.Path+"' '"+strings.Join(inner.Args[1:], "' '")+"'", "/dev/null")
	cmd.Env = inner.Env
	out, _ := cmd.CombinedOutput()
	got, _ := os.ReadFile(record)
	if string(got) != "called\n" {
		t.Errorf("a bare neodesk as root on a terminal: neodesk-setup got %q; output %q", got, out[:min(len(out), 200)])
	}
}

// The installer's options are kept once, in setupFlags and
// setupNodeFlags; a new option of neodesk.sh must go into one of them, or
// neodesk would take it for its own.
func TestSetupFlagsAreTheInstallers(t *testing.T) {
	got := slices.Sorted(slices.Values(slices.Concat(setupFlags, setupNodeFlags)))
	if want := installerFlags(t); !slices.Equal(got, want) {
		t.Errorf("setupFlags are %v,\nneodesk.sh takes %v", got, want)
	}
}

// Which calls go to neodesk-setup: a first argument that is the
// installer's, and a bare call as root on a terminal while neodesk-setup
// is there. A bare call of anybody else, or without a terminal, is the
// command line's (its help).
func TestWhichCallsGoToNeodeskSetup(t *testing.T) {
	type ran struct {
		path string
		args []string
	}
	for _, tc := range []struct {
		name           string
		args           []string
		root, terminal bool
		present        bool
		want           *ran
		wantCode       int
	}{
		{"bare, root on a terminal", nil, true, true, true, &ran{setupCommand, nil}, 7},
		{"bare, root without a terminal", nil, true, false, true, nil, 0},
		{"bare, a user on a terminal", nil, false, true, true, nil, 0},
		{"bare, root on a terminal without neodesk-setup", nil, true, true, false, nil, 0},
		{"--update", []string{"--update"}, false, false, true, &ran{setupCommand, []string{"--update"}}, 7},
		{"--update --channel dev", []string{"--update", "--channel", "dev"}, true, true, true, &ran{setupCommand, []string{"--update", "--channel", "dev"}}, 7},
		{"--update without neodesk-setup", []string{"--update"}, true, true, false, nil, ndcli.ExitUsage},
		{"--help", []string{"--help"}, true, true, true, nil, 0},
		{"devices list", []string{"devices", "list"}, true, true, true, nil, 0},
		{"--json --update", []string{"--json", "--update"}, true, true, true, nil, 0},
		{"--join --node", []string{"--join", "nd1.x", "--node"}, false, false, true, &ran{setupCommand, []string{"--join", "nd1.x", "--node"}}, 7},
		{"--lan-addr --node", []string{"--lan-addr", "10.0.0.5:21117", "--node"}, false, false, true, &ran{setupCommand, []string{"--lan-addr", "10.0.0.5:21117", "--node"}}, 7},
		{"--join, the client's", []string{"--join", "https://desk.example.com/join/ABCDEF23"}, true, true, true, nil, 0},
		{"--lan-addr without --node", []string{"--lan-addr", "10.0.0.5:21117"}, true, true, true, nil, 0},
		{"--forward --node", []string{"--forward", "--node"}, false, false, true, &ran{setupCommand, []string{"--forward", "--node"}}, 7},
		{"--forward without --node", []string{"--forward"}, true, true, true, nil, 0},
	} {
		var got *ran
		var stderr strings.Builder
		code, handled := handToSetup(tc.args, setupCall{
			root: tc.root, terminal: tc.terminal,
			find: func() (string, bool) { return setupCommand, tc.present },
			run: func(path string, args []string) int {
				got = &ran{path, args}
				return 7
			},
			stderr: &stderr,
		})
		if handled != (tc.want != nil || tc.wantCode != 0) || code != tc.wantCode {
			t.Errorf("%s: handled %v, exit %d, want exit %d", tc.name, handled, code, tc.wantCode)
		}
		switch {
		case tc.want == nil && got != nil:
			t.Errorf("%s: ran %s %v", tc.name, got.path, got.args)
		case tc.want != nil && (got == nil || got.path != tc.want.path || !slices.Equal(got.args, tc.want.args)):
			t.Errorf("%s: ran %+v, want %+v", tc.name, got, tc.want)
		}
		if tc.wantCode == ndcli.ExitUsage && !strings.Contains(stderr.String(), "neodesk-setup") {
			t.Errorf("%s: the message does not name neodesk-setup: %q", tc.name, stderr.String())
		}
	}
}
