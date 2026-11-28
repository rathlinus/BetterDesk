package signal

import (
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/audit"
	"github.com/neodeskapp/neodesk/neodesk-server/codec"
	"github.com/neodeskapp/neodesk/neodesk-server/config"
	cryptopkg "github.com/neodeskapp/neodesk/neodesk-server/crypto"
	"github.com/neodeskapp/neodesk/neodesk-server/peer"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/ratelimit"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"google.golang.org/protobuf/proto"
)

// fakeChannel is a node's UDP forwarding connection.
type fakeChannel struct {
	in     chan fwdPacket
	out    chan fwdPacket
	closed chan struct{}
	once   sync.Once
}

type fwdPacket struct {
	addr *net.UDPAddr
	msg  *pb.RendezvousMessage
}

func newFakeChannel() *fakeChannel {
	return &fakeChannel{in: make(chan fwdPacket, 16), out: make(chan fwdPacket, 16), closed: make(chan struct{})}
}

func (c *fakeChannel) ReadPacket() (*net.UDPAddr, []byte, error) {
	select {
	case p := <-c.in:
		b, _ := proto.Marshal(p.msg)
		return p.addr, b, nil
	case <-c.closed:
		return nil, nil, io.EOF
	}
}

func (c *fakeChannel) WritePacket(to *net.UDPAddr, data []byte) error {
	m := &pb.RendezvousMessage{}
	if err := proto.Unmarshal(data, m); err != nil {
		return err
	}
	c.out <- fwdPacket{addr: to, msg: m}
	return nil
}

func (c *fakeChannel) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

// next returns the next datagram the server sent through the node.
func (c *fakeChannel) next(t *testing.T) fwdPacket {
	t.Helper()
	select {
	case p := <-c.out:
		return p
	case <-time.After(2 * time.Second):
		t.Fatal("nothing sent through the node")
		return fwdPacket{}
	}
}

func (c *fakeChannel) none(t *testing.T) {
	t.Helper()
	select {
	case p := <-c.out:
		t.Fatalf("sent %v to %s through the node, want nothing", p.msg, p.addr)
	case <-time.After(200 * time.Millisecond):
	}
}

// serveChannel runs ServeForwardedUDP for node on a new channel.
func serveChannel(t *testing.T, srv *Server, node string) *fakeChannel {
	t.Helper()
	ch := newFakeChannel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.ServeForwardedUDP(node, ch)
	}()
	t.Cleanup(func() {
		ch.Close()
		<-done
	})
	return ch
}

// fwdConn is one end of a pipe whose remote address is a computer's.
type fwdConn struct {
	net.Conn
	remote *net.TCPAddr
}

func (c *fwdConn) RemoteAddr() net.Addr { return c.remote }

// forwardTCP serves a forwarded stream from client and returns the
// computer's end.
func forwardTCP(t *testing.T, srv *Server, node, service, client string) net.Conn {
	t.Helper()
	server, computer := net.Pipe()
	addr, err := net.ResolveTCPAddr("tcp", client)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.ServeForwardedTCP(node, service, &fwdConn{Conn: server, remote: addr})
	}()
	t.Cleanup(func() {
		computer.Close()
		<-done
	})
	return computer
}

// TestAForwardedComputerRegistersWithItsOwnAddress: a RegisterPeer that
// comes through node C registers the computer at its own LAN address,
// the answer goes back through node C (the server has no UDP socket at
// all here), and the peer is known to come through node C.
func TestAForwardedComputerRegistersWithItsOwnAddress(t *testing.T) {
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	ch := serveChannel(t, srv, "node-c")
	from := udpAddr("10.3.0.5", 40000)
	ch.in <- fwdPacket{addr: from, msg: &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: "SITECPC1"}}}}

	p := ch.next(t)
	if p.addr.String() != "10.3.0.5:40000" || p.msg.GetRegisterPeerResponse() == nil {
		t.Fatalf("node got %v for %s, want RegisterPeerResponse for 10.3.0.5:40000", p.msg, p.addr)
	}
	e := srv.peers.GetLocal("SITECPC1")
	if e == nil || e.IP != "10.3.0.5:40000" {
		t.Fatalf("peer entry %+v, want IP 10.3.0.5:40000", e)
	}
	if got := srv.PeerForwardNode("SITECPC1"); got != "node-c" {
		t.Fatalf("peer comes through %q, want node-c", got)
	}
	if got := srv.ForwardedPeers("node-c"); got != 1 {
		t.Fatalf("node-c has %d forwarded peers, want 1", got)
	}
	// An address that never came through a node is not sent there
	srv.sendUDP(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_Hc{Hc: &pb.HealthCheck{}}}, udpAddr("10.3.0.6", 40000))
	ch.none(t)
}

