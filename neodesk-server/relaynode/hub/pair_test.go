package hub_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/internal/fakestore"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// scriptedNode reads a raw node's frames, acks authorize as ack says
// (nil: never) and keeps what it got.
type scriptedNode struct {
	mu     sync.Mutex
	frames []wire.Frame
}

func (n *scriptedNode) run(c *wire.Conn, ack func(wire.Authorize) *wire.Ack) {
	for {
		f, err := c.Read(5 * time.Second)
		if err != nil {
			return
		}
		n.mu.Lock()
		n.frames = append(n.frames, f)
		n.mu.Unlock()
		var a wire.Authorize
		if f.Type == wire.TypeAuthorize && f.Decode(&a) == nil {
			if r := ack(a); r != nil {
				c.Write(*r, time.Second)
			}
		}
	}
}

func (n *scriptedNode) of(typ string) []wire.Frame {
	n.mu.Lock()
	defer n.mu.Unlock()
	var out []wire.Frame
	for _, f := range n.frames {
		if f.Type == typ {
			out = append(out, f)
		}
	}
	return out
}

func okAck(a wire.Authorize) *wire.Ack { return &wire.Ack{ID: a.ID, OK: true} }

const (
	dialerKey   = "ZGlhbGVyLWtleS1kaWFsZXIta2V5LWRpYWxlci1rZXk="
	acceptorKey = "YWNjZXB0b3Ita2V5LWFjY2VwdG9yLWtleS1hY2NlcHQ="
)

func pairOf(dialer, acceptor string) hub.PairSpec {
	return hub.PairSpec{Dialer: dialer, Acceptor: acceptor, DialerKey: dialerKey, AcceptorKey: acceptorKey, Dial: "192.0.2.7:21125"}
}

func pairTicket(uuid string) relay.Ticket {
	return relay.Ticket{UUID: uuid, Initiator: "111", Target: "222", Expires: time.Now().Add(30 * time.Second)}
}

// TestAPairTicketGoesToBothNodesWithTheirLegs: the accepting node gets a
// ticket that takes a leg from the dialing node's key, the dialing node
// one that dials the accepting node's leg address and expects its key.
// The accepting node's reports drive billing; the dialing node's don't.
func TestAPairTicketGoesToBothNodesWithTheirLegs(t *testing.T) {
	st := fakestore.New()
	rec := fakestore.NewRecorder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Events = rec })
	ca, a := enrolled(t, h, st, pin, "tok-a")
	cb, b := enrolled(t, h, st, pin, "tok-b")
	na, nb := &scriptedNode{}, &scriptedNode{}
	go na.run(ca, okAck)
	go nb.run(cb, okAck)

	store := h.Pair(pairOf(a, b))
	if err := store.Authorize(context.Background(), pairTicket("u-pair")); err != nil {
		t.Fatalf("Authorize: %v", err)
	}
	var da, db wire.Authorize
	if fs := na.of(wire.TypeAuthorize); len(fs) != 1 || fs[0].Decode(&da) != nil {
		t.Fatalf("dialer got %d authorize frames", len(fs))
	}
	if fs := nb.of(wire.TypeAuthorize); len(fs) != 1 || fs[0].Decode(&db) != nil {
		t.Fatalf("acceptor got %d authorize frames", len(fs))
	}
	if da.Leg == nil || *da.Leg != (wire.Leg{Role: wire.LegDial, PeerAddr: "192.0.2.7:21125", PeerKey: acceptorKey}) {
		t.Fatalf("dialer's leg %+v", da.Leg)
	}
	if db.Leg == nil || *db.Leg != (wire.Leg{Role: wire.LegAccept, PeerKey: dialerKey}) {
		t.Fatalf("acceptor's leg %+v", db.Leg)
	}
	if da.UUID != "u-pair" || db.UUID != "u-pair" || db.Initiator != "111" || db.Target != "222" {
		t.Fatalf("tickets %+v and %+v", da, db)
	}
	if !store.Admitted("u-pair", "111", "222") {
		t.Fatal("the pair is not admitted after both acks")
	}

	// The dialing node reports first; billing waits for the accepting node
	if err := ca.Write(wire.Started{UUID: "u-pair"}, time.Second); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return h.ActiveSessions(a) == 1 })
	if err := cb.Write(wire.Started{UUID: "u-pair"}, time.Second); err != nil {
		t.Fatal(err)
	}
	e, err := rec.Wait("started", 2*time.Second)
	if err != nil || e.Node != b {
		t.Fatalf("started event %+v, %v; want one from the accepting node %s", e, err, b)
	}
	if _, ok := store.Live("u-pair"); !ok {
		t.Fatal("the pair is not live after the accepting node started it")
	}
	ca.Write(wire.Ended{UUID: "u-pair", Up: 1, Down: 2}, time.Second)
	cb.Write(wire.Ended{UUID: "u-pair", Up: 10, Down: 20}, time.Second)
	e, err = rec.Wait("ended", 2*time.Second)
	if err != nil || e.Node != b || e.Up != 10 {
		t.Fatalf("ended event %+v, %v; want the accepting node's", e, err)
	}
	select {
	case e := <-rec.C:
		if e.Kind == "started" || e.Kind == "ended" {
			t.Fatalf("a second %s event, from node %s: billing would count the dialing node too", e.Kind, e.Node)
		}
	case <-time.After(200 * time.Millisecond):
	}
}

