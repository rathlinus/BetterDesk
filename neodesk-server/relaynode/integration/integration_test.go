package integration

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/db"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
)

// TestPeersAtOneSiteRelayThroughTheSiteNode: two peers at site A are both
// told node A's address, their bytes go through node A, the central relay
// gets neither a ticket nor a connection, and the session is billed and
// recorded as relayed by node A.
func TestPeersAtOneSiteRelayThroughTheSiteNode(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	siteB := s.site("Site B", "10.2.0.0/16")
	a := s.startNode(siteA, nil)
	b := s.startNode(siteB, nil)
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini, tgt)

	ses := s.connect(ini, tgt)
	if ses.initiatorRelay != a.relayAddr || ses.targetRelay != a.relayAddr {
		t.Fatalf("initiator told %q, target told %q; want node A %q (node B %q, central %q)",
			ses.initiatorRelay, ses.targetRelay, a.relayAddr, b.relayAddr, s.relayAddr)
	}
	waitFor(t, "hub counts node A's session", 3*time.Second, func() bool { return s.glue.Hub.ActiveSessions(a.id) == 1 })
	if n := s.glue.Hub.ActiveSessions(b.id); n != 0 {
		t.Fatalf("node B has %d sessions, want 0", n)
	}
	waitFor(t, "billing activated", 3*time.Second, func() bool { return s.billing.activated.has(ses.uuid) })
	if s.relayPaired.has(ses.uuid) {
		t.Fatal("the central relay paired the session too")
	}
	if relay.DefaultTickets().Admitted(ses.uuid, ini.id, tgt.id) {
		t.Fatal("signal issued the session's ticket on the central relay")
	}

	ses.close()
	waitFor(t, "billing ended", 3*time.Second, func() bool { return s.billing.ended.has(ses.uuid) })
	waitFor(t, "hub sees the session end", 3*time.Second, func() bool { return s.glue.Hub.ActiveSessions(a.id) == 0 })
	rec := s.sessionRecord(tgt.id, ses.uuid, func(r *db.PeerConnectionSession) bool { return r.EndedAt != nil })
	if rec.RelayVia != "node:"+a.id || rec.PeerID != ini.id {
		t.Fatalf("session record via %q from %q, want via node:%s from %s", rec.RelayVia, rec.PeerID, a.id, ini.id)
	}
}

// TestAStoppedNodeLeavesSessionsOnTheCentralRelay: once node A's agent is
// gone, the next session at site A goes through the central relay, and
// connects in well under 5 s.
func TestAStoppedNodeLeavesSessionsOnTheCentralRelay(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	a := s.startNode(siteA, nil)
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini, tgt)

	a.stop()
	waitFor(t, "hub sees node A offline", 5*time.Second, func() bool { return !s.glue.Hub.Online(a.id) })

	ses := s.connect(ini, tgt)
	if !s.isCentral(ses.initiatorRelay) || !s.isCentral(ses.targetRelay) {
		t.Fatalf("initiator told %q, target told %q; want the central relay %q", ses.initiatorRelay, ses.targetRelay, s.relayAddr)
	}
	if ses.connected >= 5*time.Second {
		t.Fatalf("connecting took %s, want < 5 s", ses.connected)
	}
	waitFor(t, "central relay pairs the session", 3*time.Second, func() bool { return s.relayPaired.has(ses.uuid) })
	ses.close()
	rec := s.sessionRecord(tgt.id, ses.uuid, func(r *db.PeerConnectionSession) bool { return r.EndedAt != nil })
	if rec.RelayVia != "central" && rec.RelayVia != "lan" {
		t.Fatalf("session record via %q, want central or lan", rec.RelayVia)
	}
}

