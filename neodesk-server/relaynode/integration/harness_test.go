package integration

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"io"
	"log"
	mrand "math/rand/v2"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/neodeskapp/neodesk/neodesk-server/codec"
	"github.com/neodeskapp/neodesk/neodesk-server/config"
	"github.com/neodeskapp/neodesk/neodesk-server/crypto"
	"github.com/neodeskapp/neodesk/neodesk-server/db"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/agent"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/central"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
	"github.com/neodeskapp/neodesk/neodesk-server/signal"
	"google.golang.org/protobuf/proto"
)

// ---- small helpers ----

// logBuf collects log lines of one component.
type logBuf struct {
	mu sync.Mutex
	b  strings.Builder
}

func (l *logBuf) Logf(format string, args ...any) {
	l.mu.Lock()
	fmt.Fprintf(&l.b, format+"\n", args...)
	l.mu.Unlock()
}

func (l *logBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *logBuf) count(sub string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Count(l.b.String(), sub)
}

func (l *logBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// uuidLog records relay session uuids in the order they came.
type uuidLog struct {
	mu   sync.Mutex
	list []string
}

func (u *uuidLog) add(id string) {
	u.mu.Lock()
	u.list = append(u.list, id)
	u.mu.Unlock()
}

func (u *uuidLog) count(id string) int {
	u.mu.Lock()
	defer u.mu.Unlock()
	n := 0
	for _, x := range u.list {
		if x == id {
			n++
		}
	}
	return n
}

func (u *uuidLog) has(id string) bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, x := range u.list {
		if x == id {
			return true
		}
	}
	return false
}

// fakeBilling is the billing service the glue and the central relay
// report to.
type fakeBilling struct {
	activated, ended uuidLog
}

func (b *fakeBilling) ActivateRelay(id string) { b.activated.add(id) }
func (b *fakeBilling) EndRelay(id string)      { b.ended.add(id) }

