package wire

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
)

// Forwarding (phase 3): a node at a site without internet access forwards
// the ID server's ports of the computers there to central. Each forwarded
// TCP connection is its own TLS connection to the control port with the
// node's certificate; its first frame is ForwardTCP, central answers
// ForwardOK (or Error) and then both sides send the raw bytes. UDP goes
// over one connection per node: ForwardUDP, ForwardOK, then Datagram
// frames both ways.

// Message types of forwarding.
const (
	TypeForwardTCP = "forward_tcp" // N, first frame of a forward connection
	TypeForwardUDP = "forward_udp" // N, first frame of the UDP connection
	TypeForwardOK  = "forward_ok"  // C, the forward is accepted
	TypeDatagram   = "udp"         // both ways on the UDP connection
)

// Services a node forwards. Central maps each to its own listener, so
// the node needs none of central's port numbers.
const (
	ServiceSignal = "signal" // TCP signal port (21116)
	ServiceNAT    = "nat"    // NAT test port (21115)
	ServiceWS     = "ws"     // WebSocket signal port (21118)
	ServiceAPI    = "api"    // HTTP API (21121)
)

// Error codes of a refused forward.
const (
	CodeNotOnline  = "not_online"  // the key's node has no control connection
	CodeBadForward = "bad_forward" // unknown service or client address
)

// ForwardTCP opens a forwarded TCP stream for the client at ClientAddr.
type ForwardTCP struct {
	Service    string `json:"service"`
	ClientAddr string `json:"client_addr"`
}

func (ForwardTCP) Type() string { return TypeForwardTCP }

// ForwardUDP opens the node's UDP forwarding connection.
type ForwardUDP struct{}

func (ForwardUDP) Type() string { return TypeForwardUDP }

// ForwardOK accepts a forward connection.
type ForwardOK struct{}

func (ForwardOK) Type() string { return TypeForwardOK }

// Datagram is one UDP datagram from (node to central) or to (central to
// node) the client at Addr.
type Datagram struct {
	Addr string `json:"addr"`
	Data []byte `json:"data"`
}

func (Datagram) Type() string { return TypeDatagram }

// ValidService says s is a service a node may forward.
func ValidService(s string) bool {
	switch s {
	case ServiceSignal, ServiceNAT, ServiceWS, ServiceAPI:
		return true
	}
	return false
}

// ParseClientAddr parses a forwarded client address: a unicast IP and a
// port other than 0. Loopback, unspecified, multicast and broadcast
// addresses are refused: no computer on a site network has them.
func ParseClientAddr(s string) (netip.AddrPort, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("client address %q: %w", s, err)
	}
	ip := ap.Addr().Unmap()
	if ap.Port() == 0 {
		return netip.AddrPort{}, fmt.Errorf("client address %q: port 0", s)
	}
	if !ip.IsValid() || ip.IsLoopback() || ip.IsUnspecified() || ip.IsMulticast() ||
		ip.IsInterfaceLocalMulticast() || ip == netip.AddrFrom4([4]byte{255, 255, 255, 255}) {
		return netip.AddrPort{}, errors.New("client address " + s + " is not a unicast address")
	}
	return netip.AddrPortFrom(ip, ap.Port()), nil
}

// TCPAddr is ap as a *net.TCPAddr.
func TCPAddr(ap netip.AddrPort) *net.TCPAddr { return net.TCPAddrFromAddrPort(ap) }

// UDPAddr is ap as a *net.UDPAddr.
func UDPAddr(ap netip.AddrPort) *net.UDPAddr { return net.UDPAddrFromAddrPort(ap) }
