package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/codec"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Legs: a session between two sites runs client A -> node A -> TLS ->
// node B -> client B. Central pushes node B an accept ticket naming node
// A's key and node A a dial ticket naming node B's leg address and key.
// When client A's connection claims at node A, node A dials node B, sends
// RequestRelay{uuid} over the TLS connection and pairs client A with it;
// node B checks the dialer's key against its ticket and pairs the leg with
// client B. Each node's relay counts the bytes and reports the session.

const (
	legHandshakeTimeout = 5 * time.Second
	legDialTimeout      = 5 * time.Second
	probeTimeout        = 3 * time.Second
	maxProbeTargets     = 64
	probeParallel       = 8
	// legWindowLen is the rate limit window of the leg listener
	legWindowLen = time.Minute
	// maxLegHandshakes bounds the leg connections in their handshake at once
	maxLegHandshakes = 64
)

// Defaults of the leg listener's limits, per remote address and minute.
const (
	DefaultLegsPerMinute    = 600
	DefaultLegRefusalsLimit = 20
)

// legTicket is the leg part of a pushed ticket.
type legTicket struct {
	role     string
	peerAddr string
	peerKey  string
	expires  time.Time
	// plain counts the claims of connections on the relay port: one, the
	// node's own client; the other side is the leg
	plain int
	// leg is set once the leg was taken (accept) or dialled (dial)
	leg bool
	// dead: cancelled by central, or a side gave up; no more claims
	dead bool
}

// gate is the ticket store the node's relay claims from: the pushed
// tickets, where a ticket with a leg takes one claim from the relay port
// only. Without it, anyone who knows the uuid could take the second side
// on the relay port and bypass the leg's key check.
type gate struct {
	a   *Agent
	reg *relay.AuthorizationRegistry

	mu   sync.Mutex
	legs map[string]*legTicket
}

var _ relay.TicketClaims = (*gate)(nil)

func newGate(a *Agent, reg *relay.AuthorizationRegistry) *gate {
	return &gate{a: a, reg: reg, legs: make(map[string]*legTicket)}
}

func (g *gate) pruneLocked(now time.Time) {
	for id, lt := range g.legs {
		if !lt.expires.After(now) && !lt.leg {
			delete(g.legs, id)
		}
	}
}

// add records the leg of a ticket the registry took.
func (g *gate) add(uuid string, lt *legTicket) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.pruneLocked(time.Now())
	g.legs[uuid] = lt
}

// forget makes uuid a ticket without a leg again (central moved the
// session to this node alone after the pair failed).
func (g *gate) forget(uuid string) {
	g.mu.Lock()
	delete(g.legs, uuid)
	g.mu.Unlock()
}

// cancel stops every further claim of uuid.
func (g *gate) cancel(uuid string) {
	g.mu.Lock()
	if lt := g.legs[uuid]; lt != nil {
		lt.dead = true
	}
	g.mu.Unlock()
}

func (g *gate) has(uuid string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.legs[uuid] != nil
}

// Claim is a claim from the relay port.
func (g *gate) Claim(uuid string) bool {
	g.mu.Lock()
	lt := g.legs[uuid]
	if lt == nil {
		g.mu.Unlock()
		return g.reg.Claim(uuid)
	}
	if lt.dead || lt.plain >= 1 {
		g.mu.Unlock()
		return false
	}
	if !g.reg.Claim(uuid) {
		g.mu.Unlock()
		return false
	}
	lt.plain++
	dial := lt.role == wire.LegDial && !lt.leg
	if dial {
		lt.leg = true
	}
	addr, key := lt.peerAddr, lt.peerKey
	g.mu.Unlock()
	if dial {
		go g.a.dialLeg(uuid, addr, key)
	}
	return true
}

// Release returns a claim whose partner never came. For a session with a
// leg that ends it: the ticket lives as long as a side may wait.
func (g *gate) Release(uuid string) {
	g.mu.Lock()
	if lt := g.legs[uuid]; lt != nil {
		lt.dead = true
	}
	g.mu.Unlock()
	g.reg.Release(uuid)
}

func (g *gate) WaitForAuthorization(ctx context.Context, uuid string) bool {
	return g.reg.WaitForAuthorization(ctx, uuid)
}

func (g *gate) End(uuid string) {
	g.forget(uuid)
	g.reg.End(uuid)
}

func (g *gate) Live(uuid string) (relay.LivePair, bool) { return g.reg.Live(uuid) }

// takeLeg checks a leg that arrived from the node with key for uuid and
// claims its side. reason is the refusal, "" when the leg may pair.
func (g *gate) takeLeg(uuid, key string) (reason string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	lt := g.legs[uuid]
	if lt == nil || lt.role != wire.LegAccept || lt.dead || lt.leg || !lt.expires.After(time.Now()) {
		return wire.LegRefusedNoTicket
	}
	if !wire.SameKey(lt.peerKey, key) {
		return wire.LegRefusedWrongKey
	}
	if !g.reg.Claim(uuid) {
		return wire.LegRefusedNoTicket
	}
	lt.leg = true
	return ""
}