func waitFor(t *testing.T, what string, within time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(within)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("%s: not within %s", what, within)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

var (
	portsMu   sync.Mutex
	portsUsed = map[int]bool{}
)

// freePorts finds a base port where base+each tcp offset (and base+each
// udp offset) can be listened on, so a server that derives its other
// ports from one setting (signal: -1, +2; relay: +2) can start.
func freePorts(t *testing.T, tcp, udp []int) int {
	t.Helper()
	portsMu.Lock()
	defer portsMu.Unlock()
	for range 500 {
		base := 20000 + mrand.IntN(40000)
		if portsUsed[base] {
			continue
		}
		var open []io.Closer
		ok := true
		for _, o := range tcp {
			ln, err := net.Listen("tcp", fmt.Sprintf(":%d", base+o))
			if err != nil {
				ok = false
				break
			}
			open = append(open, ln)
		}
		for _, o := range udp {
			if !ok {
				break
			}
			pc, err := net.ListenPacket("udp", fmt.Sprintf(":%d", base+o))
			if err != nil {
				ok = false
				break
			}
			open = append(open, pc)
		}
		for _, c := range open {
			c.Close()
		}
		if ok {
			for _, o := range append(append([]int{}, tcp...), udp...) {
				portsUsed[base+o] = true
			}
			return base
		}
	}
	t.Fatal("no free ports")
	return 0
}

// ---- central server ----

// server is a central server: SQLite, signal on real UDP/TCP sockets, the
// central relay, the sites service, the node hub and the glue, wired as
// main.go wires them (startRelayNodeHub calls central.Start).
type server struct {
	t           *testing.T
	dir         string
	db          db.Database
	kp          *crypto.KeyPair
	cfg         *config.Config
	sig         *signal.Server
	signalAddr  string // 127.0.0.1:port, TCP and UDP
	relayAddr   string // the central relay, as RELAY_SERVERS names it
	relayPort   int
	relayPaired uuidLog // uuids the central relay paired
	billing     *fakeBilling
	glue        *central.Glue
	hubLogs     *logBuf
	ctx         context.Context
}

func newServer(t *testing.T) *server {
	t.Helper()
	if testing.Short() {
		t.Skip("integration test: skipped with -short")
	}
	quietLog(t)
	dir := t.TempDir()
	database, err := db.OpenSQLite(filepath.Join(dir, "neodesk.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	kp, err := crypto.LoadOrGenerateKeyPair(filepath.Join(dir, "id_ed25519"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	cfg := config.DefaultConfig()
	cfg.EnrollmentMode = config.EnrollmentModeOpen
	cfg.KeyFile = filepath.Join(dir, "id_ed25519")
	cfg.DBPath = filepath.Join(dir, "neodesk.db")
	cfg.SignalPort = freePorts(t, []int{-1, 0, 2}, []int{0})
	cfg.RelayPort = freePorts(t, []int{0, 2}, nil)
	cfg.RelayServers = fmt.Sprintf("127.0.0.1:%d", cfg.RelayPort)

	s := &server{
		t: t, dir: dir, db: database, kp: kp, cfg: cfg, ctx: ctx,
		signalAddr: fmt.Sprintf("127.0.0.1:%d", cfg.SignalPort),
		relayAddr:  cfg.RelayServers, relayPort: cfg.RelayPort,
		billing: &fakeBilling{}, hubLogs: &logBuf{},
	}

	s.sig = signal.New(cfg, kp, database)
	if err := s.sig.Start(ctx); err != nil {
		t.Fatalf("signal: %v", err)
	}
	t.Cleanup(s.sig.Stop)

	// The central relay as main.go sets it up
	relaySrv := relay.New(cfg)
	relaySrv.SetSessionReporter(relay.SessionReporterFuncs{
		Started: func(id string) {
			s.relayPaired.add(id)
			s.billing.ActivateRelay(id)
		},
		Ended: func(id string, _ relay.SessionStats) {
			s.billing.EndRelay(id)
			_ = database.EndPeerConnectionSessionByRelay(id)
		},
	})
	if err := relaySrv.Start(ctx); err != nil {
		t.Fatalf("relay: %v", err)
	}
	t.Cleanup(relaySrv.Stop)

	glue, err := central.Start(ctx, central.Config{
		Addr: "127.0.0.1:0", CertDir: dir, ServerPK: kp.PublicKeyBase64(),
		DB: database, Billing: s.billing, Signal: s.sig,
		Hub:        hub.Config{Logf: s.hubLogs.Logf},
		ProbeDelay: 50 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("central: %v", err)
	}
	t.Cleanup(glue.Hub.Stop)
	s.glue = glue
	return s
}

// quietLog sends the standard logger (signal, relay, glue) to the test
// log only when the test fails.
func quietLog(t *testing.T) {
	buf := &logBuf{}
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() {
		log.SetOutput(prev)
		if t.Failed() {
			t.Logf("server log:\n%s", buf.String())
		}
	})
}

func (s *server) controlAddr() string {
	return fmt.Sprintf("127.0.0.1:%d", s.glue.ControlPort)
}

// site makes a site with a private network.
func (s *server) site(name, cidr string) string {
	return s.siteVPN(name, cidr, "")
}

// siteVPN makes a site with a private network in a VPN group.
func (s *server) siteVPN(name, cidr, vpn string) string {
	s.t.Helper()
	site, err := s.glue.Sites.CreateSite("", name, vpn)
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.glue.Sites.ReplaceNetworks(site.ID, []db.SiteNetwork{{CIDR: cidr, Kind: db.SiteNetworkPrivate}}); err != nil {
		s.t.Fatal(err)
	}
	return site.ID
}

// pin puts devices at a site. Every peer registers from 127.0.0.1, a
// public address no site network holds, so the pin decides.
func (s *server) pin(siteID string, devs ...device) {
	s.t.Helper()
	for _, d := range devs {
		if err := s.glue.Sites.SetPin(db.SitePinDevice, d.id, siteID); err != nil {
			s.t.Fatal(err)
		}
	}
}

// joinString is the enrollment string the console shows for a new token
// of the site, pointing at addr (the control listener, or a proxy).
func (s *server) joinString(siteID, addr string) string {
	s.t.Helper()
	token, _, err := s.glue.Sites.CreateEnrollmentToken(siteID, "integration-test")
	if err != nil {
		s.t.Fatal(err)
	}
	return wire.Join{Server: addr, Pin: s.glue.Pin, Token: token}.Encode()
}

// ---- relay nodes ----

type node struct {
	id        string
	agent     *agent.Agent
	relayAddr string // what peers dial: the node relay, or a proxy in front
	relayPort int
	legAddr   string // the leg listener
	logs      *logBuf
	stop      func()
	// fwdSignal and fwdNAT are the node's forward listeners (NODE_FORWARD),
	// "" without forwarding
	fwdSignal, fwdNAT string
}

type nodeOpts struct {
	// control routes the control connection through a proxy that sees
	// every frame (security test, lost acks)
	control *controlProxy
	// relayFront makes peers dial a capturing proxy in front of the relay
	relayFront bool
	relayProxy *relayProxy // set by startNode when relayFront
	// publicAddr is the public address the node reports, its relay
	// address when empty
	publicAddr string
	// legLan and legPublic override the leg addresses the node reports
	// ("none" for none); both default to its leg listener
	legLan, legPublic string
	// forward turns NODE_FORWARD on, with forward listeners on 127.0.0.1;
	// claim is the computer address the node vouches for (computers
	// here are all on loopback, which central refuses)
	forward bool
	claim   func(net.Addr) string
}

// startNode enrolls a relay node with a token of the site and waits until
// the hub has it online.
func (s *server) startNode(siteID string, o *nodeOpts) *node {
	t := s.t
	t.Helper()
	if o == nil {
		o = &nodeOpts{}
	}
	dataDir := t.TempDir()
	key, _, err := wire.LoadOrGenerateKey(filepath.Join(dataDir, agent.KeyFileName))
	if err != nil {
		t.Fatal(err)
	}
	controlAddr := s.controlAddr()
	if o.control != nil {
		o.control.start(t, s, key)
		controlAddr = o.control.addr()
	}
	relayPort := freePorts(t, []int{0, 2}, nil)
	relayAddr := fmt.Sprintf("127.0.0.1:%d", relayPort)
	if o.relayFront {
		o.relayProxy = startRelayProxy(t, relayAddr)
		relayAddr = o.relayProxy.addr()
	}
	publicAddr := relayAddr
	if o.publicAddr != "" {
		publicAddr = o.publicAddr
	}
	legPort := freePorts(t, []int{0}, nil)
	rcfg := config.DefaultConfig()
	rcfg.RelayPort = relayPort
	rcfg.KeyFile = filepath.Join(dataDir, "id_ed25519")
	logs := &logBuf{}
	acfg := agent.Config{
		Join: s.joinString(siteID, controlAddr), DataDir: dataDir,
		LanAddr: relayAddr, PublicAddr: publicAddr,
		LegPort: legPort, LegLanAddr: o.legLan, LegPublicAddr: o.legPublic,
		Relay: rcfg, Version: "integration", Logf: logs.Logf,
		BackoffMin: 50 * time.Millisecond, BackoffMax: 200 * time.Millisecond,
	}
	if o.forward {
		acfg.Forward = true
		acfg.ForwardSignalPort = freePorts(t, []int{-1, 0, 2}, []int{0})
		acfg.ForwardAPIPort = freePorts(t, []int{0}, nil)
		acfg.ForwardListen = "127.0.0.1"
		acfg.ClientAddr = o.claim
	}
	a, err := agent.New(acfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(s.ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := a.Run(ctx); err != nil {
			logs.Logf("agent run: %v", err)
		}
	}()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			<-done
		})
	}
	t.Cleanup(func() {
		stop()
		if t.Failed() {
			t.Logf("node %s log:\n%s", a.NodeID(), logs.String())
		}
	})
	waitFor(t, "node online at the hub", 5*time.Second, func() bool {
		return a.NodeID() != "" && s.glue.Hub.Online(a.NodeID())
	})
	n := &node{id: a.NodeID(), agent: a, relayAddr: relayAddr, relayPort: relayPort, legAddr: fmt.Sprintf("127.0.0.1:%d", legPort), logs: logs, stop: stop}
	if o.forward {
		n.fwdSignal, n.fwdNAT = a.ForwardAddr(wire.ServiceSignal), a.ForwardAddr(wire.ServiceNAT)
		// the UDP forwarding connection is one of the node's streams
		waitFor(t, "node's UDP forwarding open", 5*time.Second, func() bool { return s.glue.Hub.ForwardedStreams(n.id) >= 1 })
	}
	return n
}

// ---- fake RustDesk peers ----

type device struct {
	id string
	pk []byte // the device's Ed25519 public key, as RegisterPk sends it
}

func newDevice(prefix string) device {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return device{id: fmt.Sprintf("%s%06d", prefix, mrand.IntN(1000000)), pk: pub}
}

func (d device) registerPk() *pb.RegisterPk {
	return &pb.RegisterPk{Id: d.id, Uuid: []byte("machine-" + d.id), Pk: d.pk}
}

// registerTarget registers d over UDP as a controlled client does
// (RegisterPeer, then RegisterPk) and returns its UDP socket, where the
// forwarded RequestRelay arrives.
func (s *server) registerTarget(d device) *net.UDPConn {
	s.t.Helper()
	return s.registerTargetAt(d, s.signalAddr)
}

// registerTargetAt is registerTarget with the ID server at sigAddr (a
// node's forward port, or central).
func (s *server) registerTargetAt(d device, sigAddr string) *net.UDPConn {
	t := s.t
	t.Helper()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	sigUDP, _ := net.ResolveUDPAddr("udp4", sigAddr)
	send := func(m *pb.RendezvousMessage) {
		b, err := proto.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := c.WriteToUDP(b, sigUDP); err != nil {
			t.Fatal(err)
		}
	}
	send(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: d.id}}})
	if m := readUDP(t, c, func(m *pb.RendezvousMessage) bool { return m.GetRegisterPeerResponse() != nil }); !m.GetRegisterPeerResponse().GetRequestPk() {
		t.Fatalf("register %s: server did not ask for the key", d.id)
	}
	send(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPk{RegisterPk: d.registerPk()}})
	m := readUDP(t, c, func(m *pb.RendezvousMessage) bool { return m.GetRegisterPkResponse() != nil })
	if r := m.GetRegisterPkResponse().GetResult(); r != pb.RegisterPkResponse_OK {
		t.Fatalf("register %s: RegisterPk result %v", d.id, r)
	}
	return c
}

