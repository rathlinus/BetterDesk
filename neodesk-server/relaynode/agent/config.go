// Package agent is MODE=node: a relay node that enrolls with the central
// server, keeps a control connection to it and relays the sessions whose
// tickets central pushes. It has no database, console or signal server.
package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/config"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Config sets up an Agent.
type Config struct {
	Join         string // NODE_JOIN: the enrollment string, first start
	DataDir      string // NODE_DATA_DIR: node.key and node.json
	LanAddr      string // NODE_LAN_ADDR: relay TCP host:port on the LAN; the control connection's local address when empty
	PublicAddr   string // NODE_PUBLIC_ADDR: relay TCP host:port clients outside dial
	WSLanAddr    string // NODE_WS_LAN_ADDR: LanAddr's port + 2 when empty
	WSPublicAddr string // NODE_WS_PUBLIC_ADDR: PublicAddr's port + 2 when empty
	// LegPort is NODE_LEG_PORT: the TLS port other nodes of the
	// organization dial for sessions between two sites (0: off).
	// ConfigFromEnv sets wire.DefaultLegPort when it is unset.
	LegPort int
	// LegListen overrides the leg listener's address (tests); ":LegPort"
	// when empty.
	LegListen string
	// LegLanAddr and LegPublicAddr are where other nodes reach the leg
	// listener (NODE_LEG_LAN_ADDR, NODE_LEG_PUBLIC_ADDR): the host of
	// LanAddr or PublicAddr with LegPort when empty, none when "none".
	LegLanAddr    string
	LegPublicAddr string
	// Limits of the leg listener per remote address and minute:
	// connections (DefaultLegsPerMinute) and refused legs
	// (DefaultLegRefusalsLimit); past either the address is refused
	// until the minute is over.
	LegsPerMinute    int
	LegRefusalsLimit int
	// Forward is NODE_FORWARD=Y: the node forwards the ID server's ports
	// (signal, NAT test, WebSocket signal, API) of the computers at its
	// site to central, for a site without internet access (D19).
	Forward bool
	// ForwardSignalPort is NODE_FORWARD_SIGNAL_PORT (21116 when 0): TCP
	// and UDP signal; the NAT test listens one below, WebSocket signal
	// two above. ForwardAPIPort is NODE_FORWARD_API_PORT (21121 when 0).
	ForwardSignalPort int
	ForwardAPIPort    int
	// ForwardListen is NODE_FORWARD_LISTEN, the host the forward
	// listeners bind: the host of LanAddr when empty, else every address.
	ForwardListen string
	// ClientAddr overrides the computer's address the node sends central
	// (tests, whose computers are all on loopback); the address as is
	// when nil.
	ClientAddr func(net.Addr) string
	Relay      *config.Config // relay ports and limits (RELAY_PORT, RELAY_MAX_CONNS_IP, ...)
	Version    string
	Logf       func(format string, args ...any) // log.Printf when nil
	Ready      func()                           // called once the relay listens

	StatsInterval time.Duration // 30 s when 0
	IdleTimeout   time.Duration // 45 s when 0: silence from central ends the connection
	BackoffMin    time.Duration // 1 s when 0
	BackoffMax    time.Duration // 60 s when 0
}

// ConfigFromEnv reads the NODE_* variables. The data dir defaults to the
// directory of the server's key file (KEY_FILE), the server's data dir.
func ConfigFromEnv(getenv func(string) string, relayCfg *config.Config) Config {
	dataDir := getenv("NODE_DATA_DIR")
	if dataDir == "" && relayCfg != nil {
		dataDir = filepath.Dir(relayCfg.KeyFile)
	}
	legPort, err := wire.LegPort(getenv)
	if err != nil {
		legPort = wire.DefaultLegPort
	}
	fwdSignal, _ := strconv.Atoi(getenv("NODE_FORWARD_SIGNAL_PORT"))
	fwdAPI, _ := strconv.Atoi(getenv("NODE_FORWARD_API_PORT"))
	return Config{
		Forward:           envOn(getenv("NODE_FORWARD")),
		ForwardSignalPort: fwdSignal,
		ForwardAPIPort:    fwdAPI,
		ForwardListen:     getenv("NODE_FORWARD_LISTEN"),
		LegPort:           legPort,
		LegLanAddr:        getenv("NODE_LEG_LAN_ADDR"),
		LegPublicAddr:     getenv("NODE_LEG_PUBLIC_ADDR"),
		Join:              getenv("NODE_JOIN"),
		DataDir:           dataDir,
		LanAddr:           getenv("NODE_LAN_ADDR"),
		PublicAddr:        getenv("NODE_PUBLIC_ADDR"),
		WSLanAddr:         getenv("NODE_WS_LAN_ADDR"),
		WSPublicAddr:      getenv("NODE_WS_PUBLIC_ADDR"),
		Relay:             relayCfg,
	}
}

// envOn reads a yes/no variable: Y, yes, true, on or 1 are yes.
func envOn(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "y", "yes", "true", "on", "1":
		return true
	}
	return false
}

// Files in the data dir.
const (
	KeyFileName   = "node.key"
	StateFileName = "node.json"
)

// State is what the node keeps after enrollment (node.json, 0600).
type State struct {
	NodeID string `json:"node_id"`
	SiteID string `json:"site_id"`
	Server string `json:"server"`
	Pin    string `json:"pin"`
	// JoinHash is the sha256 of the enrollment string it enrolled with, so
	// a NODE_JOIN that stays in the environment is not used again
	JoinHash string `json:"join_hash"`
}

func loadState(path string) (*State, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if s.NodeID == "" || s.Server == "" || s.Pin == "" {
		return nil, fmt.Errorf("%s: incomplete", path)
	}
	return &s, nil
}

func saveState(path string, s *State) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return wire.WriteFileAtomic(path, append(b, '\n'))
}

func joinHash(join string) string {
	sum := sha256.Sum256([]byte(join))
	return hex.EncodeToString(sum[:])
}

// legAddrFor is the leg address to report: set when set ("none" for
// none), else the host of relayAddr with port, "" without a relay address.
func legAddrFor(set, relayAddr string, port int) string {
	if set == "none" {
		return ""
	}
	if set != "" {
		return set
	}
	host, _, err := net.SplitHostPort(relayAddr)
	if err != nil || host == "" || port <= 0 {
		return ""
	}
	return net.JoinHostPort(host, strconv.Itoa(port))
}

// listenAddr is where a listener on port listens: every address, or
// 127.0.0.1 in tests.
func listenAddr(port int) string { return config.ListenAddr(port) }

// plusTwo is addr with its port + 2 (the WebSocket relay), "" for "".
func plusTwo(addr string) string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return ""
	}
	n, err := strconv.Atoi(port)
	if err != nil {
		return ""
	}
	return net.JoinHostPort(host, strconv.Itoa(n+2))
}
