package sites

import (
	"net"
	"testing"
)

// forwardFixture: sites A and B with internet, site C without; each has
// one node with a LAN and a public address. The computer CPC sits behind
// node C at 10.3.0.10.
type forwardFixture struct {
	*fixture
	nodeA, nodeB, nodeC string
	cpc                 net.IP
}

func newForwardFixture(t *testing.T) *forwardFixture {
	f := newFixture(t)
	a := f.site("org", "A", "", netSpec{"10.1.0.0/16", private})
	b := f.site("org", "B", "", netSpec{"10.2.0.0/16", private})
	c := f.site("org", "C", "", netSpec{"10.3.0.0/16", private})
	na := f.node(a.ID, "10.1.0.2:21117", "203.0.113.1:21117")
	nb := f.node(b.ID, "10.2.0.2:21117", "203.0.113.2:21117")
	nc := f.node(c.ID, "10.3.0.2:21117", "203.0.113.3:21117")
	for _, d := range []string{"CPC", "CPC2", "PA", "PB", "NET"} {
		f.device(d, "org")
	}
	return &forwardFixture{fixture: f, nodeA: na.ID, nodeB: nb.ID, nodeC: nc.ID, cpc: net.ParseIP("10.3.0.10")}
}

// TestForwardedPeerAtItsNodesSiteUsesThatNode: a peer at site C (on the
// LAN, or forwarded too) and the computer behind node C meet on node C's
// LAN address.
func TestForwardedPeerAtItsNodesSiteUsesThatNode(t *testing.T) {
	f := newForwardFixture(t)
	for name, r := range map[string]NodeRoute{
		"other peer on the LAN":  f.svc.RouteForwarded("PA", net.ParseIP("10.3.0.11"), "", "CPC", f.cpc, f.nodeC),
		"both behind node C":     f.svc.RouteForwarded("CPC2", net.ParseIP("10.3.0.11"), f.nodeC, "CPC", f.cpc, f.nodeC),
		"forwarded is initiator": f.svc.RouteForwarded("CPC", f.cpc, f.nodeC, "PA", net.ParseIP("10.3.0.11"), ""),
		"public address, node C": f.svc.RouteForwarded("CPC", net.ParseIP("198.51.100.4"), f.nodeC, "PA", net.ParseIP("10.3.0.11"), ""),
	} {
		if r.Kind != Same || r.A.ID != f.nodeC || r.InitiatorAddr != "10.3.0.2:21117" || r.TargetAddr != "10.3.0.2:21117" {
			t.Errorf("%s: %+v; want node C on its LAN address for both", name, r)
		}
	}
}

// TestForwardedPeerAndAPeerAtAnotherSitePairTheirNodes: the computer
// behind node C and a peer at site A go over node A and node C; a public
// address on A's side adds node C alone as the fallback.
func TestForwardedPeerAndAPeerAtAnotherSitePairTheirNodes(t *testing.T) {
	f := newForwardFixture(t)
	r := f.svc.RouteForwarded("PA", net.ParseIP("10.1.0.10"), "", "CPC", f.cpc, f.nodeC)
	if r.Kind != Pair || r.A.ID != f.nodeA || r.B.ID != f.nodeC || r.InitiatorAddr != "10.1.0.2:21117" || r.TargetAddr != "10.3.0.2:21117" {
		t.Fatalf("route %+v; want Pair node A (LAN) to node C (LAN)", r)
	}
	if r.Fallback != nil {
		t.Errorf("fallback %+v; a peer on A's LAN can't reach node C", r.Fallback)
	}
	// The computer starts the session
	r = f.svc.RouteForwarded("CPC", f.cpc, f.nodeC, "PB", net.ParseIP("10.2.0.10"), "")
	if r.Kind != Pair || r.A.ID != f.nodeC || r.B.ID != f.nodeB || r.InitiatorAddr != "10.3.0.2:21117" {
		t.Fatalf("route %+v; want Pair node C to node B", r)
	}

	// Site A seen from outside (public network): node C alone is a fallback
	if _, err := f.svc.ReplaceNetworks(f.siteOf(f.nodeA), nil); err != nil {
		t.Fatal(err)
	}
	f.pinDevice("PA", f.siteOf(f.nodeA))
	r = f.svc.RouteForwarded("PA", net.ParseIP("198.51.100.7"), "", "CPC", f.cpc, f.nodeC)
	if r.Kind != Pair || r.InitiatorAddr != "203.0.113.1:21117" || r.Fallback == nil || r.Fallback.A.ID != f.nodeC ||
		r.Fallback.InitiatorAddr != "203.0.113.3:21117" || r.Fallback.TargetAddr != "10.3.0.2:21117" {
		t.Fatalf("route %+v (fallback %+v); want Pair with node C alone as fallback", r, r.Fallback)
	}
}