// legConn is a leg as the relay sees it: its address names the leg, not
// the other node's IP, so the relay's per-IP session limit counts the
// clients at both ends and not every session between two sites as one
// address.
type legConn struct {
	net.Conn
	name string
}

func (c *legConn) RemoteAddr() net.Addr { return legAddr(c.name) }

type legAddr string

func (a legAddr) Network() string { return "tcp" }
func (a legAddr) String() string  { return string(a) }

func shortUUID(uuid string) string {
	if len(uuid) > 8 {
		return uuid[:8]
	}
	return uuid
}

// ---- dialing side ----

// dialLeg dials the other node for uuid and pairs the leg with the client
// that claimed. When it can't, the waiting client is dropped at once.
func (a *Agent) dialLeg(uuid, addr, keyB64 string) {
	conn, err := a.openLeg(uuid, addr, keyB64)
	if err != nil {
		a.cfg.Logf("[node] Leg of UUID %s to %s failed: %v", shortUUID(uuid), addr, err)
		a.gate.cancel(uuid)
		if a.srv != nil {
			a.srv.DropPending(uuid)
		}
		return
	}
	if !a.reg.Claim(uuid) {
		conn.Close()
		a.cfg.Logf("[node] Leg of UUID %s to %s: the ticket is gone", shortUUID(uuid), addr)
		if a.srv != nil {
			a.srv.DropPending(uuid)
		}
		return
	}
	a.cfg.Logf("[node] Leg of UUID %s to %s open", shortUUID(uuid), addr)
	a.srv.ServeClaimed(&legConn{Conn: conn, name: "leg-to/" + shortUUID(uuid)}, uuid)
}

func (a *Agent) openLeg(uuid, addr, keyB64 string) (net.Conn, error) {
	key, err := wire.DecodePublicKey(keyB64)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), legDialTimeout)
	defer cancel()
	tc, _, err := a.handshakeLeg(ctx, addr, key)
	if err != nil {
		return nil, err
	}
	_ = tc.SetWriteDeadline(time.Now().Add(legDialTimeout))
	err = codec.WriteRawProto(tc, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{Uuid: uuid}}})
	_ = tc.SetWriteDeadline(time.Time{})
	if err != nil {
		tc.Close()
		return nil, err
	}
	return tc, nil
}

// handshakeLeg opens a TLS connection to the leg listener at addr that
// must show key. rtt is the TCP connect time.
func (a *Agent) handshakeLeg(ctx context.Context, addr string, key ed25519.PublicKey) (*tls.Conn, time.Duration, error) {
	d := net.Dialer{}
	start := time.Now()
	raw, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, 0, err
	}
	rtt := time.Since(start)
	tc := tls.Client(raw, wire.LegClientTLS(a.cert, key))
	if err := tc.HandshakeContext(ctx); err != nil {
		raw.Close()
		return nil, 0, err
	}
	return tc, rtt, nil
}

// ---- accepting side ----

// legListener takes legs from other nodes.
type legListener struct {
	a  *Agent
	ln net.Listener
	wg sync.WaitGroup

	busy chan struct{} // handshakes in flight

	mu     sync.Mutex
	window map[string]*legWindow

	accepted atomic.Int64
	refusedM sync.Mutex
	refused  map[string]int64
	probes   atomic.Int64
}

type legWindow struct {
	start          time.Time
	conns, refused int
}

func (a *Agent) startLegListener(ctx context.Context) error {
	if a.cfg.LegPort <= 0 {
		return nil
	}
	addr := a.cfg.LegListen
	if addr == "" {
		addr = listenAddr(a.cfg.LegPort)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("leg listener: listen %s: %w", addr, err)
	}
	l := &legListener{a: a, ln: ln, busy: make(chan struct{}, maxLegHandshakes), window: map[string]*legWindow{}, refused: map[string]int64{}}
	a.mu.Lock()
	a.legs = l
	a.mu.Unlock()
	l.wg.Add(1)
	go l.accept()
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	a.cfg.Logf("[node] Leg listener on %s (TLS 1.3, node keys)", ln.Addr())
	return nil
}

// LegAddr is the leg listener's address, nil when it is off.
func (a *Agent) LegAddr() net.Addr {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.legs == nil {
		return nil
	}
	return a.legs.ln.Addr()
}

func (l *legListener) accept() {
	defer l.wg.Done()
	for {
		c, err := l.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go l.serve(c)
	}
}

