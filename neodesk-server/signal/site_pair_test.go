package signal

import (
	"fmt"
	"net"
	"testing"

	cryptopkg "github.com/neodeskapp/neodesk/neodesk-server/crypto"
	"github.com/neodeskapp/neodesk/neodesk-server/peer"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
)

const (
	pairInitiatorAddr = "10.20.0.5:21117" // node A, the initiator's site
	pairTargetAddr    = "10.30.0.6:21117" // node B, the target's site
)

// pairRouter routes SITEINI1 -> SITETGT1 over two nodes, with node B
// alone as the fallback.
type pairRouter struct {
	pair, single *recordingTickets
}

func (p *pairRouter) singleB() NodeRelay {
	return NodeRelay{Addr: pairTargetAddr, TargetAddr: pairTargetAddr, Tickets: p.single, Via: "node:b"}
}

func (p *pairRouter) NodeRoute(initiatorID string, _ net.IP, targetID string, _ net.IP) (NodeRelay, bool) {
	if initiatorID != "SITEINI1" || targetID != "SITETGT1" {
		return NodeRelay{}, false
	}
	fb := p.singleB()
	return NodeRelay{Addr: pairInitiatorAddr, TargetAddr: pairTargetAddr, Tickets: p.pair, Via: "nodes:a,b", Fallback: &fb}, true
}

func (p *pairRouter) NodeForAddr(addr, _ string, _ net.IP, _ string, _ net.IP) (NodeRelay, bool) {
	if addr == pairTargetAddr {
		return p.singleB(), true
	}
	return NodeRelay{}, false
}

func newPairFixture(t *testing.T, pairErr, singleErr error) (*siteFixture, *pairRouter) {
	t.Helper()
	f := newSiteFixture(t, nil)
	r := &pairRouter{pair: &recordingTickets{err: pairErr}, single: &recordingTickets{err: singleErr}}
	f.srv.SetSiteRouter(r)
	return f, r
}

func unavailable() error { return fmt.Errorf("node gone: %w", relay.ErrTicketsUnavailable) }

// TestASessionBetweenTwoSitesGetsBothNodes: the initiator is told its
// site's node, the target its own, and the pair's store gets the ticket.
func TestASessionBetweenTwoSitesGetsBothNodes(t *testing.T) {
	f, r := newPairFixture(t, nil, nil)
	resp := f.srv.handleRequestRelayTCP(&pb.RequestRelay{Id: "SITETGT1", Uuid: "site-pair"}, f.iniA, peer.ConnTCP)
	if got := resp.GetRelayResponse().GetRelayServer(); got != pairInitiatorAddr {
		t.Fatalf("initiator told %q, want node A %q", got, pairInitiatorAddr)
	}
	if got := readUDPRendezvous(t, f.tgt).GetRequestRelay().GetRelayServer(); got != pairTargetAddr {
		t.Fatalf("target told %q, want node B %q", got, pairTargetAddr)
	}
	if got := r.pair.issuedUUIDs(); len(got) != 1 || len(r.single.issuedUUIDs()) != 0 || len(f.central.issuedUUIDs()) != 0 {
		t.Fatalf("pair %v, single %v, central %v; want the pair's store only", got, r.single.issuedUUIDs(), f.central.issuedUUIDs())
	}
	if via := RelayVia("site-pair"); via != "nodes:a,b" {
		t.Fatalf("relay via %q", via)
	}
}

// TestAPairThatCantTakeTheTicketMovesToOneNode: the two nodes can't take
// the ticket, so both peers get node B alone, which gets the ticket.
func TestAPairThatCantTakeTheTicketMovesToOneNode(t *testing.T) {
	f, r := newPairFixture(t, unavailable(), nil)
	resp := f.srv.handleRequestRelayTCP(&pb.RequestRelay{Id: "SITETGT1", Uuid: "site-pair-fb"}, f.iniA, peer.ConnTCP)
	if got := resp.GetRelayResponse().GetRelayServer(); got != pairTargetAddr {
		t.Fatalf("initiator told %q, want node B %q", got, pairTargetAddr)
	}
	if got := readUDPRendezvous(t, f.tgt).GetRequestRelay().GetRelayServer(); got != pairTargetAddr {
		t.Fatalf("target told %q, want node B %q", got, pairTargetAddr)
	}
	if got := r.single.issuedUUIDs(); len(got) != 1 || len(f.central.issuedUUIDs()) != 0 {
		t.Fatalf("single %v, central %v; want node B's store", got, f.central.issuedUUIDs())
	}
	if via := RelayVia("site-pair-fb"); via != "node:b" {
		t.Fatalf("relay via %q, want node:b", via)
	}
}

