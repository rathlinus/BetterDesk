package wire

import (
	"crypto/ed25519"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strconv"
)

// DefaultLegPort is the port of a node's leg listener when NODE_LEG_PORT
// is not set: other nodes of the organization dial it to join the two
// halves of a session between two sites. 21124 is the cluster port, so
// the next free one near the relay ports.
const DefaultLegPort = 21125

// LegPort reads NODE_LEG_PORT, DefaultLegPort when unset; 0 turns the leg
// listener off (the node then takes no sessions from other sites' nodes,
// but still dials them).
func LegPort(getenv func(string) string) (int, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	v := getenv("NODE_LEG_PORT")
	if v == "" {
		return DefaultLegPort, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > 65535 {
		return 0, fmt.Errorf("NODE_LEG_PORT=%q is not a port", v)
	}
	return n, nil
}

// ErrLegKey is the TLS error when the other node's key is not the one
// central named.
var ErrLegKey = errors.New("the other node's key is not the one central named")

// DecodePublicKey parses a key in the form relay_nodes.public_key stores
// (standard base64 of an Ed25519 public key).
func DecodePublicKey(b64 string) (ed25519.PublicKey, error) {
	b, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(b) != ed25519.PublicKeySize {
		return nil, errors.New("not an Ed25519 public key")
	}
	return ed25519.PublicKey(b), nil
}

// LegServerTLS is the leg listener's TLS config: TLS 1.3, it presents the
// node's own certificate and requires a client certificate with an
// Ed25519 key. Which keys may bring a leg is the ticket's business (the
// peer_key central pushed), checked after the handshake.
func LegServerTLS(cert tls.Certificate) *tls.Config {
	c := ServerTLS(cert)
	c.NextProtos = []string{legALPN}
	return c
}

// LegClientTLS is the dialing node's TLS config: TLS 1.3, it presents the
// node's own certificate and accepts only a server whose Ed25519 key is
// peer, the key central named for the other node.
func LegClientTLS(cert tls.Certificate, peer ed25519.PublicKey) *tls.Config {
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
		Certificates:       []tls.Certificate{cert},
		NextProtos:         []string{legALPN},
		InsecureSkipVerify: true, // the key check below replaces chain verification
		VerifyConnection: func(cs tls.ConnectionState) error {
			got, err := PeerKey(cs)
			if err != nil {
				return ErrLegKey
			}
			if len(peer) != ed25519.PublicKeySize || subtle.ConstantTimeCompare(got, peer) != 1 {
				return ErrLegKey
			}
			return nil
		},
	}
}

// legALPN names the protocol on the leg port, so a relay or another TLS
// service reached there by mistake fails the handshake.
const legALPN = "neodesk-leg/1"

// SameKey compares two keys in relay_nodes.public_key form in constant
// time; an empty key matches nothing.
func SameKey(a, b string) bool {
	if a == "" || b == "" || len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