// TestAComputerKeepsItsNodeWhenTheNodesConnectionDrops: after node C's
// UDP connection ends the computer still counts as behind node C, so its
// sessions stay off the central relay, and nothing is sent to its private
// address from the server's own socket.
func TestAComputerKeepsItsNodeWhenTheNodesConnectionDrops(t *testing.T) {
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	attachTestUDPPair(t, srv) // a direct send would succeed
	ch := newFakeChannel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.ServeForwardedUDP("node-c", ch)
	}()
	from := udpAddr("10.3.0.5", 40000)
	ch.in <- fwdPacket{addr: from, msg: &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: "SITECPC1"}}}}
	ch.next(t)
	ch.Close()
	<-done

	if got := srv.PeerForwardNode("SITECPC1"); got != "node-c" {
		t.Fatalf("after the drop the peer comes through %q, want node-c", got)
	}
	if srv.sendUDP(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_Hc{Hc: &pb.HealthCheck{}}}, from) {
		t.Fatal("a datagram to the computer was sent although its node is gone")
	}
}

// TestForwardedConnectionsAreRateLimitedByTheComputersAddress: the signal
// connection limit counts each computer behind a node on its own, not the
// node's address for all of them.
func TestForwardedConnectionsAreRateLimitedByTheComputersAddress(t *testing.T) {
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	kp, err := cryptopkg.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	srv.kp = kp
	srv.SetRateLimiter(ratelimit.NewIPLimiter(1, time.Minute, time.Minute))
	greets := func(client string) bool {
		c := forwardTCP(t, srv, "node-c", ForwardSignal, client)
		m, err := codec.ReadRawProto(c, 2*time.Second)
		return err == nil && m.GetKeyExchange() != nil
	}
	if !greets("10.3.0.5:5000") {
		t.Fatal("first connection of 10.3.0.5 got no KeyExchange")
	}
	if greets("10.3.0.5:5001") {
		t.Fatal("second connection of 10.3.0.5 within the minute was not limited")
	}
	if !greets("10.3.0.6:5000") {
		t.Fatal("10.3.0.6 behind the same node was limited by its neighbour's connection")
	}
}

// TestForwardedNATTestSeesTheComputersPortAndNoServerList: the NAT test
// answers with the port the computer used, so a client behind a node finds
// no NAT; and it leaves out RENDEZVOUS_SERVERS, which the computer can't
// reach, while a direct client still gets them.
func TestForwardedNATTestSeesTheComputersPortAndNoServerList(t *testing.T) {
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	srv.cfg.RendezvousServers = "central.example.com"
	c := forwardTCP(t, srv, "node-c", ForwardNAT, "10.3.0.5:51000")
	if err := codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_TestNatRequest{TestNatRequest: &pb.TestNatRequest{Serial: 3}}}); err != nil {
		t.Fatal(err)
	}
	m, err := codec.ReadRawProto(c, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if r := m.GetTestNatResponse(); r == nil || r.Port != 51000 || r.Cu != nil {
		t.Fatalf("forwarded NAT test answer %v, want port 51000 and no config update", m)
	}
	direct := srv.handleTestNat(&pb.TestNatRequest{Serial: 3}, &net.TCPAddr{IP: net.ParseIP("198.51.100.4"), Port: 51000})
	if direct.GetTestNatResponse().GetCu() == nil {
		t.Fatal("a direct client lost the config update")
	}
}

// TestForwardedRefusalsAreAuditedWithTheComputersAddress: a refused
// request through a node is audited under the computer's address.
func TestForwardedRefusalsAreAuditedWithTheComputersAddress(t *testing.T) {
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	logger := audit.NewLogger("")
	srv.SetAuditLogger(logger)
	putOnlinePeer(srv, "AUDITTGT1", "203.0.113.94", 52000, peer.ConnUDP)
	ch := serveChannel(t, srv, "node-c")
	ch.in <- fwdPacket{addr: udpAddr("10.3.0.7", 40000), msg: &pb.RendezvousMessage{Union: &pb.RendezvousMessage_PunchHoleRequest{PunchHoleRequest: &pb.PunchHoleRequest{Id: "AUDITTGT1"}}}}
	ch.next(t) // the refusal goes back through the node
	denied := logger.RecentByAction(audit.ActionConnectionDenied, 10)
	if len(denied) != 1 || denied[0].Actor != "10.3.0.7" {
		t.Fatalf("audit %+v, want one denial by 10.3.0.7", denied)
	}
}

