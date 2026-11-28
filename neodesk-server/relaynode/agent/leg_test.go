package agent

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/codec"
	"github.com/neodeskapp/neodesk/neodesk-server/config"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// freePort is a TCP port where port and port+2 are free (the relay and
// its WebSocket listener).
func freePort(t *testing.T) int {
	t.Helper()
	for range 100 {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		p := ln.Addr().(*net.TCPAddr).Port
		ln2, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p+2))
		ln.Close()
		if err == nil {
			ln2.Close()
			return p
		}
	}
	t.Fatal("no free port")
	return 0
}

// legNode is an enrolled agent with its relay and leg listener running.
type legNode struct {
	a         *Agent
	relayAddr string
	legAddr   string
}

func (e *env) legNode(token string, mod func(*Config)) *legNode {
	e.t.Helper()
	relayPort, legPort := freePort(e.t), freePort(e.t)
	rcfg := config.DefaultConfig()
	rcfg.RelayPort = relayPort
	cfg := Config{
		Join: e.join(token), DataDir: e.t.TempDir(), Relay: rcfg, Version: "test", Logf: e.logs.Logf,
		LanAddr: fmt.Sprintf("127.0.0.1:%d", relayPort), LegPort: legPort,
		BackoffMin: 20 * time.Millisecond, BackoffMax: 100 * time.Millisecond,
	}
	if mod != nil {
		mod(&cfg)
	}
	a, err := New(cfg)
	if err != nil {
		e.t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(e.rootCtx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := a.Run(ctx); err != nil {
			e.logs.Logf("run: %v", err)
		}
	}()
	e.t.Cleanup(func() {
		cancel()
		<-done
	})
	waitFor(e.t, "node online with its leg listener", func() bool {
		return a.NodeID() != "" && e.hub.Online(a.NodeID()) && a.LegAddr() != nil
	})
	return &legNode{a: a, relayAddr: cfg.LanAddr, legAddr: a.LegAddr().String()}
}

func newKeyCert(t *testing.T) (tls.Certificate, string) {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := wire.SelfSignedCert(key, "test node")
	if err != nil {
		t.Fatal(err)
	}
	return cert, wire.PublicKeyBase64(key.Public().(ed25519.PublicKey))
}

func pushTicket(t *testing.T, a *Agent, uuid string, leg *wire.Leg) {
	t.Helper()
	ack := a.authorize(wire.Authorize{ID: 1, UUID: uuid, Initiator: "111", Target: "222", ExpiresUnixMs: time.Now().Add(30 * time.Second).UnixMilli(), Leg: leg})
	if !ack.OK {
		t.Fatalf("ticket %s refused: %s", uuid, ack.Err)
	}
}

func requestRelay(t *testing.T, c net.Conn, uuid string) {
	t.Helper()
	if err := codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{Uuid: uuid}}}); err != nil {
		t.Fatal(err)
	}
}