func readUDP(t *testing.T, c *net.UDPConn, want func(*pb.RendezvousMessage) bool) *pb.RendezvousMessage {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	buf := make([]byte, 65535)
	for {
		_ = c.SetReadDeadline(deadline)
		n, _, err := c.ReadFromUDP(buf)
		if err != nil {
			t.Fatalf("UDP read: %v", err)
		}
		m := &pb.RendezvousMessage{}
		if proto.Unmarshal(buf[:n], m) == nil && want(m) {
			return m
		}
	}
}

// dialInitiator opens the controlling client's TCP signal connection and
// registers its key on it, so signal knows who sends the RequestRelay that
// follows on the same connection.
func (s *server) dialInitiator(d device) net.Conn {
	s.t.Helper()
	return s.dialInitiatorAt(d, s.signalAddr)
}

// dialInitiatorAt is dialInitiator with the ID server at sigAddr.
func (s *server) dialInitiatorAt(d device, sigAddr string) net.Conn {
	t := s.t
	t.Helper()
	c, err := net.DialTimeout("tcp", sigAddr, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	// The server offers a KeyExchange first; a client that answers with a
	// plain message stays on plain framing
	if m, err := codec.ReadRawProto(c, 3*time.Second); err != nil || m.GetKeyExchange() == nil {
		t.Fatalf("signal TCP: want KeyExchange first, got %v, %v", m, err)
	}
	if err := codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPk{RegisterPk: d.registerPk()}}); err != nil {
		t.Fatal(err)
	}
	m, err := codec.ReadRawProto(c, 3*time.Second)
	if err != nil || m.GetRegisterPkResponse().GetResult() != pb.RegisterPkResponse_OK {
		t.Fatalf("initiator RegisterPk: %v, %v", m, err)
	}
	return c
}

