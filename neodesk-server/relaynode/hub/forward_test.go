package hub_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/internal/fakestore"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// fakeForwarder records the streams the hub hands over and echoes TCP
// bytes back.
type fakeForwarder struct {
	mu      sync.Mutex
	streams []forwardedStream
	got     chan forwardedStream
	udp     chan *hub.UDPChannel
	stop    chan struct{} // ends ForwardUDP
}

type forwardedStream struct {
	node, service, remote string
	conn                  net.Conn
}

func newFakeForwarder() *fakeForwarder {
	return &fakeForwarder{got: make(chan forwardedStream, 16), udp: make(chan *hub.UDPChannel, 4), stop: make(chan struct{})}
}

func (f *fakeForwarder) ForwardTCP(node, service string, c net.Conn) {
	s := forwardedStream{node: node, service: service, remote: c.RemoteAddr().String(), conn: c}
	f.mu.Lock()
	f.streams = append(f.streams, s)
	f.mu.Unlock()
	f.got <- s
	defer c.Close()
	_, _ = io.Copy(c, c) // echo until the node closes
}

func (f *fakeForwarder) ForwardUDP(node string, ch *hub.UDPChannel) {
	f.udp <- ch
	<-f.stop // the test reads ch itself
}

func (f *fakeForwarder) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.streams)
}

// nodeCert makes a node key and its certificate.
func nodeCert(t *testing.T) tls.Certificate {
	t.Helper()
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	cert, err := wire.SelfSignedCert(key, "test node")
	if err != nil {
		t.Fatal(err)
	}
	return cert
}

func dialHub(t *testing.T, h *hub.Hub, pin string, cert tls.Certificate) *wire.Conn {
	t.Helper()
	c, err := tls.Dial("tcp", h.Addr().String(), wire.ClientTLS(cert, pin))
	if err != nil {
		t.Fatal(err)
	}
	wc := wire.NewConn(c)
	t.Cleanup(func() { wc.Close() })
	return wc
}

// enrollCert enrolls the node with cert and keeps its control connection.
func enrollCert(t *testing.T, h *hub.Hub, st *fakestore.Store, pin, token string, cert tls.Certificate) (*wire.Conn, string) {
	t.Helper()
	st.AddToken(token, "site-1")
	c := dialHub(t, h, pin, cert)
	f := hello(t, c, wire.Hello{Token: token, Version: "test"})
	var w wire.Welcome
	if f.Type != wire.TypeWelcome || f.Decode(&w) != nil {
		t.Fatalf("got %s %s, want welcome", f.Type, f.Body)
	}
	waitFor(t, func() bool { return h.Online(w.NodeID) })
	// answer pings so the control connection stays up
	go func() {
		for {
			f, err := c.Read(10 * time.Second)
			if err != nil {
				return
			}
			if f.Type == wire.TypePing {
				_ = c.Write(wire.Pong{}, time.Second)
			}
		}
	}()
	return c, w.NodeID
}

// openForward opens a forward_tcp stream and returns the connection and
// central's answer.
func openForward(t *testing.T, h *hub.Hub, pin string, cert tls.Certificate, service, client string) (*wire.Conn, wire.Frame) {
	t.Helper()
	c := dialHub(t, h, pin, cert)
	if err := c.Write(wire.ForwardTCP{Service: service, ClientAddr: client}, time.Second); err != nil {
		t.Fatal(err)
	}
	f, err := c.Read(3 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return c, f
}

func errCode(t *testing.T, f wire.Frame) string {
	t.Helper()
	if f.Type != wire.TypeError {
		t.Fatalf("got %s %s, want an error", f.Type, f.Body)
	}
	var e wire.Error
	_ = f.Decode(&e)
	return e.Code
}

// TestForwardFromAnOnlineNodeCarriesTheClientAddress: an enrolled node
// with its control connection up opens a forward stream; the hub answers
// forward_ok, hands the stream to the forwarder with the computer's
// address as its remote address, and bytes go through both ways.
func TestForwardFromAnOnlineNodeCarriesTheClientAddress(t *testing.T) {
	st := fakestore.New()
	fw := newFakeForwarder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Forwarder = fw })
	cert := nodeCert(t)
	_, id := enrollCert(t, h, st, pin, "tok-fwd", cert)

	c, f := openForward(t, h, pin, cert, wire.ServiceSignal, "10.3.0.5:51000")
	if f.Type != wire.TypeForwardOK {
		t.Fatalf("got %s %s, want forward_ok", f.Type, f.Body)
	}
	s := <-fw.got
	if s.node != id || s.service != wire.ServiceSignal || s.remote != "10.3.0.5:51000" {
		t.Fatalf("forwarder got node %q service %q remote %q", s.node, s.service, s.remote)
	}
	if fn, ok := s.conn.(interface{ ForwardNode() string }); !ok || fn.ForwardNode() != id {
		t.Fatalf("stream does not name its node %s", id)
	}
	msg := []byte("raw signal bytes \x00\x01")
	if _, err := c.Net().Write(msg); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(msg))
	_ = c.Net().SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(c.Net(), got); err != nil || !bytes.Equal(got, msg) {
		t.Fatalf("echo %q, %v", got, err)
	}
	if n := h.ForwardedStreams(id); n != 1 {
		t.Fatalf("hub counts %d open streams, want 1", n)
	}
}

