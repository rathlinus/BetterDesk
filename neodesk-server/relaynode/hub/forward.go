package hub

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Defaults of the forward limits (D20).
const (
	DefaultForwardPerMinute      = 6000  // forward connections per node and minute
	DefaultForwardOpenMax        = 2048  // open forward connections per node
	DefaultForwardPerIPMinute    = 600   // forward connections per node, client IP and minute
	DefaultDatagramsPerMinute    = 20000 // datagrams per node and minute
	DefaultDatagramsPerIPMinute  = 1200  // datagrams per node, client IP and minute
	forwardLimitsMaxTrackedAddrs = 65536
)

// Reasons a forward is refused, for the audit's refused_<reason> counts.
const (
	ForwardRefusedNotOnline = "not_online"   // no control connection for the key
	ForwardRefusedBad       = "bad_forward"  // unknown service, bad client address
	ForwardRefusedRate      = "rate_limited" // past a per-node or per-IP limit
	ForwardRefusedOff       = "off"          // this server forwards nothing
)

// Forwarder receives the streams relay nodes forward for the computers
// at their sites (phase 3). Both methods run on the forward connection's
// goroutine and return when the stream is over.
type Forwarder interface {
	// ForwardTCP serves one TCP stream of service (wire.Service*). c's
	// RemoteAddr is the computer's address as the node saw it. The
	// receiver closes c.
	ForwardTCP(nodeID, service string, c net.Conn)
	// ForwardUDP serves the node's UDP connection until ch fails.
	ForwardUDP(nodeID string, ch *UDPChannel)
}

// forwardedConn is a forward connection whose remote address is the
// computer's.
type forwardedConn struct {
	net.Conn
	remote *net.TCPAddr
	node   string
}

func (c *forwardedConn) RemoteAddr() net.Addr { return c.remote }

// ForwardNode is the node the connection came through.
func (c *forwardedConn) ForwardNode() string { return c.node }

// onlineNodeByKey is the id of the node with the client key that has a
// control connection now, "" for none (D20).
func (h *Hub) onlineNodeByKey(key string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	for id, n := range h.nodes {
		if n.conn != nil && n.conn.key == key {
			return id
		}
	}
	return ""
}

// serveForward runs a forward connection whose first frame f is
// forward_tcp or forward_udp. The client address in it is used only when
// the key belongs to a node that is online.
func (h *Hub) serveForward(tc *tls.Conn, c *wire.Conn, ip, key string, f wire.Frame) {
	nodeID := h.onlineNodeByKey(key)
	if nodeID == "" {
		h.refuseForward(c, ip, "", ForwardRefusedNotOnline, wire.CodeNotOnline, "the node is not enrolled or not connected")
		return
	}
	if h.cfg.Forwarder == nil {
		h.refuseForward(c, ip, nodeID, ForwardRefusedOff, wire.CodeBadForward, "this server takes no forwarded traffic")
		return
	}
	_ = tc.SetDeadline(time.Time{})
	switch f.Type {
	case wire.TypeForwardTCP:
		var m wire.ForwardTCP
		if f.Decode(&m) != nil || !wire.ValidService(m.Service) {
			h.refuseForward(c, ip, nodeID, ForwardRefusedBad, wire.CodeBadForward, "unknown service")
			return
		}
		client, err := wire.ParseClientAddr(m.ClientAddr)
		if err == nil && !h.forwardClientAllowed(nodeID, client) {
			err = errClientOutsideSite
		}
		if err != nil {
			h.refuseForward(c, ip, nodeID, ForwardRefusedBad, wire.CodeBadForward, err.Error())
			return
		}
		if !h.fwd.allowConn(nodeID, client.Addr(), h.cfg.Now()) {
			h.countForward(nodeID, func(fc *forwardCounts) { fc.refused(ForwardRefusedRate) })
			_ = c.Write(wire.Error{Code: wire.CodeRateLimited, Msg: "too many forwarded connections"}, closeTimeout)
			c.Close()
			return
		}
		defer h.fwd.closed(nodeID)
		if err := c.Write(wire.ForwardOK{}, writeTimeout); err != nil {
			c.Close()
			return
		}
		fc := &forwardedConn{Conn: tc, remote: wire.TCPAddr(client), node: nodeID}
		if !h.trackForward(nodeID, fc) {
			c.Close()
			return
		}
		defer h.untrackForward(nodeID, fc)
		h.countForward(nodeID, func(fc *forwardCounts) { fc.tcp[m.Service]++ })
		h.cfg.Forwarder.ForwardTCP(nodeID, m.Service, fc)
	case wire.TypeForwardUDP:
		if err := c.Write(wire.ForwardOK{}, writeTimeout); err != nil {
			c.Close()
			return
		}
		ch := &UDPChannel{h: h, node: nodeID, c: c}
		if !h.trackForward(nodeID, tc) {
			c.Close()
			return
		}
		defer h.untrackForward(nodeID, tc)
		h.cfg.Logf("[nodes] Node %s opened its UDP forwarding", nodeID)
		h.cfg.Forwarder.ForwardUDP(nodeID, ch)
		c.Close()
	}
}