// ---- routing ----

// fwdRouter is a site router that knows forwarded peers.
type fwdRouter struct {
	fakeSiteRouter
	route NodeRelay
	ok    bool
	mu    sync.Mutex
	calls [][2]string // initiator node, target node
}

func (f *fwdRouter) ForwardedNodeRoute(_ string, _ net.IP, iNode, _ string, _ net.IP, tNode string) (NodeRelay, bool) {
	f.mu.Lock()
	f.calls = append(f.calls, [2]string{iNode, tNode})
	f.mu.Unlock()
	return f.route, f.ok
}

// fwdFixture: initiator SITEINI1 reaches the server directly on a local
// UDP socket, target SITECPC1 is at 10.3.0.5:40000 behind node-c.
type fwdFixture struct {
	srv     *Server
	central *recordingTickets
	node    *recordingTickets
	ini     *net.UDPConn
	iniA    *net.UDPAddr
	tgt     *fakeChannel
}

func newFwdFixture(t *testing.T, router SiteRouter) *fwdFixture {
	t.Helper()
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	srv.cfg.P2PFirst = false
	central := &recordingTickets{}
	srv.SetTickets(central)
	ini, iniA := attachTestUDPPair(t, srv)
	putOnlinePeer(srv, "SITEINI1", "127.0.0.1", iniA.Port, peer.ConnUDP)
	tgt := serveChannel(t, srv, "node-c")
	tgt.in <- fwdPacket{addr: udpAddr("10.3.0.5", 40000), msg: &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: "SITECPC1"}}}}
	tgt.next(t)
	srv.SetSiteRouter(router)
	f := &fwdFixture{srv: srv, central: central, ini: ini, iniA: iniA, tgt: tgt}
	if r, ok := router.(*fwdRouter); ok {
		f.node = r.route.Tickets.(*recordingTickets)
	}
	return f
}

func newRouter(ok bool, nodeErr error) *fwdRouter {
	store := &recordingTickets{err: nodeErr}
	return &fwdRouter{
		route: NodeRelay{Addr: nodeInitiatorAddr, TargetAddr: "10.3.0.2:21117", Tickets: store, Via: "node:node-c"},
		ok:    ok,
	}
}

// TestAForwardedTargetIsRelayedByItsNode: the router is asked for the
// route with the target's node, the target is told its node's address,
// the node's store gets the ticket and the central relay nothing.
func TestAForwardedTargetIsRelayedByItsNode(t *testing.T) {
	r := newRouter(true, nil)
	f := newFwdFixture(t, r)
	f.srv.handleRequestRelay(&pb.RequestRelay{Id: "SITECPC1", Uuid: "fwd-rr"}, f.iniA)

	p := f.tgt.next(t)
	if p.addr.String() != "10.3.0.5:40000" || p.msg.GetRequestRelay().GetRelayServer() != "10.3.0.2:21117" {
		t.Fatalf("target got %v at %s, want RequestRelay naming 10.3.0.2:21117", p.msg, p.addr)
	}
	if got := readUDPRendezvous(t, f.ini).GetRelayResponse().GetRelayServer(); got != nodeInitiatorAddr {
		t.Fatalf("initiator told %q, want %q", got, nodeInitiatorAddr)
	}
	if len(r.calls) != 1 || r.calls[0] != [2]string{"", "node-c"} {
		t.Fatalf("router asked with nodes %v, want [\"\" node-c]", r.calls)
	}
	if len(f.node.issuedUUIDs()) != 1 || len(f.central.issuedUUIDs()) != 0 {
		t.Fatalf("node tickets %v, central tickets %v", f.node.issuedUUIDs(), f.central.issuedUUIDs())
	}
}