// TestANodeThatNeverAcksFallsBackWithinTheBudget: node A is connected but
// its acks never come (the proxy drops the authorize frames). The session
// waits out the hub's authorize budget once, then goes to the central
// relay.
func TestANodeThatNeverAcksFallsBackWithinTheBudget(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	proxy := &controlProxy{}
	a := s.startNode(siteA, &nodeOpts{control: proxy})
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini, tgt)
	proxy.dropAuthorize.Store(true)

	ses := s.connect(ini, tgt)
	if proxy.droppedCount() != 1 {
		t.Fatalf("the hub pushed %d tickets to node A, want 1", proxy.droppedCount())
	}
	if !s.isCentral(ses.initiatorRelay) || !s.isCentral(ses.targetRelay) {
		t.Fatalf("initiator told %q, target told %q; want the central relay %q (node A %q)",
			ses.initiatorRelay, ses.targetRelay, s.relayAddr, a.relayAddr)
	}
	// The budget is spent waiting for the ack; the fallback adds little
	if ses.connected < hub.DefaultAuthorizeBudget-100*time.Millisecond || ses.connected > hub.DefaultAuthorizeBudget+1500*time.Millisecond {
		t.Fatalf("connecting took %s, want about the %s budget", ses.connected, hub.DefaultAuthorizeBudget)
	}
	waitFor(t, "central relay pairs the session", 3*time.Second, func() bool { return s.relayPaired.has(ses.uuid) })
	ses.close()
}

// TestPeersAtTwoSitesRelayOverBothNodes: the initiator dials its site's
// node, the target its own, node A dials node B over TLS and the bytes go
// client A -> node A -> node B -> client B. Both nodes report the session,
// the central relay sees nothing, billing counts it once, and the record
// says it went over both nodes.
func TestPeersAtTwoSitesRelayOverBothNodes(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	siteB := s.site("Site B", "10.2.0.0/16")
	a := s.startNode(siteA, nil)
	b := s.startNode(siteB, nil)
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini)
	s.pin(siteB, tgt)
	// The nodes probe each other when they connect
	if r := s.reach(a.id, b.id); !r.OK || r.Via != "public" {
		t.Fatalf("probe A -> B: %+v, want reachable over public", r)
	}

	ses := s.connect(ini, tgt)
	if ses.initiatorRelay != a.relayAddr || ses.targetRelay != b.relayAddr {
		t.Fatalf("initiator told %q, target told %q; want node A %q and node B %q",
			ses.initiatorRelay, ses.targetRelay, a.relayAddr, b.relayAddr)
	}
	exchange(t, ses.ini, ses.tgt, bytes.Repeat([]byte("site to site "), 4096))
	waitFor(t, "both nodes count the session", 3*time.Second, func() bool {
		return s.glue.Hub.ActiveSessions(a.id) == 1 && s.glue.Hub.ActiveSessions(b.id) == 1
	})
	if !strings.Contains(a.logs.String(), "to "+b.legAddr+" open") {
		t.Fatalf("node A did not dial node B's leg listener %s:\n%s", b.legAddr, a.logs.String())
	}
	if !strings.Contains(b.logs.String(), "Leg of UUID "+ses.uuid[:8]) {
		t.Fatalf("node B took no leg for the session:\n%s", b.logs.String())
	}
	if s.relayPaired.has(ses.uuid) {
		t.Fatal("the central relay paired the session")
	}
	if relay.DefaultTickets().Admitted(ses.uuid, ini.id, tgt.id) {
		t.Fatal("signal issued the session's ticket on the central relay")
	}
	waitFor(t, "billing activated", 3*time.Second, func() bool { return s.billing.activated.has(ses.uuid) })
	ses.close()
	waitFor(t, "billing ended", 3*time.Second, func() bool { return s.billing.ended.has(ses.uuid) })
	waitFor(t, "both nodes see the end", 3*time.Second, func() bool {
		return s.glue.Hub.ActiveSessions(a.id) == 0 && s.glue.Hub.ActiveSessions(b.id) == 0
	})
	if n := s.billing.activated.count(ses.uuid) + s.billing.ended.count(ses.uuid); n != 2 {
		t.Fatalf("billing heard of the session %d times, want once started and once ended", n)
	}
	rec := s.sessionRecord(tgt.id, ses.uuid, func(r *db.PeerConnectionSession) bool { return r.EndedAt != nil })
	if want := "nodes:" + a.id + "," + b.id; rec.RelayVia != want {
		t.Fatalf("session record via %q, want %q", rec.RelayVia, want)
	}
}