func (h *Hub) refuseForward(c *wire.Conn, ip, nodeID, reason, code, msg string) {
	h.cfg.Logf("[nodes] Refused forward connection from %s: %s (%s)", ip, reason, msg)
	fields := map[string]string{"remote": ip, "reason": reason}
	if nodeID != "" {
		fields["node_id"] = nodeID
		h.countForward(nodeID, func(fc *forwardCounts) { fc.refused(reason) })
	}
	h.audit("relay_node.forward_refused", fields)
	_ = c.Write(wire.Error{Code: code, Msg: msg}, closeTimeout)
	c.Close()
}

// trackForward remembers a forward connection of the node so Disconnect
// closes it; false when the node went offline meanwhile.
func (h *Hub) trackForward(nodeID string, c net.Conn) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := h.nodes[nodeID]
	if n == nil || n.conn == nil {
		return false
	}
	if n.forwards == nil {
		n.forwards = make(map[net.Conn]struct{})
	}
	n.forwards[c] = struct{}{}
	return true
}

func (h *Hub) untrackForward(nodeID string, c net.Conn) {
	h.mu.Lock()
	if n := h.nodes[nodeID]; n != nil {
		delete(n.forwards, c)
	}
	h.mu.Unlock()
}

// closeForwardsLocked closes every forward connection of n.
func (n *nodeState) closeForwardsLocked() {
	for c := range n.forwards {
		c.Close()
	}
	n.forwards = nil
}

// forwardCounts are a node's forwards since the last audit.
type forwardCounts struct {
	tcp       map[string]int64 // by service
	datagrams int64            // node to central
	refusedBy map[string]int64
}

func (fc *forwardCounts) refused(reason string) {
	if fc.refusedBy == nil {
		fc.refusedBy = make(map[string]int64)
	}
	fc.refusedBy[reason]++
}

func (fc *forwardCounts) empty() bool {
	return len(fc.tcp) == 0 && fc.datagrams == 0 && len(fc.refusedBy) == 0
}

func (h *Hub) countForward(nodeID string, f func(*forwardCounts)) {
	h.mu.Lock()
	n := h.state(nodeID)
	if n.fwdCounts.tcp == nil {
		n.fwdCounts.tcp = make(map[string]int64)
	}
	f(&n.fwdCounts)
	h.mu.Unlock()
}

// ForwardedStreams is how many forward connections of the node are
// open (TCP streams and its UDP connection).
func (h *Hub) ForwardedStreams(nodeID string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	if n := h.nodes[nodeID]; n != nil {
		return len(n.forwards)
	}
	return 0
}

// UDPChannel is a node's UDP forwarding connection: datagrams of the
// computers behind the node, each with its address.
type UDPChannel struct {
	h    *Hub
	node string
	c    *wire.Conn
}

// Node is the id of the channel's node.
func (ch *UDPChannel) Node() string { return ch.node }

// ReadPacket returns the next datagram the node forwarded and the
// computer's address. Datagrams with a bad address or past the limits
// are dropped and counted.
func (ch *UDPChannel) ReadPacket() (*net.UDPAddr, []byte, error) {
	h := ch.h
	for {
		f, err := ch.c.Read(0)
		if err != nil {
			return nil, nil, err
		}
		if f.Type != wire.TypeDatagram {
			continue
		}
		var d wire.Datagram
		if json.Unmarshal(f.Body, &d) != nil {
			continue
		}
		client, err := wire.ParseClientAddr(d.Addr)
		if err != nil || !h.forwardClientAllowed(ch.node, client) {
			h.countForward(ch.node, func(fc *forwardCounts) { fc.refused(ForwardRefusedBad) })
			continue
		}
		if !h.fwd.allowDatagram(ch.node, client.Addr(), h.cfg.Now()) {
			h.countForward(ch.node, func(fc *forwardCounts) { fc.refused(ForwardRefusedRate) })
			continue
		}
		h.countForward(ch.node, func(fc *forwardCounts) { fc.datagrams++ })
		return wire.UDPAddr(client), d.Data, nil
	}
}