// TestAForwardedPeerNeverGetsTheCentralRelay: without a node route (the
// router has none, the router can't route forwarded peers, or the node
// can't take the ticket) the relay is refused; the central relay never
// gets a ticket and the target is never told to dial it.
func TestAForwardedPeerNeverGetsTheCentralRelay(t *testing.T) {
	for name, router := range map[string]SiteRouter{
		"no route":            newRouter(false, nil),
		"router without hook": &fakeSiteRouter{ini: "SITEINI1", tgt: "SITECPC1", store: &recordingTickets{}},
		"node unavailable":    newRouter(true, relay.ErrTicketsUnavailable),
	} {
		t.Run(name, func(t *testing.T) {
			f := newFwdFixture(t, router)
			f.srv.handleRequestRelay(&pb.RequestRelay{Id: "SITECPC1", Uuid: "fwd-none"}, f.iniA)
			rr := readUDPRendezvous(t, f.ini).GetRelayResponse()
			if rr.GetRefuseReason() != refuseRelayUnavailable {
				t.Fatalf("initiator got %v, want refusal %q", rr, refuseRelayUnavailable)
			}
			if got := f.central.issuedUUIDs(); len(got) != 0 {
				t.Fatalf("central relay got tickets %v", got)
			}
			f.tgt.none(t)
		})
	}
}

// TestAPunchToAForwardedPeerIsForcedToRelay: a punch hole request to a
// computer behind a node gets a relay answer, and the target is asked to
// dial its node instead of punching towards the initiator.
func TestAPunchToAForwardedPeerIsForcedToRelay(t *testing.T) {
	f := newFwdFixture(t, newRouter(true, nil))
	f.srv.handlePunchHoleRequest(&pb.PunchHoleRequest{Id: "SITECPC1", NatType: pb.NatType_ASYMMETRIC}, f.iniA)
	if m := readUDPRendezvous(t, f.ini); m.GetRelayResponse().GetRelayServer() != nodeInitiatorAddr {
		t.Fatalf("initiator got %v, want a RelayResponse naming the node", m)
	}
	p := f.tgt.next(t)
	if p.msg.GetPunchHole() != nil || p.msg.GetRequestRelay().GetRelayServer() != "10.3.0.2:21117" {
		t.Fatalf("target got %v, want RequestRelay naming its node", p.msg)
	}
}

// TestOnlyPeersBehindOneNodeShareANetwork: two computers behind node C on
// one subnet are one LAN (direct connection allowed); the same addresses
// behind two nodes are not, and neither is a direct peer on that subnet.
func TestOnlyPeersBehindOneNodeShareANetwork(t *testing.T) {
	srv, _ := newTestSignalServer(t, config.EnrollmentModeOpen)
	srv.SetSiteRouter(newRouter(true, nil))
	c := serveChannel(t, srv, "node-c")
	d := serveChannel(t, srv, "node-d")
	hb := func(ch *fakeChannel, ip string, port int, id string) *net.UDPAddr {
		a := udpAddr(ip, port)
		ch.in <- fwdPacket{addr: a, msg: &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: id}}}}
		ch.next(t)
		return a
	}
	a := hb(c, "192.168.1.10", 4000, "LANPEER1")
	b := hb(c, "192.168.1.11", 4000, "LANPEER2")
	other := hb(d, "192.168.1.12", 4000, "LANPEER3")
	direct := udpAddr("192.168.1.13", 4000)

	route := srv.chooseRelay(relayRouteRequest{base: srv.getRelayServer(), a: a, b: b, initiatorID: "LANPEER1", targetID: "LANPEER2"})
	if !route.SameNetwork || route.ForceRelay {
		t.Fatalf("one node: same network %v, force relay %v; want true, false", route.SameNetwork, route.ForceRelay)
	}
	for name, peerB := range map[string]*net.UDPAddr{"two nodes": other, "direct peer": direct} {
		route = srv.chooseRelay(relayRouteRequest{base: srv.getRelayServer(), a: a, b: peerB, initiatorID: "LANPEER1", targetID: "LANPEER3"})
		if route.SameNetwork || !route.ForceRelay || route.Hairpin {
			t.Fatalf("%s: same network %v, force relay %v, hairpin %v; want false, true, false", name, route.SameNetwork, route.ForceRelay, route.Hairpin)
		}
	}
	// Without forwarding the same addresses are one LAN, as before
	route = srv.chooseRelay(relayRouteRequest{base: srv.getRelayServer(), a: direct, b: udpAddr("192.168.1.14", 4000)})
	if !route.SameNetwork {
		t.Fatal("two direct peers on one subnet lost the LAN rule")
	}
}