// TestSitesOnOneVPNDialTheOtherNodesLANAddress: neither node's leg
// listener has a public address. Without a shared VPN group the sites
// can't pair and one node relays; once both sites are in the same VPN
// group node A dials node B's LAN address.
func TestSitesOnOneVPNDialTheOtherNodesLANAddress(t *testing.T) {
	s := newServer(t)
	siteA := s.siteVPN("Site A", "10.1.0.0/16", "corp")
	siteB := s.site("Site B", "10.2.0.0/16")
	a := s.startNode(siteA, &nodeOpts{legPublic: "none"})
	b := s.startNode(siteB, &nodeOpts{legPublic: "none"})
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini)
	s.pin(siteB, tgt)
	lan, public := s.glue.Hub.LegAddrs(b.id)
	if lan != b.legAddr || public != "" {
		t.Fatalf("node B reports leg addresses %q and %q, want only the LAN one %q", lan, public, b.legAddr)
	}

	before := s.connect(ini, tgt)
	if before.initiatorRelay != before.targetRelay {
		t.Fatalf("without a shared VPN group: initiator told %q, target told %q; want one node for both", before.initiatorRelay, before.targetRelay)
	}
	before.close()

	vpn := "corp"
	if _, err := s.glue.Sites.UpdateSite(siteB, nil, &vpn); err != nil {
		t.Fatal(err)
	}
	ini2, tgt2 := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini2)
	s.pin(siteB, tgt2)
	ses := s.connect(ini2, tgt2)
	if ses.initiatorRelay != a.relayAddr || ses.targetRelay != b.relayAddr {
		t.Fatalf("same VPN group: initiator told %q, target told %q; want node A %q and node B %q",
			ses.initiatorRelay, ses.targetRelay, a.relayAddr, b.relayAddr)
	}
	if !strings.Contains(a.logs.String(), "to "+lan+" open") {
		t.Fatalf("node A did not dial node B's LAN leg address %s:\n%s", lan, a.logs.String())
	}
	if s.relayPaired.has(ses.uuid) {
		t.Fatal("the central relay paired the session")
	}
	ses.close()
	rec := s.sessionRecord(tgt2.id, ses.uuid, func(r *db.PeerConnectionSession) bool { return r.EndedAt != nil })
	if want := "nodes:" + a.id + "," + b.id; rec.RelayVia != want {
		t.Fatalf("session record via %q, want %q", rec.RelayVia, want)
	}
}

// TestSitesWhoseNodesCantReachEachOtherUseOneNode: both nodes report leg
// addresses nobody listens on, the probes store that neither reaches the
// other, and the session goes through one node both peers reach.
func TestSitesWhoseNodesCantReachEachOtherUseOneNode(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	siteB := s.site("Site B", "10.2.0.0/16")
	deadA := fmt.Sprintf("127.0.0.1:%d", freePorts(t, []int{0}, nil))
	deadB := fmt.Sprintf("127.0.0.1:%d", freePorts(t, []int{0}, nil))
	a := s.startNode(siteA, &nodeOpts{legPublic: deadA})
	b := s.startNode(siteB, &nodeOpts{legPublic: deadB})
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini)
	s.pin(siteB, tgt)
	if r := s.reach(a.id, b.id); r.OK || r.Via != "public" {
		t.Fatalf("probe A -> B: %+v, want unreachable", r)
	}
	if r := s.reach(b.id, a.id); r.OK {
		t.Fatalf("probe B -> A: %+v, want unreachable", r)
	}

	ses := s.connect(ini, tgt)
	if ses.initiatorRelay != ses.targetRelay || (ses.initiatorRelay != a.relayAddr && ses.initiatorRelay != b.relayAddr) {
		t.Fatalf("initiator told %q, target told %q; want one of the nodes (A %q, B %q) for both",
			ses.initiatorRelay, ses.targetRelay, a.relayAddr, b.relayAddr)
	}
	if s.relayPaired.has(ses.uuid) {
		t.Fatal("the central relay paired the session")
	}
	ses.close()
	rec := s.sessionRecord(tgt.id, ses.uuid, func(r *db.PeerConnectionSession) bool { return r.EndedAt != nil })
	if rec.RelayVia != "node:"+a.id && rec.RelayVia != "node:"+b.id {
		t.Fatalf("session record via %q, want one node", rec.RelayVia)
	}
}