// TestAPairAndItsNodeDownMoveToTheCentralRelay: neither the pair nor the
// one node can take the ticket: the central relay gets the session.
func TestAPairAndItsNodeDownMoveToTheCentralRelay(t *testing.T) {
	f, _ := newPairFixture(t, unavailable(), unavailable())
	resp := f.srv.handleRequestRelayTCP(&pb.RequestRelay{Id: "SITETGT1", Uuid: "site-pair-central"}, f.iniA, peer.ConnTCP)
	rr := resp.GetRelayResponse()
	if rr.GetRefuseReason() != "" {
		t.Fatalf("refused: %q", rr.GetRefuseReason())
	}
	if got := rr.GetRelayServer(); got == pairInitiatorAddr || got == pairTargetAddr || got == "" {
		t.Fatalf("initiator told %q, want the central relay", got)
	}
	if got := f.central.issuedUUIDs(); len(got) != 1 {
		t.Fatalf("central %v, want the ticket", got)
	}
}

// TestARelayResponseNamingTheTargetsNodeKeepsThePair: after a punch hole
// the target answers naming node B, which it dials; the initiator is told
// node A and the pair gets the ticket, not node B alone.
func TestARelayResponseNamingTheTargetsNodeKeepsThePair(t *testing.T) {
	f, r := newPairFixture(t, nil, nil)
	f.srv.storePendingUUID("SITETGT1", f.iniA, "site-pair-hint", "SITEINI1")
	f.srv.handleRelayResponseForward(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_RelayResponse{
		RelayResponse: &pb.RelayResponse{
			SocketAddr: cryptopkg.EncodeAddr(f.iniA), Uuid: "site-pair-hint",
			RelayServer: pairTargetAddr, Union: &pb.RelayResponse_Id{Id: "SITETGT1"},
		},
	}}, f.tgtA)
	if got := readUDPRendezvous(t, f.ini).GetRelayResponse().GetRelayServer(); got != pairInitiatorAddr {
		t.Fatalf("initiator told %q, want node A %q", got, pairInitiatorAddr)
	}
	if got := r.pair.issuedUUIDs(); len(got) != 1 || len(r.single.issuedUUIDs()) != 0 {
		t.Fatalf("pair %v, single %v; want the pair's store", got, r.single.issuedUUIDs())
	}

	// The pair can't take it: node B alone, never the central relay
	f2, r2 := newPairFixture(t, unavailable(), nil)
	f2.srv.storePendingUUID("SITETGT1", f2.iniA, "site-pair-hint2", "SITEINI1")
	f2.srv.handleRelayResponseForward(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_RelayResponse{
		RelayResponse: &pb.RelayResponse{
			SocketAddr: cryptopkg.EncodeAddr(f2.iniA), Uuid: "site-pair-hint2",
			RelayServer: pairTargetAddr, Union: &pb.RelayResponse_Id{Id: "SITETGT1"},
		},
	}}, f2.tgtA)
	if got := readUDPRendezvous(t, f2.ini).GetRelayResponse().GetRelayServer(); got != pairTargetAddr {
		t.Fatalf("after the pair failed the initiator was told %q, want node B %q", got, pairTargetAddr)
	}
	if len(r2.single.issuedUUIDs()) != 1 || len(f2.central.issuedUUIDs()) != 0 {
		t.Fatalf("single %v, central %v", r2.single.issuedUUIDs(), f2.central.issuedUUIDs())
	}
}
