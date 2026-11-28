package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/internal/fakestore"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

func startHub(t *testing.T, st *fakestore.Store, mod func(*hub.Config)) (*hub.Hub, string) {
	t.Helper()
	return startHubWith(t, st, mod)
}

// startHubWith is startHub on any store.
func startHubWith(t *testing.T, st hub.Store, mod func(*hub.Config)) (*hub.Hub, string) {
	t.Helper()
	cert, pin, err := hub.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cfg := hub.Config{Addr: "127.0.0.1:0", Cert: cert, ServerPK: "server-pk", Store: st, Logf: t.Logf}
	if mod != nil {
		mod(&cfg)
	}
	h, err := hub.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Stop)
	return h, pin
}

// rawNode is a node speaking the protocol by hand.
func rawNode(t *testing.T, h *hub.Hub, pin string) *wire.Conn {
	t.Helper()
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	cert, err := wire.SelfSignedCert(key, "test node")
	if err != nil {
		t.Fatal(err)
	}
	c, err := tls.Dial("tcp", h.Addr().String(), wire.ClientTLS(cert, pin))
	if err != nil {
		t.Fatal(err)
	}
	wc := wire.NewConn(c)
	t.Cleanup(func() { wc.Close() })
	return wc
}

// hello sends a hello and returns central's answer.
func hello(t *testing.T, c *wire.Conn, m wire.Hello) wire.Frame {
	t.Helper()
	if err := c.Write(m, time.Second); err != nil {
		t.Fatal(err)
	}
	f, err := c.Read(3 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func enrolled(t *testing.T, h *hub.Hub, st *fakestore.Store, pin, token string) (*wire.Conn, string) {
	t.Helper()
	st.AddToken(token, "site-1")
	c := rawNode(t, h, pin)
	f := hello(t, c, wire.Hello{Token: token, Version: "test"})
	var w wire.Welcome
	if f.Type != wire.TypeWelcome || f.Decode(&w) != nil || w.NodeID == "" {
		t.Fatalf("got %s %s, want welcome", f.Type, f.Body)
	}
	waitFor(t, func() bool { return h.Online(w.NodeID) })
	return c, w.NodeID
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met within 3 s")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func authorize(h *hub.Hub, ctx context.Context, node, uuid string) error {
	return h.Tickets(node).AuthorizePair(ctx, uuid, "111", "222", 5, "console-handle", time.Now().Add(30*time.Second))
}

func TestAuthorizeToAnOfflineNodeIsUnavailableAtOnce(t *testing.T) {
	h, _ := startHub(t, fakestore.New(), nil)
	start := time.Now()
	err := authorize(h, context.Background(), "no-such-node", "u1")
	if !errors.Is(err, hub.ErrUnavailable) {
		t.Fatalf("got %v, want ErrUnavailable", err)
	}
	if d := time.Since(start); d > 200*time.Millisecond {
		t.Fatalf("took %s", d)
	}
}

func TestAuthorizeWithoutAckIsUnavailableWithinBudget(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, func(c *hub.Config) { c.AuthorizeBudget = 300 * time.Millisecond })
	c, id := enrolled(t, h, st, pin, "tok-1")
	got := make(chan wire.Authorize, 1)
	go func() {
		for {
			f, err := c.Read(5 * time.Second)
			if err != nil {
				return
			}
			var a wire.Authorize
			if f.Type == wire.TypeAuthorize && f.Decode(&a) == nil {
				got <- a // and never ack
			}
		}
	}()

	start := time.Now()
	err := authorize(h, context.Background(), id, "u1")
	d := time.Since(start)
	if !errors.Is(err, hub.ErrUnavailable) {
		t.Fatalf("got %v, want ErrUnavailable", err)
	}
	if d < 250*time.Millisecond || d > time.Second {
		t.Fatalf("returned after %s, want the 300 ms budget", d)
	}
	a := <-got
	if a.UUID != "u1" || a.Initiator != "111" || a.Target != "222" || a.ExpiresUnixMs == 0 {
		t.Fatalf("node got %+v", a)
	}

	// A deadline of the caller's wins over the budget
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	start = time.Now()
	if err := authorize(h, ctx, id, "u2"); !errors.Is(err, hub.ErrUnavailable) || time.Since(start) > 250*time.Millisecond {
		t.Fatalf("with an 80 ms deadline: %v after %s", err, time.Since(start))
	}
}

func TestAuthorizeWhenTheConnectionDropsIsUnavailable(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, func(c *hub.Config) { c.AuthorizeBudget = 5 * time.Second })
	c, id := enrolled(t, h, st, pin, "tok-1")
	go func() {
		c.Read(5 * time.Second)
		c.Close()
	}()
	start := time.Now()
	if err := authorize(h, context.Background(), id, "u1"); !errors.Is(err, hub.ErrUnavailable) {
		t.Fatalf("got %v, want ErrUnavailable", err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("waited %s for a closed connection", d)
	}
}

func TestAckAcceptsAndRefuses(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, nil)
	c, id := enrolled(t, h, st, pin, "tok-1")
	go func() {
		for {
			f, err := c.Read(5 * time.Second)
			if err != nil {
				return
			}
			var a wire.Authorize
			if f.Type == wire.TypeAuthorize && f.Decode(&a) == nil {
				c.Write(wire.Ack{ID: a.ID, OK: a.UUID == "good", Err: "conflict"}, time.Second)
			}
		}
	}()
	if err := authorize(h, context.Background(), id, "good"); err != nil {
		t.Fatalf("good: %v", err)
	}
	if !h.Tickets(id).Admitted("good", "111", "222") || h.Tickets(id).Admitted("good", "111", "333") {
		t.Fatal("Admitted does not match the acked pair")
	}
	if err := authorize(h, context.Background(), id, "bad"); !errors.Is(err, hub.ErrRejected) {
		t.Fatalf("bad: got %v, want ErrRejected", err)
	}
}