// TestAPairWithANodeThatNeverAcksMovesToOneNode: node B's acks never come;
// after the budget the session goes through one node, not the central
// relay.
func TestAPairWithANodeThatNeverAcksMovesToOneNode(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	siteB := s.site("Site B", "10.2.0.0/16")
	proxy := &controlProxy{}
	a := s.startNode(siteA, nil)
	b := s.startNode(siteB, &nodeOpts{control: proxy})
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini)
	s.pin(siteB, tgt)
	s.reach(a.id, b.id)
	proxy.dropAuthorize.Store(true)

	// The one-node fallback is the less loaded node: node A, or node B,
	// whose acks don't come either, and then the central relay
	ses := s.connect(ini, tgt)
	if ses.initiatorRelay != ses.targetRelay || ses.initiatorRelay == b.relayAddr {
		t.Fatalf("initiator told %q, target told %q; want node A %q or the central relay %q for both (node B %q)",
			ses.initiatorRelay, ses.targetRelay, a.relayAddr, s.relayAddr, b.relayAddr)
	}
	if ses.initiatorRelay == a.relayAddr && s.relayPaired.has(ses.uuid) {
		t.Fatal("node A and the central relay both paired the session")
	}
	if ses.connected > 2*hub.DefaultAuthorizeBudget+1500*time.Millisecond {
		t.Fatalf("connecting took %s", ses.connected)
	}
	ses.close()
}

// TestARevokedNodeIsCutOffAndRefusedOnReconnect: revoking node A closes
// its control connection, the next session goes to the central relay, and
// the agent's reconnects are refused.
func TestARevokedNodeIsCutOffAndRefusedOnReconnect(t *testing.T) {
	s := newServer(t)
	siteA := s.site("Site A", "10.1.0.0/16")
	a := s.startNode(siteA, nil)
	ini, tgt := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini, tgt)

	// Node A carries sessions before the revocation
	before := s.connect(ini, tgt)
	if before.initiatorRelay != a.relayAddr {
		t.Fatalf("before the revocation the initiator was told %q, want node A %q", before.initiatorRelay, a.relayAddr)
	}
	before.close()

	if err := s.glue.Sites.RevokeNode(a.id); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "hub drops node A", 3*time.Second, func() bool { return !s.glue.Hub.Online(a.id) })

	ini2, tgt2 := newDevice("INI"), newDevice("TGT")
	s.pin(siteA, ini2, tgt2)
	after := s.connect(ini2, tgt2)
	if !s.isCentral(after.initiatorRelay) || !s.isCentral(after.targetRelay) {
		t.Fatalf("after the revocation: initiator told %q, target told %q; want the central relay %q",
			after.initiatorRelay, after.targetRelay, s.relayAddr)
	}
	after.close()

	// The agent keeps retrying (50-200 ms backoff); each try is refused
	refused := "Refused node connection from 127.0.0.1: revoked"
	waitFor(t, "hub refuses the agent's reconnects", 5*time.Second, func() bool { return s.hubLogs.count(refused) >= 2 })
	if !strings.Contains(a.logs.String(), "central refused the node: revoked") {
		t.Fatalf("the agent did not hear it was revoked:\n%s", a.logs.String())
	}
	if s.glue.Hub.Online(a.id) {
		t.Fatal("node A is online again after the revocation")
	}
}