// dialLegAs opens a leg to node n as the holder of cert and asks for uuid.
func dialLegAs(t *testing.T, n *legNode, cert tls.Certificate, uuid string) *tls.Conn {
	t.Helper()
	key, err := wire.DecodePublicKey(n.a.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	c, err := tls.Dial("tcp", n.legAddr, wire.LegClientTLS(cert, key))
	if err != nil {
		t.Fatalf("leg handshake: %v", err)
	}
	t.Cleanup(func() { c.Close() })
	requestRelay(t, c, uuid)
	return c
}

func dialRelay(t *testing.T, addr, uuid string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	requestRelay(t, c, uuid)
	return c
}

// closedSoon says the node hung up on c within d without sending data.
func closedSoon(c net.Conn, d time.Duration) bool {
	_ = c.SetReadDeadline(time.Now().Add(d))
	var b [1]byte
	_, err := c.Read(b[:])
	return err == io.EOF || (err != nil && !isTimeout(err))
}

func isTimeout(err error) bool {
	ne, ok := err.(net.Error)
	return ok && ne.Timeout()
}

func through(t *testing.T, from, to net.Conn, msg string) {
	t.Helper()
	_ = from.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if _, err := from.Write([]byte(msg)); err != nil {
		t.Fatalf("write: %v", err)
	}
	got := make([]byte, len(msg))
	_ = to.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(to, got); err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(got, []byte(msg)) {
		t.Fatalf("got %q, want %q", got, msg)
	}
}

func refusedCount(n *legNode, reason string) int64 {
	_, r := n.a.legs.counts()
	return r[reason]
}

// TestALegNeedsATicketAndTheKeyCentralNamed: node B takes a leg only for
// a uuid it holds an accept ticket of, and only from the key the ticket
// names; such a leg pairs with B's own client and bytes flow.
func TestALegNeedsATicketAndTheKeyCentralNamed(t *testing.T) {
	e := newEnv(t)
	b := e.legNode("tok-b", nil)
	certA, keyA := newKeyCert(t)
	certX, _ := newKeyCert(t)

	t.Run("no ticket", func(t *testing.T) {
		c := dialLegAs(t, b, certA, "u-none")
		if !closedSoon(c, 2*time.Second) {
			t.Fatal("a leg for a uuid without a ticket stayed open")
		}
		waitFor(t, "refusal counted", func() bool { return refusedCount(b, wire.LegRefusedNoTicket) == 1 })
	})

	t.Run("a ticket without a leg", func(t *testing.T) {
		pushTicket(t, b.a, "u-plain", nil)
		c := dialLegAs(t, b, certA, "u-plain")
		if !closedSoon(c, 2*time.Second) {
			t.Fatal("a leg for a one-node ticket stayed open")
		}
		waitFor(t, "refusal counted", func() bool { return refusedCount(b, wire.LegRefusedNoTicket) == 2 })
	})

	t.Run("wrong key", func(t *testing.T) {
		pushTicket(t, b.a, "u-wrong", &wire.Leg{Role: wire.LegAccept, PeerKey: keyA})
		c := dialLegAs(t, b, certX, "u-wrong")
		if !closedSoon(c, 2*time.Second) {
			t.Fatal("a leg from a key central did not name stayed open")
		}
		waitFor(t, "refusal counted", func() bool { return refusedCount(b, wire.LegRefusedWrongKey) == 1 })
		// The refused leg spent nothing: the right node still gets in
		leg := dialLegAs(t, b, certA, "u-wrong")
		client := dialRelay(t, b.relayAddr, "u-wrong")
		through(t, leg, client, "after a wrong key")
	})

	t.Run("right key and ticket", func(t *testing.T) {
		pushTicket(t, b.a, "u-ok", &wire.Leg{Role: wire.LegAccept, PeerKey: keyA})
		client := dialRelay(t, b.relayAddr, "u-ok")
		leg := dialLegAs(t, b, certA, "u-ok")
		through(t, leg, client, "from client A over the leg")
		through(t, client, leg, "from client B back")
		accepted, _ := b.a.legs.counts()
		if accepted != 2 {
			t.Fatalf("accepted %d legs, want 2", accepted)
		}
		// A second leg for the same uuid is refused
		again := dialLegAs(t, b, certA, "u-ok")
		if !closedSoon(again, 2*time.Second) {
			t.Fatal("a second leg for a used ticket stayed open")
		}
	})

	t.Run("the relay port takes one side only", func(t *testing.T) {
		pushTicket(t, b.a, "u-port", &wire.Leg{Role: wire.LegAccept, PeerKey: keyA})
		first := dialRelay(t, b.relayAddr, "u-port")
		waitFor(t, "first side claimed", func() bool { return b.a.gate.plainClaims("u-port") == 1 })
		second := dialRelay(t, b.relayAddr, "u-port")
		if !closedSoon(second, 4*time.Second) {
			t.Fatal("a second connection on the relay port took the leg's side")
		}
		leg := dialLegAs(t, b, certA, "u-port")
		through(t, leg, first, "the leg still pairs")
	})
}

// TestTooManyRefusedLegsCloseTheDoor: past the refusal limit an address
// is refused at once, even with the right key and ticket.
func TestTooManyRefusedLegsCloseTheDoor(t *testing.T) {
	e := newEnv(t)
	b := e.legNode("tok-b", func(c *Config) { c.LegRefusalsLimit = 2 })
	certA, keyA := newKeyCert(t)
	for i := range 2 {
		c := dialLegAs(t, b, certA, fmt.Sprintf("u-guess-%d", i))
		closedSoon(c, 2*time.Second)
	}
	waitFor(t, "two refusals", func() bool { return refusedCount(b, wire.LegRefusedNoTicket) == 2 })
	pushTicket(t, b.a, "u-late", &wire.Leg{Role: wire.LegAccept, PeerKey: keyA})
	raw, err := net.DialTimeout("tcp", b.legAddr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	if !closedSoon(raw, 2*time.Second) {
		t.Fatal("the listener kept talking to an address past its refusal limit")
	}
	if refusedCount(b, wire.LegRefusedRate) != 1 {
		t.Fatalf("rate refusals %d, want 1", refusedCount(b, wire.LegRefusedRate))
	}
}

// TestTwoNodesJoinASessionOverTheirLeg: node A holds a dial ticket, node
// B the accept ticket; client A at node A and client B at node B talk
// through both relays and the TLS leg between them.
func TestTwoNodesJoinASessionOverTheirLeg(t *testing.T) {
	e := newEnv(t)
	a := e.legNode("tok-a", nil)
	b := e.legNode("tok-b", nil)
	pushTicket(t, b.a, "u-2", &wire.Leg{Role: wire.LegAccept, PeerKey: a.a.PublicKey()})
	pushTicket(t, a.a, "u-2", &wire.Leg{Role: wire.LegDial, PeerAddr: b.legAddr, PeerKey: b.a.PublicKey()})
	clientB := dialRelay(t, b.relayAddr, "u-2")
	clientA := dialRelay(t, a.relayAddr, "u-2")
	through(t, clientA, clientB, "A to B")
	through(t, clientB, clientA, "B to A")
	accepted, _ := b.a.legs.counts()
	if accepted != 1 {
		t.Fatalf("node B accepted %d legs, want 1", accepted)
	}
}

// TestADialToTheWrongKeyDropsTheClientAtOnce: node B does not show the
// key the dial ticket names, so node A gives up on the leg and its client
// hears it at once instead of after the 30 s pair timeout.
func TestADialToTheWrongKeyDropsTheClientAtOnce(t *testing.T) {
	e := newEnv(t)
	a := e.legNode("tok-a", nil)
	b := e.legNode("tok-b", nil)
	_, other := newKeyCert(t)
	pushTicket(t, b.a, "u-3", &wire.Leg{Role: wire.LegAccept, PeerKey: a.a.PublicKey()})
	pushTicket(t, a.a, "u-3", &wire.Leg{Role: wire.LegDial, PeerAddr: b.legAddr, PeerKey: other})
	clientA := dialRelay(t, a.relayAddr, "u-3")
	if !closedSoon(clientA, 5*time.Second) {
		t.Fatal("client A still waits after the leg failed")
	}
	if accepted, _ := b.a.legs.counts(); accepted != 0 {
		t.Fatalf("node B accepted %d legs", accepted)
	}
}

// TestAProbeIsATLSHandshakeWithTheRightKey: a probe succeeds against the
// target's leg listener and its key only, and the target counts it as a
// probe, not a refused leg.
func TestAProbeIsATLSHandshakeWithTheRightKey(t *testing.T) {
	e := newEnv(t)
	a := e.legNode("tok-a", nil)
	b := e.legNode("tok-b", nil)
	_, other := newKeyCert(t)
	if r := a.a.probeOne(wire.ProbeTarget{NodeID: "b", Addr: b.legAddr, Key: b.a.PublicKey()}); !r.OK || r.NodeID != "b" || r.Addr != b.legAddr {
		t.Fatalf("probe of B: %+v", r)
	}
	if r := a.a.probeOne(wire.ProbeTarget{NodeID: "b", Addr: b.legAddr, Key: other}); r.OK {
		t.Fatalf("probe with another key: %+v, want not ok", r)
	}
	closed := fmt.Sprintf("127.0.0.1:%d", freePort(t))
	if r := a.a.probeOne(wire.ProbeTarget{NodeID: "c", Addr: closed, Key: b.a.PublicKey()}); r.OK {
		t.Fatalf("probe of a closed port: %+v", r)
	}
	waitFor(t, "probe counted", func() bool { return b.a.legs.probes.Load() >= 1 })
	if _, r := b.a.legs.counts(); r[wire.LegRefusedBadFrame] != 0 {
		t.Fatalf("the probe counted as a refused leg: %v", r)
	}
}

// plainClaims is the claims uuid got from the relay port.
func (g *gate) plainClaims(uuid string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	if lt := g.legs[uuid]; lt != nil {
		return lt.plain
	}
	return -1
}
