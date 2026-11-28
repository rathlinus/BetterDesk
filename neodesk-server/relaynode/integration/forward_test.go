package integration

import (
	"bytes"
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/codec"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
	"google.golang.org/protobuf/proto"
)

// claimOn makes a node vouch for each loopback computer as an address of
// the network prefix ("10.3.0"), the host part taken from its port, so
// central sees the computers on the site's network.
func claimOn(prefix string) func(net.Addr) string {
	return func(a net.Addr) string {
		_, port, _ := net.SplitHostPort(a.String())
		p, _ := strconv.Atoi(port)
		return fmt.Sprintf("%s.%d:%s", prefix, 10+p%200, port)
	}
}

// online asks central's NAT test port whether id is online, as a
// client's address book does.
func (s *server) online(id string) bool {
	s.t.Helper()
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", s.cfg.NATTestPort()), 3*time.Second)
	if err != nil {
		s.t.Fatal(err)
	}
	defer c.Close()
	if err := codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_OnlineRequest{OnlineRequest: &pb.OnlineRequest{Id: "ASKER1", Peers: []string{id}}}}); err != nil {
		s.t.Fatal(err)
	}
	m, err := codec.ReadRawProto(c, 3*time.Second)
	if err != nil {
		s.t.Fatal(err)
	}
	st := m.GetOnlineResponse().GetStates()
	return len(st) > 0 && st[0]&0x80 != 0
}

// refusedRelay sends RequestRelay for tgt from ini (ID server iniSig)
// and returns the refusal, "" when the relay was granted.
func (s *server) refusedRelay(ini device, iniSig string, tgt device) (reason, id string) {
	s.t.Helper()
	sig := s.dialInitiatorAt(ini, iniSig)
	id = fmt.Sprintf("refuse-%d", time.Now().UnixNano())
	if err := codec.WriteRawProto(sig, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{
		Id: tgt.id, Uuid: id, LicenceKey: s.kp.PublicKeyBase64(),
	}}}); err != nil {
		s.t.Fatal(err)
	}
	m, err := codec.ReadRawProto(sig, 5*time.Second)
	if err != nil {
		s.t.Fatalf("RelayResponse: %v", err)
	}
	return m.GetRelayResponse().GetRefuseReason(), id
}

// checkSignedBy checks that signed is the IdPk of d signed with central's
// key, as the client verifies it with the key it is configured with.
func (s *server) checkSignedBy(signed []byte, d device) {
	s.t.Helper()
	if len(signed) <= ed25519.SignatureSize || !ed25519.Verify(s.kp.PublicKey, signed[ed25519.SignatureSize:], signed[:ed25519.SignatureSize]) {
		s.t.Fatalf("the peer key of %s is not signed with central's key", d.id)
	}
	var idpk pb.IdPk
	if err := proto.Unmarshal(signed[ed25519.SignatureSize:], &idpk); err != nil || idpk.Id != d.id || !bytes.Equal(idpk.Pk, d.pk) {
		s.t.Fatalf("signed IdPk %v, want %s's key", &idpk, d.id)
	}
}