// session is one relayed connection between two fake peers.
type session struct {
	uuid           string
	initiatorRelay string // the relay the initiator was told
	targetRelay    string // the relay the target was told
	signedPK       []byte // RelayResponse.pk: the target's key signed by the server
	ini, tgt       *recConn
	connected      time.Duration // RequestRelay sent to both sides paired and a byte through
}

// connect runs a relay session the way RustDesk clients do: the initiator
// sends RequestRelay over TCP signal and gets RelayResponse (uuid, relay),
// the target gets the forwarded RequestRelay over UDP, and both dial the
// relay they were told and send RequestRelay{uuid, licence_key}. It
// returns once the relay carries a byte each way.
func (s *server) connect(ini, tgt device) *session {
	s.t.Helper()
	return s.connectAt(ini, s.signalAddr, tgt, s.signalAddr)
}

// connectAt is connect with each peer's ID server: central, or the
// forward port of the node a peer sits behind.
func (s *server) connectAt(ini device, iniSig string, tgt device, tgtSig string) *session {
	t := s.t
	t.Helper()
	tgtUDP := s.registerTargetAt(tgt, tgtSig)
	sig := s.dialInitiatorAt(ini, iniSig)
	id := uuid.NewString()
	licence := s.kp.PublicKeyBase64()

	start := time.Now()
	if err := codec.WriteRawProto(sig, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{
		Id: tgt.id, Uuid: id, LicenceKey: licence,
	}}}); err != nil {
		t.Fatal(err)
	}
	m, err := codec.ReadRawProto(sig, 5*time.Second)
	if err != nil {
		t.Fatalf("RelayResponse: %v", err)
	}
	rr := m.GetRelayResponse()
	if rr == nil || rr.GetRefuseReason() != "" || rr.GetUuid() != id {
		t.Fatalf("RelayResponse %v, want uuid %s and no refusal", m, id)
	}
	fwd := readUDP(t, tgtUDP, func(m *pb.RendezvousMessage) bool { return m.GetRequestRelay() != nil }).GetRequestRelay()
	if fwd.GetUuid() != id {
		t.Fatalf("target got RequestRelay for uuid %q, want %q", fwd.GetUuid(), id)
	}
	ses := &session{uuid: id, initiatorRelay: rr.GetRelayServer(), targetRelay: fwd.GetRelayServer(), signedPK: rr.GetPk()}
	ses.tgt = dialRelay(t, ses.targetRelay, id, licence)
	ses.ini = dialRelay(t, ses.initiatorRelay, id, licence)
	exchange(t, ses.ini, ses.tgt, []byte("hello from the initiator "+id))
	exchange(t, ses.tgt, ses.ini, []byte("hello from the target "+id))
	ses.connected = time.Since(start)
	return ses
}