// TestAPairWithANodeDownIsUnavailableAndCancelled: the accepting node is
// offline, so the pair is unavailable at once and the dialing node, which
// acked, gets a cancel and keeps nothing.
func TestAPairWithANodeDownIsUnavailableAndCancelled(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, nil)
	ca, a := enrolled(t, h, st, pin, "tok-a")
	na := &scriptedNode{}
	go na.run(ca, okAck)

	store := h.Pair(pairOf(a, "offline-node"))
	start := time.Now()
	err := store.Authorize(context.Background(), pairTicket("u-down"))
	if !errors.Is(err, hub.ErrUnavailable) {
		t.Fatalf("got %v, want ErrUnavailable", err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("took %s", d)
	}
	waitFor(t, func() bool { return len(na.of(wire.TypeCancel)) == 1 })
	var c wire.Cancel
	na.of(wire.TypeCancel)[0].Decode(&c)
	if c.UUID != "u-down" {
		t.Fatalf("cancel %+v", c)
	}
	if h.Tickets(a).Admitted("u-down", "111", "222") || store.Admitted("u-down", "111", "222") {
		t.Fatal("a ticket of the failed pair is still admitted")
	}
}

// TestAPairWhoseNodeDoesNotAckFallsBackWithinTheBudget: the dialing node
// never acks; the pair is unavailable after the budget, and the accepting
// node, which acked, is cancelled.
func TestAPairWhoseNodeDoesNotAckFallsBackWithinTheBudget(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, func(c *hub.Config) { c.AuthorizeBudget = 300 * time.Millisecond })
	ca, a := enrolled(t, h, st, pin, "tok-a")
	cb, b := enrolled(t, h, st, pin, "tok-b")
	na, nb := &scriptedNode{}, &scriptedNode{}
	go na.run(ca, func(wire.Authorize) *wire.Ack { return nil })
	go nb.run(cb, okAck)

	start := time.Now()
	err := h.Pair(pairOf(a, b)).Authorize(context.Background(), pairTicket("u-slow"))
	d := time.Since(start)
	if !errors.Is(err, hub.ErrUnavailable) {
		t.Fatalf("got %v, want ErrUnavailable", err)
	}
	if d < 250*time.Millisecond || d > 1200*time.Millisecond {
		t.Fatalf("returned after %s, want the 300 ms budget", d)
	}
	waitFor(t, func() bool { return len(nb.of(wire.TypeCancel)) == 1 })
	if h.Tickets(b).Admitted("u-slow", "111", "222") {
		t.Fatal("the accepting node's ticket outlived the failed pair")
	}
}

// TestLegCountsReachTheAudit: the legs a node accepted and refused, from
// its stats, are audited per reason once per interval, as differences.
func TestLegCountsReachTheAudit(t *testing.T) {
	st := fakestore.New()
	rec := fakestore.NewRecorder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Audit = rec; c.AuditInterval = 100 * time.Millisecond })
	c, id := enrolled(t, h, st, pin, "tok-legs")
	c.Write(wire.Stats{LegsAccepted: 3, LegsRefused: map[string]int64{wire.LegRefusedWrongKey: 2}}, time.Second)
	e, err := rec.Wait("relay_node.legs", 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if e.Fields["node_id"] != id || e.Fields["accepted"] != "3" || e.Fields["refused_wrong_key"] != "2" {
		t.Fatalf("audit fields %v", e.Fields)
	}
	c.Write(wire.Stats{LegsAccepted: 4, LegsRefused: map[string]int64{wire.LegRefusedWrongKey: 2, wire.LegRefusedNoTicket: 1}}, time.Second)
	e, err = rec.Wait("relay_node.legs", 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if e.Fields["accepted"] != "1" || e.Fields["refused_no_ticket"] != "1" || e.Fields["refused_wrong_key"] != "" {
		t.Fatalf("second audit %v, want only what is new", e.Fields)
	}
}
