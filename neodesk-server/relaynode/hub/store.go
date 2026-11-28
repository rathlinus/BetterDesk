// Package hub is the central side of the relay node control channel: the
// TLS listener nodes connect to, the registry of connected nodes, and a
// remote ticket store per node.
package hub

import (
	"crypto/ed25519"
	"crypto/tls"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// DefaultControlPort is the port of the control listener when
// NODE_CONTROL_PORT is not set. DESIGN.md names 21119, which RELAY_PORT+2
// (the relay's WebSocket) already takes, and 21120 is reserved as a port
// that never shipped, so the listener uses 21123.
const DefaultControlPort = 21123

// ControlPort reads NODE_CONTROL_PORT, DefaultControlPort when unset;
// 0 turns the control listener off.
func ControlPort(getenv func(string) string) (int, error) {
	v := getenv("NODE_CONTROL_PORT")
	if v == "" {
		return DefaultControlPort, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > 65535 {
		return 0, fmt.Errorf("NODE_CONTROL_PORT=%q is not a port", v)
	}
	return n, nil
}

// Node is a relay node as the hub needs it. Revoked is true once the node
// was revoked (relay_nodes.revoked_at set).
type Node struct {
	ID         string
	SiteID     string
	Name       string
	PublicKey  string // base64 Ed25519, wire.PublicKeyBase64
	LanAddr    string
	PublicAddr string
	Version    string
	CreatedAt  time.Time
	Revoked    bool
}

// Site is a site as the hub needs it.
type Site struct {
	ID    string
	OrgID string
	Name  string
}

// Store is the database and sites service behind the hub. The lead wires
// sites.Service and db.Database to it.
type Store interface {
	// ConsumeEnrollmentToken uses the one-use token (as the node sent it,
	// not hashed) for the node nodeID and returns its site. Unknown, used
	// and expired tokens are errors.
	ConsumeEnrollmentToken(token, nodeID string, now time.Time) (siteID string, err error)
	// GetRelayNodeByKey returns the node with the public key, nil and no
	// error when there is none.
	GetRelayNodeByKey(publicKey string) (*Node, error)
	CreateRelayNode(n *Node) error
	UpdateRelayNodeState(id, version, lanAddr, publicAddr string, seen time.Time) error
	// GetSite returns the site, nil and no error when it is gone.
	GetSite(id string) (*Site, error)
}

// Events receives what nodes report. The methods run on the node's
// connection goroutine and must not block for long.
type Events interface {
	NodeSessionStarted(nodeID, uuid string)
	NodeSessionEnded(nodeID, uuid string, up, down int64)
	NodeStats(nodeID string, s wire.Stats)
}

// ConnectEvents is optional on Events: NodeConnected runs when a node's
// control connection is up (central probes then).
type ConnectEvents interface {
	NodeConnected(nodeID string)
}

// ProbeEvents is optional on Events: the results of a probe the node was
// sent. They are the node's own claims; the receiver checks that it asked
// for them.
type ProbeEvents interface {
	NodeProbed(nodeID string, results []wire.ProbeResult)
}

// Auditor records security events: enrollment, failed authentication,
// ticket pushes in aggregate, revocation. Fields never hold secrets.
type Auditor interface {
	Audit(event string, fields map[string]string)
}

// Files of the central control certificate in the data dir.
const (
	CertFileName = "node_control.crt"
	KeyFileName  = "node_control.key"
)

// LoadOrCreateCert loads the central control certificate from dir, the
// server's data dir (where id_ed25519 is), or makes it once: an Ed25519
// key and a self-signed certificate, both 0600. pin is the SPKI sha256
// nodes pin.
func LoadOrCreateCert(dir string) (cert tls.Certificate, pin string, err error) {
	key, _, err := wire.LoadOrGenerateKey(filepath.Join(dir, KeyFileName))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	certPath := filepath.Join(dir, CertFileName)
	if b, err := os.ReadFile(certPath); err == nil {
		cert, err = wire.CertFromPEM(b, key)
		if err != nil {
			return tls.Certificate{}, "", fmt.Errorf("%s: %w", certPath, err)
		}
	} else if errors.Is(err, os.ErrNotExist) {
		cert, err = wire.SelfSignedCert(key, "neodesk node control")
		if err != nil {
			return tls.Certificate{}, "", err
		}
		if err := wire.WriteFileAtomic(certPath, wire.CertPEM(cert)); err != nil {
			return tls.Certificate{}, "", fmt.Errorf("%s: %w", certPath, err)
		}
	} else {
		return tls.Certificate{}, "", fmt.Errorf("%s: %w", certPath, err)
	}
	pin, err = wire.SPKIPin(key.Public().(ed25519.PublicKey))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	return cert, pin, nil
}

// SessionOwner is an optional part of Store: whether the node relayed the
// session uuid. The hub asks it for an ended report it holds no ticket
// for, which happens after a central restart (tickets live in memory).
type SessionOwner interface {
	NodeRelayedSession(nodeID, uuid string) bool
}