// TestTwoForwardedPeersAtTwoSitesPairOnlyTheirNodes: computers behind
// node C and node B use exactly those nodes, with no one-node fallback.
func TestTwoForwardedPeersAtTwoSitesPairOnlyTheirNodes(t *testing.T) {
	f := newForwardFixture(t)
	r := f.svc.RouteForwarded("CPC2", net.ParseIP("10.2.0.10"), f.nodeB, "CPC", f.cpc, f.nodeC)
	if r.Kind != Pair || r.A.ID != f.nodeB || r.B.ID != f.nodeC || r.Fallback != nil {
		t.Fatalf("route %+v; want Pair node B to node C without fallback", r)
	}
}

// TestForwardedPeerAndAPeerWithoutSite: a peer at no site reaches node C
// at its public address when its own address is public; with a private
// address (unknown network) there is no route.
func TestForwardedPeerAndAPeerWithoutSite(t *testing.T) {
	f := newForwardFixture(t)
	r := f.svc.RouteForwarded("NET", net.ParseIP("198.51.100.9"), "", "CPC", f.cpc, f.nodeC)
	if r.Kind != Same || r.A.ID != f.nodeC || r.InitiatorAddr != "203.0.113.3:21117" || r.TargetAddr != "10.3.0.2:21117" {
		t.Fatalf("public peer: %+v; want node C, public for it and LAN for the computer", r)
	}
	if r := f.svc.RouteForwarded("NET", net.ParseIP("192.168.77.9"), "", "CPC", f.cpc, f.nodeC); r.Kind != None {
		t.Fatalf("private peer at no site: %+v; want None", r)
	}
}

// TestForwardingNodeMustBeOnlineAndOfTheDevicesOrg: a forwarding node
// that is offline, unknown or at a site of another organization carries
// nothing, even where another node would do.
func TestForwardingNodeMustBeOnlineAndOfTheDevicesOrg(t *testing.T) {
	f := newForwardFixture(t)
	other := f.site("other-org", "X", "", netSpec{"10.9.0.0/16", private})
	nx := f.node(other.ID, "10.9.0.2:21117", "203.0.113.9:21117")
	if r := f.svc.RouteForwarded("PA", net.ParseIP("10.1.0.10"), "", "CPC", f.cpc, nx.ID); r.Kind != None {
		t.Fatalf("node of another organization: %+v; want None", r)
	}
	if r := f.svc.RouteForwarded("PA", net.ParseIP("10.1.0.10"), "", "CPC", f.cpc, "no-such-node"); r.Kind != None {
		t.Fatalf("unknown node: %+v; want None", r)
	}
	f.live.mu.Lock()
	f.live.online[f.nodeC] = false
	f.live.mu.Unlock()
	if r := f.svc.RouteForwarded("PA", net.ParseIP("10.3.0.11"), "", "CPC", f.cpc, f.nodeC); r.Kind != None {
		t.Fatalf("offline node: %+v; want None", r)
	}
}

func (f *forwardFixture) siteOf(nodeID string) string {
	n, err := f.store.GetRelayNode(nodeID)
	if err != nil || n == nil {
		f.t.Fatalf("node %s: %v", nodeID, err)
	}
	return n.SiteID
}

func (f *forwardFixture) pinDevice(id, siteID string) {
	if err := f.svc.SetPin("device", id, siteID); err != nil {
		f.t.Fatal(err)
	}
}