func TestEnrollmentIsRateLimitedPerIP(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, func(c *hub.Config) { c.EnrollPerMinute = 2 })
	var codes []string
	for i := 0; i < 3; i++ {
		f := hello(t, rawNode(t, h, pin), wire.Hello{Token: "wrong"})
		var e wire.Error
		f.Decode(&e)
		codes = append(codes, e.Code)
	}
	want := []string{wire.CodeBadToken, wire.CodeBadToken, wire.CodeRateLimited}
	for i := range want {
		if codes[i] != want[i] {
			t.Fatalf("codes %v, want %v", codes, want)
		}
	}
}

func TestASilentNodeIsDropped(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, func(c *hub.Config) { c.IdleTimeout = 300 * time.Millisecond; c.PingInterval = 100 * time.Millisecond })
	c, id := enrolled(t, h, st, pin, "tok-1")
	// The node reads the pings but never answers, until central hangs up
	pings := 0
	start := time.Now()
	for {
		f, err := c.Read(3 * time.Second)
		if err != nil {
			break
		}
		if f.Type == wire.TypePing {
			pings++
		}
		if time.Since(start) > 3*time.Second {
			t.Fatal("central keeps a silent node for 3 s")
		}
	}
	if pings == 0 {
		t.Fatal("no ping from central")
	}
	waitFor(t, func() bool { return !h.Online(id) })
}

func TestRevokeAndEndReachTheNode(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, nil)
	c, id := enrolled(t, h, st, pin, "tok-1")
	h.RevokeForPeer("111")
	h.Tickets(id).End("u9")
	seen := map[string]string{}
	for len(seen) < 2 {
		f, err := c.Read(2 * time.Second)
		if err != nil {
			t.Fatalf("after %v: %v", seen, err)
		}
		switch f.Type {
		case wire.TypeRevoke:
			var m wire.Revoke
			f.Decode(&m)
			seen["revoke"] = m.Peer
		case wire.TypeEnd:
			var m wire.End
			f.Decode(&m)
			seen["end"] = m.UUID
		}
	}
	if seen["revoke"] != "111" || seen["end"] != "u9" {
		t.Fatalf("node got %v", seen)
	}
}

func TestStatsGiveTheNodesTrafficWhileItIsOnline(t *testing.T) {
	st := fakestore.New()
	h, pin := startHub(t, st, nil)
	c, id := enrolled(t, h, st, pin, "tok-traffic")
	if up, down := h.Traffic(id); up != 0 || down != 0 {
		t.Fatalf("before stats: %d up, %d down", up, down)
	}
	if err := c.Write(wire.Stats{Active: 2, UpTotal: 1234, DownTotal: 5678}, time.Second); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { up, down := h.Traffic(id); return up == 1234 && down == 5678 })
	if n := h.ActiveSessions(id); n != 2 {
		t.Fatalf("active sessions %d, want 2", n)
	}
	c.Close()
	waitFor(t, func() bool { return !h.Online(id) })
	if up, down := h.Traffic(id); up != 0 || down != 0 {
		t.Fatalf("offline: %d up, %d down", up, down)
	}
}