// TestForwardFromAKeyThatIsNotOnlineIsRefused: a key that never enrolled
// (while another node is online), and an enrolled key whose control connection is down, get not_online;
// the forwarder never sees their client address.
func TestForwardFromAKeyThatIsNotOnlineIsRefused(t *testing.T) {
	st := fakestore.New()
	fw := newFakeForwarder()
	rec := fakestore.NewRecorder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Forwarder = fw; c.Audit = rec })
	// another node is online: its being online must not help a stranger
	enrollCert(t, h, st, pin, "tok-other", nodeCert(t))

	_, f := openForward(t, h, pin, nodeCert(t), wire.ServiceSignal, "10.3.0.5:51000")
	if code := errCode(t, f); code != wire.CodeNotOnline {
		t.Fatalf("stranger: code %q, want not_online", code)
	}
	e, err := rec.Wait("relay_node.forward_refused", 2*time.Second)
	if err != nil || e.Fields["reason"] != hub.ForwardRefusedNotOnline {
		t.Fatalf("audit %v, %v", e.Fields, err)
	}

	// Enrolled, then its control connection goes away
	cert := nodeCert(t)
	ctl, id := enrollCert(t, h, st, pin, "tok-off", cert)
	ctl.Close()
	waitFor(t, func() bool { return !h.Online(id) })
	_, f = openForward(t, h, pin, cert, wire.ServiceSignal, "10.3.0.5:51000")
	if code := errCode(t, f); code != wire.CodeNotOnline {
		t.Fatalf("offline node: code %q, want not_online", code)
	}
	if fw.count() != 0 {
		t.Fatalf("forwarder got %d streams, want none", fw.count())
	}
}

// TestRevokingANodeEndsItsForwardsAndRefusesNewOnes: Disconnect (revoke)
// closes the node's open forward stream, and the node's next forward is
// refused although it still holds the same key.
func TestRevokingANodeEndsItsForwardsAndRefusesNewOnes(t *testing.T) {
	st := fakestore.New()
	fw := newFakeForwarder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Forwarder = fw })
	cert := nodeCert(t)
	_, id := enrollCert(t, h, st, pin, "tok-rev", cert)
	c, f := openForward(t, h, pin, cert, wire.ServiceNAT, "10.3.0.5:51000")
	if f.Type != wire.TypeForwardOK {
		t.Fatalf("got %s", f.Type)
	}
	<-fw.got

	st.Revoke(id)
	h.Disconnect(id)
	_ = c.Net().SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Net().Read(make([]byte, 1)); err == nil {
		t.Fatal("the open forward stream survived the revocation")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("the open forward stream is still open after the revocation")
	}
	waitFor(t, func() bool { return !h.Online(id) })
	_, f = openForward(t, h, pin, cert, wire.ServiceSignal, "10.3.0.5:51001")
	if code := errCode(t, f); code != wire.CodeNotOnline {
		t.Fatalf("revoked node: code %q, want not_online", code)
	}
	if fw.count() != 1 {
		t.Fatalf("forwarder got %d streams, want only the one before the revocation", fw.count())
	}
}