// allow counts a connection from ip; false past the limits.
func (l *legListener) allow(ip string) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.window) > 4096 {
		for k, w := range l.window {
			if now.Sub(w.start) >= legWindowLen {
				delete(l.window, k)
			}
		}
	}
	w := l.window[ip]
	if w == nil || now.Sub(w.start) >= legWindowLen {
		w = &legWindow{start: now}
		l.window[ip] = w
	}
	w.conns++
	return w.conns <= l.a.cfg.LegsPerMinute && w.refused < l.a.cfg.LegRefusalsLimit
}

// refuse counts and logs a refused leg; keys never appear.
func (l *legListener) refuse(c net.Conn, ip, reason, uuid string) {
	defer c.Close()
	l.refusedM.Lock()
	l.refused[reason]++
	l.refusedM.Unlock()
	if reason != wire.LegRefusedRate {
		l.mu.Lock()
		if w := l.window[ip]; w != nil {
			w.refused++
		}
		l.mu.Unlock()
	}
	if uuid != "" {
		l.a.cfg.Logf("[node] Refused a leg from %s: %s (UUID %s)", ip, reason, shortUUID(uuid))
	} else {
		l.a.cfg.Logf("[node] Refused a leg from %s: %s", ip, reason)
	}
}

func (l *legListener) counts() (accepted int64, refused map[string]int64) {
	l.refusedM.Lock()
	defer l.refusedM.Unlock()
	refused = make(map[string]int64, len(l.refused))
	for k, v := range l.refused {
		refused[k] = v
	}
	return l.accepted.Load(), refused
}

func (l *legListener) serve(raw net.Conn) {
	ip := remoteIP(raw)
	if !l.allow(ip) {
		l.refuse(raw, ip, wire.LegRefusedRate, "")
		return
	}
	select {
	case l.busy <- struct{}{}:
	default:
		l.refuse(raw, ip, wire.LegRefusedRate, "")
		return
	}
	tc := tls.Server(raw, wire.LegServerTLS(l.a.cert))
	_ = tc.SetDeadline(time.Now().Add(legHandshakeTimeout))
	err := tc.Handshake()
	<-l.busy
	if err != nil {
		l.refuse(raw, ip, wire.LegRefusedHandshake, "")
		return
	}
	pub, err := wire.PeerKey(tc.ConnectionState())
	if err != nil {
		l.refuse(tc, ip, wire.LegRefusedHandshake, "")
		return
	}
	msg, err := codec.ReadRawProto(tc, legHandshakeTimeout)
	if err != nil {
		if errors.Is(err, io.EOF) {
			// A probe: the handshake was all it wanted
			l.probes.Add(1)
			tc.Close()
			return
		}
		l.refuse(tc, ip, wire.LegRefusedBadFrame, "")
		return
	}
	uuid := msg.GetRequestRelay().GetUuid()
	if uuid == "" {
		l.refuse(tc, ip, wire.LegRefusedBadFrame, "")
		return
	}
	if reason := l.a.gate.takeLeg(uuid, wire.PublicKeyBase64(pub)); reason != "" {
		l.refuse(tc, ip, reason, uuid)
		return
	}
	_ = tc.SetDeadline(time.Time{})
	l.accepted.Add(1)
	l.a.cfg.Logf("[node] Leg of UUID %s from %s accepted", shortUUID(uuid), ip)
	l.a.srv.ServeClaimed(&legConn{Conn: tc, name: "leg-from/" + shortUUID(uuid)}, uuid)
}

func remoteIP(c net.Conn) string {
	host, _, err := net.SplitHostPort(c.RemoteAddr().String())
	if err != nil {
		return c.RemoteAddr().String()
	}
	return host
}

// ---- probes ----

// probe checks each target with a TLS handshake to its leg listener and
// answers central with the results.
func (a *Agent) probe(c *wire.Conn, m wire.Probe) {
	targets := m.Targets
	if len(targets) > maxProbeTargets {
		targets = targets[:maxProbeTargets]
	}
	results := make([]wire.ProbeResult, len(targets))
	sem := make(chan struct{}, probeParallel)
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			results[i] = a.probeOne(t)
		}()
	}
	wg.Wait()
	if err := c.Write(wire.Probed{Results: results}, writeTimeout); err != nil {
		a.cfg.Logf("[node] Probe results not sent: %v", err)
	}
}

func (a *Agent) probeOne(t wire.ProbeTarget) wire.ProbeResult {
	r := wire.ProbeResult{NodeID: t.NodeID, Addr: t.Addr}
	key, err := wire.DecodePublicKey(t.Key)
	if err != nil || t.Addr == "" {
		return r
	}
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	tc, rtt, err := a.handshakeLeg(ctx, t.Addr, key)
	if err != nil {
		a.cfg.Logf("[node] Probe of node %s at %s: %v", t.NodeID, t.Addr, err)
		return r
	}
	tc.Close()
	r.OK = true
	r.RTTMs = max(rtt.Milliseconds(), 0)
	return r
}