func (ses *session) close() {
	ses.ini.Close()
	ses.tgt.Close()
}

// recConn is a peer's relay connection that keeps every byte it wrote.
type recConn struct {
	net.Conn
	mu      sync.Mutex
	written bytes.Buffer
}

func (c *recConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	c.mu.Lock()
	c.written.Write(p[:n])
	c.mu.Unlock()
	return n, err
}

func (c *recConn) sent() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return bytes.Clone(c.written.Bytes())
}

// dialRelay connects to a relay as RustDesk's create_relay does: one
// RequestRelay with the uuid and the server key as licence_key, then the
// session's bytes.
func dialRelay(t *testing.T, addr, id, licence string) *recConn {
	t.Helper()
	raw, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		t.Fatalf("dial relay %s: %v", addr, err)
	}
	c := &recConn{Conn: raw}
	t.Cleanup(func() { c.Close() })
	if err := codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{
		Uuid: id, LicenceKey: licence,
	}}}); err != nil {
		t.Fatal(err)
	}
	return c
}

// exchange writes msg on from and checks it arrives whole on to.
func exchange(t *testing.T, from, to net.Conn, msg []byte) {
	t.Helper()
	_ = from.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if _, err := from.Write(msg); err != nil {
		t.Fatalf("write through relay: %v", err)
	}
	got := make([]byte, len(msg))
	_ = to.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(to, got); err != nil {
		t.Fatalf("read through relay: %v", err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("relay delivered %q, want %q", got, msg)
	}
}

// sessionRecord waits for the connection session row of the relay uuid
// to satisfy ok and returns it.
func (s *server) sessionRecord(hostID, relayUUID string, ok func(*db.PeerConnectionSession) bool) *db.PeerConnectionSession {
	s.t.Helper()
	var found *db.PeerConnectionSession
	deadline := time.Now().Add(3 * time.Second)
	for {
		rows, err := s.db.ListPeerConnectionSessions(hostID, 50)
		if err != nil {
			s.t.Fatal(err)
		}
		found = nil
		for _, r := range rows {
			if r.RelayUUID == relayUUID {
				found = r
			}
		}
		if found != nil && ok(found) {
			return found
		}
		if time.Now().After(deadline) {
			s.t.Fatalf("connection session of relay %s: got %+v", relayUUID, found)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// reach waits for the stored probe result of node from reaching node to
// and returns it.
func (s *server) reach(from, to string) db.SiteReachability {
	s.t.Helper()
	var got db.SiteReachability
	waitFor(s.t, "probe result "+from+" -> "+to, 5*time.Second, func() bool {
		rows, err := s.db.ListSiteReachability()
		if err != nil {
			s.t.Fatal(err)
		}
		for _, r := range rows {
			if r.FromNode == from && r.ToNode == to {
				got = r
				return true
			}
		}
		return false
	})
	return got
}

// isCentral says addr is the central relay (by port: signal may name it by
// the server's LAN address when both peers look like one network).
func (s *server) isCentral(addr string) bool {
	_, port, err := net.SplitHostPort(addr)
	return err == nil && port == fmt.Sprint(s.relayPort)
}