// TestForwardWithABadServiceOrAddressIsRefused: loopback (the API trusts
// loopback callers), port 0 and unknown services never reach the
// forwarder.
func TestForwardWithABadServiceOrAddressIsRefused(t *testing.T) {
	st := fakestore.New()
	fw := newFakeForwarder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Forwarder = fw })
	cert := nodeCert(t)
	enrollCert(t, h, st, pin, "tok-bad", cert)
	for _, tc := range []struct{ service, addr string }{
		{wire.ServiceAPI, "127.0.0.1:5000"},
		{wire.ServiceSignal, "[::1]:5000"},
		{wire.ServiceSignal, "10.3.0.5:0"},
		{"relay", "10.3.0.5:5000"},
	} {
		_, f := openForward(t, h, pin, cert, tc.service, tc.addr)
		if code := errCode(t, f); code != wire.CodeBadForward {
			t.Errorf("%s %s: code %q, want bad_forward", tc.service, tc.addr, code)
		}
	}
	if fw.count() != 0 {
		t.Fatalf("forwarder got %d streams", fw.count())
	}
}

// TestForwardsAreLimitedPerClientIP: past the per-IP limit a client's
// streams are refused while another client of the same node still gets
// through, and the refusals are audited per node.
func TestForwardsAreLimitedPerClientIP(t *testing.T) {
	st := fakestore.New()
	fw := newFakeForwarder()
	rec := fakestore.NewRecorder()
	h, pin := startHub(t, st, func(c *hub.Config) {
		c.Forwarder = fw
		c.ForwardPerIPMinute = 2
		c.Audit = rec
		c.AuditInterval = 100 * time.Millisecond
	})
	cert := nodeCert(t)
	_, id := enrollCert(t, h, st, pin, "tok-rate", cert)
	for i := range 2 {
		if _, f := openForward(t, h, pin, cert, wire.ServiceSignal, "10.3.0.5:5000"); f.Type != wire.TypeForwardOK {
			t.Fatalf("stream %d: %s", i, f.Type)
		}
	}
	if _, f := openForward(t, h, pin, cert, wire.ServiceSignal, "10.3.0.5:5001"); errCode(t, f) != wire.CodeRateLimited {
		t.Fatal("third stream of the IP was not rate limited")
	}
	if _, f := openForward(t, h, pin, cert, wire.ServiceSignal, "10.3.0.6:5000"); f.Type != wire.TypeForwardOK {
		t.Fatalf("another IP of the node: %s", f.Type)
	}
	e, err := rec.Wait("relay_node.forwards", 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if e.Fields["node_id"] != id || e.Fields["tcp_signal"] != "3" || e.Fields["refused_rate_limited"] != "1" {
		t.Fatalf("audit %v", e.Fields)
	}
}

// TestUDPForwardCarriesEachDatagramsAddress: datagrams on the node's UDP
// connection arrive with the computer's address; one with a loopback
// address is dropped; an answer goes back to the node with its address.
func TestUDPForwardCarriesEachDatagramsAddress(t *testing.T) {
	st := fakestore.New()
	fw := newFakeForwarder()
	h, pin := startHub(t, st, func(c *hub.Config) { c.Forwarder = fw })
	t.Cleanup(func() { close(fw.stop) }) // before the hub stops
	cert := nodeCert(t)
	_, id := enrollCert(t, h, st, pin, "tok-udp", cert)
	c := dialHub(t, h, pin, cert)
	if err := c.Write(wire.ForwardUDP{}, time.Second); err != nil {
		t.Fatal(err)
	}
	if f, err := c.Read(3 * time.Second); err != nil || f.Type != wire.TypeForwardOK {
		t.Fatalf("got %v %v, want forward_ok", f.Type, err)
	}
	ch := <-fw.udp
	if ch.Node() != id {
		t.Fatalf("channel of node %q, want %q", ch.Node(), id)
	}
	_ = c.Write(wire.Datagram{Addr: "127.0.0.1:4000", Data: []byte("spoofed")}, time.Second)
	_ = c.Write(wire.Datagram{Addr: "10.3.0.5:40000", Data: []byte("register")}, time.Second)
	from, data, err := ch.ReadPacket()
	if err != nil || from.String() != "10.3.0.5:40000" || string(data) != "register" {
		t.Fatalf("got %v %q %v, want the second datagram from 10.3.0.5:40000", from, data, err)
	}
	if err := ch.WritePacket(from, []byte("answer")); err != nil {
		t.Fatal(err)
	}
	f, err := c.Read(3 * time.Second)
	var d wire.Datagram
	if err != nil || f.Type != wire.TypeDatagram || f.Decode(&d) != nil || d.Addr != "10.3.0.5:40000" || string(d.Data) != "answer" {
		t.Fatalf("node got %v %s %v", f.Type, f.Body, err)
	}
}