func TestCentralCertIsMadeOnce(t *testing.T) {
	dir := t.TempDir()
	_, pin1, err := hub.LoadOrCreateCert(dir)
	if err != nil {
		t.Fatal(err)
	}
	_, pin2, err := hub.LoadOrCreateCert(dir)
	if err != nil || pin1 != pin2 {
		t.Fatalf("second load: pin %s vs %s, %v", pin2, pin1, err)
	}
}

func TestControlPort(t *testing.T) {
	env := map[string]string{}
	get := func(k string) string { return env[k] }
	if p, err := hub.ControlPort(get); err != nil || p != hub.DefaultControlPort {
		t.Fatalf("default: %d %v", p, err)
	}
	env["NODE_CONTROL_PORT"] = "30000"
	if p, err := hub.ControlPort(get); err != nil || p != 30000 {
		t.Fatalf("set: %d %v", p, err)
	}
	env["NODE_CONTROL_PORT"] = "x"
	if _, err := hub.ControlPort(get); err == nil {
		t.Fatal("x accepted")
	}
}

// ackAll answers every authorize on c with ok, until c closes.
func ackAll(c *wire.Conn) {
	go func() {
		for {
			f, err := c.Read(10 * time.Second)
			if err != nil {
				return
			}
			var a wire.Authorize
			if f.Type == wire.TypeAuthorize && f.Decode(&a) == nil {
				c.Write(wire.Ack{ID: a.ID, OK: true}, time.Second)
			}
		}
	}()
}

// TestANodeReportsOnlyItsOwnSessions: started and ended for a uuid the
// node holds no ticket for (another node's session) reach neither billing
// nor the session record, and do not end the other node's session.
func TestANodeReportsOnlyItsOwnSessions(t *testing.T) {
	st := fakestore.New()
	rec := fakestore.NewRecorder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Events, c.Audit = rec, rec })
	a, aID := enrolled(t, h, st, pin, "tok-a")
	b, _ := enrolled(t, h, st, pin, "tok-b")
	ackAll(a)
	if err := authorize(h, context.Background(), aID, "sess-a"); err != nil {
		t.Fatal(err)
	}

	if err := b.Write(wire.Started{UUID: "sess-a"}, time.Second); err != nil {
		t.Fatal(err)
	}
	if err := b.Write(wire.Ended{UUID: "sess-a", Up: 1, Down: 2}, time.Second); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		e, err := rec.Wait("relay_node.unknown_session", 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if e.Fields["uuid"] != "sess-a" {
			t.Fatalf("audit %v", e.Fields)
		}
	}
	for len(rec.C) > 0 {
		if e := <-rec.C; e.Kind == "started" || e.Kind == "ended" {
			t.Fatalf("another node's report reached the events: %+v", e)
		}
	}
	if !h.Tickets(aID).Admitted("sess-a", "111", "222") {
		t.Fatal("another node's ended dropped the ticket")
	}

	if err := a.Write(wire.Started{UUID: "sess-a"}, time.Second); err != nil {
		t.Fatal(err)
	}
	e, err := rec.Wait("started", 2*time.Second)
	if err != nil || e.Node != aID || e.UUID != "sess-a" {
		t.Fatalf("own started: %+v, %v", e, err)
	}
	if err := a.Write(wire.Started{UUID: "sess-a"}, time.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := rec.Wait("relay_node.unknown_session", 2*time.Second); err != nil {
		t.Fatalf("a second started for a running session: %v", err)
	}
	if err := a.Write(wire.Ended{UUID: "sess-a"}, time.Second); err != nil {
		t.Fatal(err)
	}
	if e, err := rec.Wait("ended", 2*time.Second); err != nil || e.Node != aID {
		t.Fatalf("own ended: %+v, %v", e, err)
	}

	// After a central restart the hub has no ticket; the session record
	// decides whether the node relayed the session
	st.Relayed("sess-before-restart")
	if err := a.Write(wire.Ended{UUID: "sess-before-restart"}, time.Second); err != nil {
		t.Fatal(err)
	}
	if e, err := rec.Wait("ended", 2*time.Second); err != nil || e.UUID != "sess-before-restart" {
		t.Fatalf("ended of a recorded session: %+v, %v", e, err)
	}
}