// TestAComputerAtASiteWithoutInternetWorksThroughItsNode: site C has no
// internet; its computers talk only to node C's forward ports. Such a
// computer registers with its own address, shows online, is reached by a
// computer next to it, by a peer at site A and by a peer at no site, and
// reaches a peer at site B, always over node C and never the central
// relay. With node C gone its sessions are refused, not sent to the
// central relay it can't reach.
func TestAComputerAtASiteWithoutInternetWorksThroughItsNode(t *testing.T) {
	s := newServer(t)
	s.cfg.RendezvousServers = "central.example.com"
	siteA := s.site("Site A", "10.1.0.0/16")
	siteB := s.site("Site B", "10.2.0.0/16")
	siteC := s.site("Site C", "10.3.0.0/16")
	a := s.startNode(siteA, nil)
	b := s.startNode(siteB, nil)
	c := s.startNode(siteC, &nodeOpts{forward: true, claim: claimOn("10.3.0")})
	cpc, cpc2 := newDevice("CPC"), newDevice("CPD")
	pa, pb2, nosite := newDevice("PAA"), newDevice("PBB"), newDevice("NET")
	s.pin(siteA, pa)
	s.pin(siteB, pb2)

	// Registers with its own address, through node C, and shows online
	s.registerTargetAt(cpc, c.fwdSignal)
	e := s.sig.PeerMap().Get(cpc.id)
	if e == nil || !strings.HasPrefix(e.IP, "10.3.0.") {
		t.Fatalf("computer registered as %+v, want its own 10.3.0.x address", e)
	}
	if got := s.sig.PeerForwardNode(cpc.id); got != c.id {
		t.Fatalf("computer comes through %q, want node C %s", got, c.id)
	}
	if site := s.glue.Sites.DeviceSite(cpc.id, net.ParseIP(strings.Split(e.IP, ":")[0])); site == nil || site.ID != siteC {
		t.Fatalf("computer placed at %+v, want site C", site)
	}
	if !s.online(cpc.id) {
		t.Fatal("computer behind node C does not show online")
	}

	// The NAT test through node C sees the computer's own port (no NAT)
	// and does not hand it central's addresses
	nat, err := net.DialTimeout("tcp", c.fwdNAT, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer nat.Close()
	if err := codec.WriteRawProto(nat, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_TestNatRequest{TestNatRequest: &pb.TestNatRequest{}}}); err != nil {
		t.Fatal(err)
	}
	m, err := codec.ReadRawProto(nat, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if r := m.GetTestNatResponse(); r == nil || int(r.Port) != nat.LocalAddr().(*net.TCPAddr).Port || r.Cu != nil {
		t.Fatalf("NAT test through node C: %v; want port %d and no config update", m, nat.LocalAddr().(*net.TCPAddr).Port)
	}

	before := len(s.relayPaired.list)
	onlyC := func(name string, ses *session) {
		t.Helper()
		if ses.initiatorRelay != c.relayAddr || ses.targetRelay != c.relayAddr {
			t.Fatalf("%s: initiator told %q, target told %q; want node C %q", name, ses.initiatorRelay, ses.targetRelay, c.relayAddr)
		}
	}

	// Reached by the computer next to it
	ses := s.connectAt(cpc2, c.fwdSignal, cpc, c.fwdSignal)
	onlyC("same site", ses)
	s.checkSignedBy(ses.signedPK, cpc)
	waitFor(t, "node C counts the session", 3*time.Second, func() bool { return s.glue.Hub.ActiveSessions(c.id) == 1 })
	ses.close()

	// Reached by a peer at site A: node A and node C
	ses = s.connectAt(pa, s.signalAddr, cpc, c.fwdSignal)
	if ses.initiatorRelay != a.relayAddr || ses.targetRelay != c.relayAddr {
		t.Fatalf("from site A: initiator told %q, target told %q; want node A %q and node C %q",
			ses.initiatorRelay, ses.targetRelay, a.relayAddr, c.relayAddr)
	}
	exchange(t, ses.ini, ses.tgt, bytes.Repeat([]byte("site A to site C "), 1024))
	ses.close()

	// Reaches a peer at site B: node C and node B, and gets the peer's
	// key signed by central
	ses = s.connectAt(cpc, c.fwdSignal, pb2, s.signalAddr)
	if ses.initiatorRelay != c.relayAddr || ses.targetRelay != b.relayAddr {
		t.Fatalf("to site B: initiator told %q, target told %q; want node C %q and node B %q",
			ses.initiatorRelay, ses.targetRelay, c.relayAddr, b.relayAddr)
	}
	s.checkSignedBy(ses.signedPK, pb2)
	ses.close()

	// Reached by a peer at no site: node C alone (its public address),
	// where without the rule the central relay would be named
	ses = s.connectAt(nosite, s.signalAddr, cpc, c.fwdSignal)
	onlyC("peer at no site", ses)
	ses.close()

	if len(s.relayPaired.list) != before {
		t.Fatalf("the central relay paired %d sessions of the computer", len(s.relayPaired.list)-before)
	}

	// Node C gone: the computer is not handed the central relay
	c.stop()
	waitFor(t, "hub sees node C offline", 5*time.Second, func() bool { return !s.glue.Hub.Online(c.id) })
	reason, id := s.refusedRelay(pa, s.signalAddr, cpc)
	if reason == "" {
		t.Fatal("a session to the computer behind the stopped node C was granted")
	}
	if relay.DefaultTickets().Admitted(id, pa.id, cpc.id) {
		t.Fatal("signal issued a central relay ticket for the computer behind node C")
	}
}

// TestTheAPIThroughANodeSeesTheComputer: an API request to node C's
// forward API port reaches central's API with the computer's address,
// and a X-Forwarded-For the computer sets itself is dropped.
func TestTheAPIThroughANodeSeesTheComputer(t *testing.T) {
	s := newServer(t)
	got := make(chan string, 1)
	s.sig.SetAPIProxy(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- r.RemoteAddr + " xff=" + r.Header.Get("X-Forwarded-For")
		io.WriteString(w, "ok")
	}))
	siteC := s.site("Site C", "10.3.0.0/16")
	c := s.startNode(siteC, &nodeOpts{forward: true, claim: claimOn("10.3.0")})
	req, _ := http.NewRequest(http.MethodGet, "http://"+c.agent.ForwardAddr(wire.ServiceAPI)+"/api/heartbeat", nil)
	req.Header.Set("X-Forwarded-For", "203.0.113.66")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "ok" {
		t.Fatalf("API answer %q", body)
	}
	if seen := <-got; !strings.HasPrefix(seen, "10.3.0.") || !strings.HasSuffix(seen, " xff=") {
		t.Fatalf("API saw %q, want the computer's 10.3.0.x address and no X-Forwarded-For", seen)
	}
}
