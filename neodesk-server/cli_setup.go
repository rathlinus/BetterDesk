package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"syscall"

	"golang.org/x/term"

	"github.com/neodeskapp/neodesk/neodesk-server/ndcli"
)

// On Linux hosts the installer neodesk.sh installs itself as
// neodesk-setup, its manager, and neodesk is the command line. Up to
// 3.6.0-rc.4 the manager was called neodesk, so the command line hands it
// what was the manager's: a call whose first argument is one of the
// installer's options, and a bare `sudo neodesk` on a terminal, which
// opened the manager's menu.

// setupCommand is where neodesk.sh installs its manager (its
// MANAGER_COMMAND).
const setupCommand = "/usr/local/sbin/neodesk-setup"

// setupFlags are the options of neodesk.sh, without --help and -h
// (neodesk --help is the command line's) and without setupNodeFlags. A
// call that starts with one of them goes to neodesk-setup as it is.
// TestSetupFlagsAreTheInstallers compares the two lists with neodesk.sh's
// argument loop.
var setupFlags = []string{
	"--auto", "-a", "--skip-verify", "--minimal", "--uninstall", "--purge",
	"--check-permissions", "--check-capabilities", "--repair-permissions", "--set-config",
	"--nodejs", "--flask", "--update", "--reset-password", "--reset-two-factor",
	"--binary", "--from-source", "--channel", "--postgresql", "--postgres",
	"--relay-mode", "--relay-servers", "--relay", "--protocol", "--pg-uri",
	"--node",
}

// setupNodeFlags are the options of neodesk.sh that only qualify --node.
// The desktop client has a --join of its own, so a call that starts with
// one of them goes to neodesk-setup only when --node is in it too:
// `neodesk --join nd1.... --node`, `neodesk --forward --node`. Without
// --node it stays with the client or the command line.
var setupNodeFlags = []string{"--join", "--lan-addr", "--public-addr", "--forward"}

// isSetupCall reports whether args, not empty, are a call of the
// installer's.
func isSetupCall(args []string) bool {
	if slices.Contains(setupFlags, args[0]) {
		return true
	}
	return slices.Contains(setupNodeFlags, args[0]) && slices.Contains(args, "--node")
}

// setupCall is what the hand-over needs from the process. Tests replace it.
type setupCall struct {
	// root and terminal: the process runs as root, with standard input
	// and output on a terminal
	root, terminal bool
	// find returns neodesk-setup's path, or false when there is none
	find func() (string, bool)
	// run runs neodesk-setup with the arguments and returns its exit
	// status (on Linux it replaces this process and does not return)
	run    func(path string, args []string) int
	stderr io.Writer
}

// handToSetup runs neodesk-setup when `neodesk args...` is the manager's
// call, and reports whether it was. A bare call goes to the manager only
// as root on a terminal and when neodesk-setup is there; otherwise it is
// the command line's, which prints its help.
func handToSetup(args []string, c setupCall) (code int, handled bool) {
	if len(args) == 0 {
		if !c.root || !c.terminal {
			return 0, false
		}
		path, ok := c.find()
		if !ok {
			return 0, false
		}
		return c.run(path, nil), true
	}
	if !isSetupCall(args) {
		return 0, false
	}
	path, ok := c.find()
	if !ok {
		fmt.Fprintf(c.stderr, "neodesk: %s is an option of the installer, neodesk-setup, which is not on this machine.\n", args[0])
		fmt.Fprintln(c.stderr, setupElsewhere())
		return ndcli.ExitUsage, true
	}
	return c.run(path, args), true
}

// setupElsewhere says where the installer of an install without
// neodesk-setup is.
func setupElsewhere() string {
	if runtime.GOOS == "windows" {
		if dir := executableDir(); dir != "" {
			if _, err := os.Stat(filepath.Join(dir, "neodesk.ps1")); err == nil {
				return "On Windows the installer is " + filepath.Join(dir, "neodesk.ps1") + " (-Update, -Uninstall, ...). neodesk --help lists the command line."
			}
		}
		return "On Windows the installer is neodesk.ps1 in the server's folder (-Update, -Uninstall, ...). neodesk --help lists the command line."
	}
	return "Docker installs update with neodesk-docker.sh on the host, Linux hosts installed with neodesk.sh have " +
		setupCommand + ". neodesk --help lists the command line."
}

// executableDir is the folder of this binary, links followed.
func executableDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	return filepath.Dir(exe)
}

// osSetupCall is the process's own setupCall.
func osSetupCall() setupCall {
	return setupCall{
		root:     os.Geteuid() == 0,
		terminal: term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd())),
		find:     findSetup,
		run:      runSetup,
		stderr:   os.Stderr,
	}
}

// findSetup finds neodesk-setup where neodesk.sh installs it, else on
// the PATH. Windows has none: the installer there is neodesk.ps1.
func findSetup() (string, bool) {
	if runtime.GOOS == "windows" {
		return "", false
	}
	if st, err := os.Stat(setupCommand); err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0 {
		return setupCommand, true
	}
	if path, err := exec.LookPath("neodesk-setup"); err == nil {
		return path, true
	}
	return "", false
}

// runSetup runs neodesk-setup in place of this process, so its terminal,
// signals and exit status are the user's own. NEODESK_SETUP_CALLED_AS
// tells it the call was neodesk's, so it names that call when it needs
// root.
func runSetup(path string, args []string) int {
	err := syscall.Exec(path, append([]string{path}, args...), append(os.Environ(), "NEODESK_SETUP_CALLED_AS=neodesk"))
	// Only a failed exec comes back
	fmt.Fprintf(os.Stderr, "neodesk: could not start %s: %v\n", path, err)
	return ndcli.ExitFailed
}