// WritePacket sends a datagram to the computer at to through the node.
func (ch *UDPChannel) WritePacket(to *net.UDPAddr, data []byte) error {
	if to == nil {
		return errors.New("no address")
	}
	ap := to.AddrPort()
	return ch.c.Write(wire.Datagram{Addr: netip.AddrPortFrom(ap.Addr().Unmap(), ap.Port()).String(), Data: data}, writeTimeout)
}

// Close closes the channel.
func (ch *UDPChannel) Close() error { return ch.c.Close() }

// forwardLimits are the per-node and per-IP windows of D20.
type forwardLimits struct {
	perMinute, openMax, perIPMinute int
	dgPerMinute, dgPerIPMinute      int

	mu    sync.Mutex
	conns map[string]*window      // node id -> connections this minute
	open  map[string]int          // node id -> open connections
	ips   map[ipWindowKey]*window // (node, ip) -> connections this minute
	dgs   map[string]*window
	dgIPs map[ipWindowKey]*window
}

type ipWindowKey struct {
	node string
	ip   netip.Addr
}

func newForwardLimits(cfg Config) *forwardLimits {
	l := &forwardLimits{
		perMinute: cfg.ForwardPerMinute, openMax: cfg.ForwardOpenMax, perIPMinute: cfg.ForwardPerIPMinute,
		dgPerMinute: cfg.DatagramsPerMinute, dgPerIPMinute: cfg.DatagramsPerIPMinute,
		conns: map[string]*window{}, open: map[string]int{}, ips: map[ipWindowKey]*window{},
		dgs: map[string]*window{}, dgIPs: map[ipWindowKey]*window{},
	}
	if l.perMinute <= 0 {
		l.perMinute = DefaultForwardPerMinute
	}
	if l.openMax <= 0 {
		l.openMax = DefaultForwardOpenMax
	}
	if l.perIPMinute <= 0 {
		l.perIPMinute = DefaultForwardPerIPMinute
	}
	if l.dgPerMinute <= 0 {
		l.dgPerMinute = DefaultDatagramsPerMinute
	}
	if l.dgPerIPMinute <= 0 {
		l.dgPerIPMinute = DefaultDatagramsPerIPMinute
	}
	return l
}

// tick counts one event in the window of key and says it is within max.
func tick[K comparable](m map[K]*window, key K, now time.Time, max int) bool {
	w := m[key]
	if w == nil || now.Sub(w.start) >= time.Minute {
		if len(m) >= forwardLimitsMaxTrackedAddrs {
			for k, old := range m {
				if now.Sub(old.start) >= time.Minute {
					delete(m, k)
				}
			}
		}
		w = &window{start: now}
		m[key] = w
	}
	w.count++
	return w.count <= max
}

// allowConn counts a new forward connection; false past a limit. A true
// answer must be followed by closed when the connection ends.
func (l *forwardLimits) allowConn(node string, ip netip.Addr, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.open[node] >= l.openMax {
		return false
	}
	okNode := tick(l.conns, node, now, l.perMinute)
	okIP := tick(l.ips, ipWindowKey{node, ip}, now, l.perIPMinute)
	if !okNode || !okIP {
		return false
	}
	l.open[node]++
	return true
}

func (l *forwardLimits) closed(node string) {
	l.mu.Lock()
	if l.open[node] > 0 {
		l.open[node]--
	}
	if l.open[node] == 0 {
		delete(l.open, node)
	}
	l.mu.Unlock()
}

func (l *forwardLimits) allowDatagram(node string, ip netip.Addr, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	okNode := tick(l.dgs, node, now, l.dgPerMinute)
	okIP := tick(l.dgIPs, ipWindowKey{node, ip}, now, l.dgPerIPMinute)
	return okNode && okIP
}

// ForwardClientChecker is optional on Store: whether a node may speak for
// a computer at an address. Without it every unicast address passes.
type ForwardClientChecker interface {
	ForwardClientAllowed(nodeID string, ip net.IP) bool
}

var errClientOutsideSite = errors.New("the client address is neither private nor in a network of the node's site")

func (h *Hub) forwardClientAllowed(nodeID string, client netip.AddrPort) bool {
	fc, ok := h.cfg.Store.(ForwardClientChecker)
	if !ok {
		return true
	}
	return fc.ForwardClientAllowed(nodeID, net.IP(client.Addr().AsSlice()))
}
