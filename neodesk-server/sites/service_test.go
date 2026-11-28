package sites

import (
	"errors"
	"net"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/db"
)

// testStore is a SQLite database whose device organizations and folders
// come from maps.
type testStore struct {
	db.Database
	mu      sync.Mutex
	orgs    map[string]string
	folders map[string]int64
}

func (t *testStore) GetDeviceOrgID(id string) (string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.orgs[id], nil
}

func (t *testStore) ListPanelDeviceFolderAssignments() (map[string]int64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make(map[string]int64, len(t.folders))
	for k, v := range t.folders {
		out[k] = v
	}
	return out, nil
}

type testLiveness struct {
	mu       sync.Mutex
	online   map[string]bool
	sessions map[string]int
}

func (l *testLiveness) Online(id string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.online[id]
}

func (l *testLiveness) ActiveSessions(id string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sessions[id]
}

type fixture struct {
	t     *testing.T
	svc   *Service
	store *testStore
	live  *testLiveness
	clock time.Time
}

// newFixture gives a Service on a new SQLite database. Its clock moves a
// minute on every read, so sites are created in order and the device
// caches never hold.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	sq, err := db.OpenSQLite(filepath.Join(t.TempDir(), "sites.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sq.Close() })
	if err := sq.Migrate(); err != nil {
		t.Fatal(err)
	}
	f := &fixture{
		t:     t,
		store: &testStore{Database: sq, orgs: map[string]string{}, folders: map[string]int64{}},
		live:  &testLiveness{online: map[string]bool{}, sessions: map[string]int{}},
		clock: time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC),
	}
	f.svc = New(f.store)
	f.svc.now = func() time.Time {
		f.clock = f.clock.Add(time.Minute)
		return f.clock
	}
	f.svc.SetLiveness(f.live)
	return f
}

type netSpec struct{ cidr, kind string }

func (f *fixture) site(org, name, vpn string, nets ...netSpec) *db.Site {
	f.t.Helper()
	s, err := f.svc.CreateSite(org, name, vpn)
	if err != nil {
		f.t.Fatal(err)
	}
	var list []db.SiteNetwork
	for _, n := range nets {
		list = append(list, db.SiteNetwork{CIDR: n.cidr, Kind: n.kind})
	}
	if _, err := f.svc.ReplaceNetworks(s.ID, list); err != nil {
		f.t.Fatal(err)
	}
	return s
}

// node stores an online node at the site.
func (f *fixture) node(siteID, lan, public string) *db.RelayNode {
	f.t.Helper()
	n := &db.RelayNode{SiteID: siteID, PublicKey: "key-" + siteID + lan + public + f.clock.String(), LANAddr: lan, PublicAddr: public}
	f.clock = f.clock.Add(time.Second)
	if err := f.store.CreateRelayNode(n); err != nil {
		f.t.Fatal(err)
	}
	f.svc.Invalidate()
	f.live.mu.Lock()
	f.live.online[n.ID] = true
	f.live.mu.Unlock()
	return n
}

func (f *fixture) device(id, org string) {
	f.store.mu.Lock()
	f.store.orgs[id] = org
	f.store.mu.Unlock()
}

func siteID(s *db.Site) string {
	if s == nil {
		return "<none>"
	}
	return s.Name
}

var (
	private = db.SiteNetworkPrivate
	public  = db.SiteNetworkPublic
)

func TestSiteResolutionPinBeatsFolderBeatsAddress(t *testing.T) {
	f := newFixture(t)
	byPin := f.site("org", "pinned", "")
	byFolder := f.site("org", "folder", "")
	f.site("org", "address", "", netSpec{"10.0.0.0/8", private})
	f.device("DEV1", "org")
	f.store.folders["DEV1"] = 5
	if err := f.svc.SetPin(db.SitePinDevice, "DEV1", byPin.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.svc.SetPin(db.SitePinFolder, "5", byFolder.ID); err != nil {
		t.Fatal(err)
	}
	addr := net.ParseIP("10.1.2.3")

	if got := f.svc.DeviceSite("DEV1", addr); siteID(got) != "pinned" {
		t.Errorf("with device and folder pin: %s; want the device pin", siteID(got))
	}
	if err := f.svc.SetPin(db.SitePinDevice, "DEV1", ""); err != nil {
		t.Fatal(err)
	}
	if got := f.svc.DeviceSite("DEV1", addr); siteID(got) != "folder" {
		t.Errorf("with folder pin: %s; want the folder pin", siteID(got))
	}
	if err := f.svc.SetPin(db.SitePinFolder, "5", ""); err != nil {
		t.Fatal(err)
	}
	if got := f.svc.DeviceSite("DEV1", addr); siteID(got) != "address" {
		t.Errorf("without pins: %s; want the site of the address", siteID(got))
	}
	if got := f.svc.DeviceSite("DEV1", net.ParseIP("192.168.1.1")); got != nil {
		t.Errorf("address in no network: %s; want none", siteID(got))
	}
}

func TestSiteResolutionPrivateAddressOnlyInPrivateNetworks(t *testing.T) {
	f := newFixture(t)
	f.site("org", "lan", "", netSpec{"10.0.0.0/8", private})
	pub := f.site("org", "wan", "", netSpec{"198.51.100.0/24", public})
	// A public network over private addresses, more specific than the
	// private one; the console does not let one in, the database could
	// have one.
	if err := f.store.ReplaceSiteNetworks(pub.ID, []db.SiteNetwork{
		{CIDR: "198.51.100.0/24", Kind: public},
		{CIDR: "10.1.0.0/16", Kind: public},
	}); err != nil {
		t.Fatal(err)
	}
	f.svc.Invalidate()
	f.device("DEV1", "org")
	if got := f.svc.DeviceSite("DEV1", net.ParseIP("10.1.2.3")); siteID(got) != "lan" {
		t.Errorf("private address: %s; want the site of the private network", siteID(got))
	}
	if got := f.svc.DeviceSite("DEV1", net.ParseIP("198.51.100.9")); siteID(got) != "wan" {
		t.Errorf("public address: %s; want the site of the public network", siteID(got))
	}
}

func TestSiteResolutionIgnoresOtherOrgSites(t *testing.T) {
	f := newFixture(t)
	other := f.site("other", "other org", "", netSpec{"10.1.0.0/16", private})
	f.site("org", "own", "", netSpec{"10.0.0.0/8", private})
	f.site("", "no org", "", netSpec{"10.1.2.0/24", private})
	f.device("DEV1", "org")
	f.device("LONE", "")
	// a pin the console refuses, written straight to the database
	if err := f.store.SetSitePin(db.SitePinDevice, "DEV1", other.ID); err != nil {
		t.Fatal(err)
	}
	f.svc.Invalidate()
	if got := f.svc.DeviceSite("DEV1", net.ParseIP("10.1.2.3")); siteID(got) != "own" {
		t.Errorf("device of org: %s; want its own org's site", siteID(got))
	}
	if got := f.svc.DeviceSite("LONE", net.ParseIP("10.1.2.3")); siteID(got) != "no org" {
		t.Errorf("device without org: %s; want the site without org", siteID(got))
	}
	if err := f.svc.SetPin(db.SitePinDevice, "DEV1", other.ID); !errors.Is(err, ErrOtherOrg) {
		t.Errorf("pin to another org's site: %v; want ErrOtherOrg", err)
	}
}

func TestSiteResolutionMostSpecificNetworkThenOldestSite(t *testing.T) {
	f := newFixture(t)
	f.site("org", "wide", "", netSpec{"10.0.0.0/8", private})
	f.site("org", "narrow old", "", netSpec{"10.1.0.0/16", private})
	f.site("org", "narrow new", "", netSpec{"10.1.0.0/16", private})
	f.device("DEV1", "org")
	if got := f.svc.DeviceSite("DEV1", net.ParseIP("10.1.2.3")); siteID(got) != "narrow old" {
		t.Errorf("10.1.2.3: %s; want the most specific network of the oldest site", siteID(got))
	}
	if got := f.svc.DeviceSite("DEV1", net.ParseIP("10.2.0.1")); siteID(got) != "wide" {
		t.Errorf("10.2.0.1: %s; want the only network holding it", siteID(got))
	}
}

func TestSiteRouteSameSiteAddressPerPeer(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private}, netSpec{"198.51.100.0/24", public})
	n := f.node(s.ID, "10.0.0.5:21117", "198.51.100.5:21117")
	f.device("LAN", "org")
	f.device("NAT", "org")
	f.device("AWAY", "org")
	if err := f.svc.SetPin(db.SitePinDevice, "AWAY", s.ID); err != nil {
		t.Fatal(err)
	}

	// Behind the site's NAT the central server sees the site's public
	// address, but the peer is inside and reaches the node's LAN address
	r := f.svc.Route("LAN", net.ParseIP("10.0.0.10"), "NAT", net.ParseIP("198.51.100.20"))
	if r.Kind != Same || r.A == nil || r.A.ID != n.ID {
		t.Fatalf("route %+v; want Same through the site's node", r)
	}
	if r.InitiatorAddr != "10.0.0.5:21117" || r.TargetAddr != "10.0.0.5:21117" {
		t.Errorf("addresses %q, %q; want the LAN address for both peers inside the site", r.InitiatorAddr, r.TargetAddr)
	}

	// A peer pinned to the site but away from it gets the public address
	r = f.svc.Route("LAN", net.ParseIP("10.0.0.10"), "AWAY", net.ParseIP("203.0.113.20"))
	if r.InitiatorAddr != "10.0.0.5:21117" || r.TargetAddr != "198.51.100.5:21117" {
		t.Errorf("addresses %q, %q; want the LAN address inside, the public one for the peer away", r.InitiatorAddr, r.TargetAddr)
	}
}

func TestSiteRouteSameSiteLeastLoaded(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private})
	var ids []string
	for i := 0; i < 3; i++ {
		ids = append(ids, f.node(s.ID, "10.0.0.5:21117", "").ID)
	}
	sort.Strings(ids)
	// the node with the lowest id is the busiest; the other two tie
	f.live.sessions[ids[0]] = 5
	f.live.sessions[ids[1]] = 1
	f.live.sessions[ids[2]] = 1
	f.device("A", "org")
	f.device("B", "org")
	r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11"))
	if r.Kind != Same || r.A.ID != ids[1] {
		t.Errorf("route through %v; want %s, the lower id of the least loaded nodes", r.A, ids[1])
	}
}

func TestSiteRouteSameSiteSkipsNodeWithoutAddress(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private}, netSpec{"198.51.100.0/24", public})
	lanOnly := f.node(s.ID, "10.0.0.5:21117", "")
	f.device("LAN", "org")
	f.device("AWAY", "org")
	if err := f.svc.SetPin(db.SitePinDevice, "AWAY", s.ID); err != nil {
		t.Fatal(err)
	}
	if r := f.svc.Route("LAN", net.ParseIP("10.0.0.10"), "AWAY", net.ParseIP("203.0.113.20")); r.Kind != None {
		t.Errorf("only node has no public address for the peer away: %+v; want None", r)
	}
	both := f.node(s.ID, "10.0.0.6:21117", "198.51.100.6:21117")
	f.live.sessions[both.ID] = 10 // busier, but the only one with both addresses
	r := f.svc.Route("LAN", net.ParseIP("10.0.0.10"), "AWAY", net.ParseIP("203.0.113.20"))
	if r.Kind != Same || r.A.ID != both.ID {
		t.Errorf("route %+v; want the node with both addresses, not %s", r, lanOnly.ID)
	}
}

func TestSiteRouteOfflineNodeIsNone(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private})
	n := f.node(s.ID, "10.0.0.5:21117", "")
	f.device("A", "org")
	f.device("B", "org")
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != Same {
		t.Fatalf("online node: %+v; want Same", r)
	}
	f.live.online[n.ID] = false
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != None {
		t.Errorf("offline node: %+v; want None", r)
	}
}

func TestSiteRouteRevokedNodeIsNone(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private})
	n := f.node(s.ID, "10.0.0.5:21117", "")
	f.device("A", "org")
	f.device("B", "org")
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != Same {
		t.Fatalf("before revocation: %+v; want Same", r)
	}
	var hooked []string
	f.svc.SetRevokeHook(func(ids []string) { hooked = append(hooked, ids...) })
	if err := f.svc.RevokeNode(n.ID); err != nil {
		t.Fatal(err)
	}
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != None {
		t.Errorf("revoked node, still online: %+v; want None", r)
	}
	if strings.Join(hooked, ",") != n.ID {
		t.Errorf("revoke hook got %v; want %s", hooked, n.ID)
	}
}

func TestSiteRouteDifferentOrgsIsNone(t *testing.T) {
	f := newFixture(t)
	s1 := f.site("org1", "one", "", netSpec{"10.0.0.0/8", private})
	s2 := f.site("org2", "two", "", netSpec{"10.0.0.0/8", private})
	f.node(s1.ID, "10.0.0.5:21117", "203.0.113.5:21117")
	f.node(s2.ID, "10.0.0.6:21117", "203.0.113.6:21117")
	f.device("A", "org1")
	f.device("B", "org2")
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != None {
		t.Errorf("peers of different orgs: %+v; want None", r)
	}
}

func TestSiteRoutePairPublicAndVPN(t *testing.T) {
	f := newFixture(t)
	a := f.site("org", "berlin", "", netSpec{"10.1.0.0/16", private})
	b := f.site("org", "hamburg", "", netSpec{"10.2.0.0/16", private})
	na := f.node(a.ID, "10.1.0.5:21117", "203.0.113.1:21117")
	nb := f.node(b.ID, "10.2.0.5:21117", "203.0.113.2:21117")
	f.device("A", "org")
	f.device("B", "org")
	route := func() NodeRoute {
		return f.svc.Route("A", net.ParseIP("10.1.0.10"), "B", net.ParseIP("10.2.0.10"))
	}
	r := route()
	if r.Kind != Pair || r.A.ID != na.ID || r.B.ID != nb.ID {
		t.Fatalf("route %+v; want Pair from berlin's node to hamburg's", r)
	}
	if r.Dial != "203.0.113.2:21117" || r.InitiatorAddr != "10.1.0.5:21117" || r.TargetAddr != "10.2.0.5:21117" {
		t.Errorf("without VPN group: dial %q, peers %q %q; want B's public address and each node's LAN address", r.Dial, r.InitiatorAddr, r.TargetAddr)
	}

	vpn := "corp"
	if _, err := f.svc.UpdateSite(a.ID, nil, &vpn); err != nil {
		t.Fatal(err)
	}
	if r := route(); r.Kind != Pair || r.Dial != "203.0.113.2:21117" {
		t.Errorf("VPN group on one site only: %+v; want the public address", r)
	}
	if _, err := f.svc.UpdateSite(b.ID, nil, &vpn); err != nil {
		t.Fatal(err)
	}
	if r := route(); r.Kind != Pair || r.Dial != "10.2.0.5:21117" {
		t.Errorf("same VPN group: %+v; want B's LAN address", r)
	}
}

// TestSiteRoutePairUnreachableFallsBack: when the probes say neither
// node reaches the other, one node both peers reach relays, else none.
func TestSiteRoutePairUnreachableFallsBack(t *testing.T) {
	f := newFixture(t)
	a := f.site("org", "berlin", "", netSpec{"10.1.0.0/16", private}, netSpec{"198.51.100.0/25", public})
	b := f.site("org", "hamburg", "", netSpec{"10.2.0.0/16", private}, netSpec{"198.51.100.128/25", public})
	na := f.node(a.ID, "10.1.0.5:21117", "203.0.113.1:21117")
	nb := f.node(b.ID, "10.2.0.5:21117", "203.0.113.2:21117")
	f.live.sessions[na.ID] = 3
	f.live.sessions[nb.ID] = 1
	f.device("A", "org")
	f.device("B", "org")
	for _, p := range [][2]string{{na.ID, nb.ID}, {nb.ID, na.ID}} {
		if err := f.svc.RecordReachability(db.SiteReachability{FromNode: p[0], ToNode: p[1], Via: "public", OK: false}); err != nil {
			t.Fatal(err)
		}
	}

	r := f.svc.Route("A", net.ParseIP("198.51.100.10"), "B", net.ParseIP("198.51.100.200"))
	if r.Kind != Same || r.A.ID != nb.ID || r.InitiatorAddr != "203.0.113.2:21117" || r.TargetAddr != "10.2.0.5:21117" {
		t.Errorf("peers behind their sites' NAT, A can't reach B: %+v; want the less loaded node, public for A and LAN for B inside its site", r)
	}

	r = f.svc.Route("A", net.ParseIP("198.51.100.10"), "B", net.ParseIP("10.2.0.10"))
	if r.Kind != Same || r.A.ID != nb.ID || r.InitiatorAddr != "203.0.113.2:21117" || r.TargetAddr != "10.2.0.5:21117" {
		t.Errorf("public initiator, private target: %+v; want the target's node, public for A and LAN for B", r)
	}

	if r := f.svc.Route("A", net.ParseIP("10.1.0.10"), "B", net.ParseIP("10.2.0.10")); r.Kind != None {
		t.Errorf("private peers, A can't reach B: %+v; want None", r)
	}

	if err := f.svc.RecordReachability(db.SiteReachability{FromNode: na.ID, ToNode: nb.ID, Via: "public", OK: true}); err != nil {
		t.Fatal(err)
	}
	if r := f.svc.Route("A", net.ParseIP("10.1.0.10"), "B", net.ParseIP("10.2.0.10")); r.Kind != Pair || r.Reverse {
		t.Errorf("after a good probe: %+v; want Pair, A dialing B", r)
	}
}

// TestSiteRoutePairOneWayDialsTheWayThatWorks: A can't reach B but B
// reaches A, so B dials A's leg listener; the peers still dial their own
// site's node.
func TestSiteRoutePairOneWayDialsTheWayThatWorks(t *testing.T) {
	f := newFixture(t)
	a := f.site("org", "berlin", "", netSpec{"10.1.0.0/16", private})
	b := f.site("org", "hamburg", "", netSpec{"10.2.0.0/16", private})
	na := f.node(a.ID, "10.1.0.5:21117", "203.0.113.1:21117")
	nb := f.node(b.ID, "10.2.0.5:21117", "203.0.113.2:21117")
	f.device("A", "org")
	f.device("B", "org")
	if err := f.svc.RecordReachability(db.SiteReachability{FromNode: na.ID, ToNode: nb.ID, Via: "public", OK: false}); err != nil {
		t.Fatal(err)
	}
	r := f.svc.Route("A", net.ParseIP("10.1.0.10"), "B", net.ParseIP("10.2.0.10"))
	if r.Kind != Pair || !r.Reverse || r.A.ID != na.ID || r.B.ID != nb.ID {
		t.Fatalf("route %+v; want Pair with B dialing A", r)
	}
	if r.Dial != "203.0.113.1:21117" || r.DialVia != "public" || r.InitiatorAddr != "10.1.0.5:21117" || r.TargetAddr != "10.2.0.5:21117" {
		t.Errorf("dial %q via %q, peers %q %q; want A's public address, each peer its own node", r.Dial, r.DialVia, r.InitiatorAddr, r.TargetAddr)
	}
}

type legLiveness struct {
	*testLiveness
	legs map[string][2]string
}

func (l legLiveness) LegAddrs(id string) (string, string) { return l.legs[id][0], l.legs[id][1] }

// TestSiteRoutePairDialsLegAddresses: with the hub's leg addresses known,
// the dial goes to B's leg listener, not to its relay; a node without a
// leg address of the needed kind is not paired, and the one-node route
// stands in. A pair carries that route as its fallback.
func TestSiteRoutePairDialsLegAddresses(t *testing.T) {
	f := newFixture(t)
	vpn := "corp"
	a := f.site("org", "berlin", vpn, netSpec{"10.1.0.0/16", private}, netSpec{"198.51.100.0/25", public})
	b := f.site("org", "hamburg", vpn, netSpec{"10.2.0.0/16", private}, netSpec{"198.51.100.128/25", public})
	na := f.node(a.ID, "10.1.0.5:21117", "203.0.113.1:21117")
	nb := f.node(b.ID, "10.2.0.5:21117", "203.0.113.2:21117")
	f.device("A", "org")
	f.device("B", "org")
	legs := legLiveness{testLiveness: f.live, legs: map[string][2]string{
		na.ID: {"10.1.0.5:21125", "203.0.113.1:21125"},
		nb.ID: {"10.2.0.5:21125", ""},
	}}
	f.svc.SetLiveness(legs)
	r := f.svc.Route("A", net.ParseIP("198.51.100.10"), "B", net.ParseIP("198.51.100.200"))
	if r.Kind != Pair || r.Dial != "10.2.0.5:21125" || r.DialVia != "private" || r.Reverse {
		t.Fatalf("same VPN group, B without a public leg address: %+v; want A dialing B's LAN leg address", r)
	}
	if r.Fallback == nil || r.Fallback.Kind != Same || r.Fallback.InitiatorAddr == "" || r.Fallback.TargetAddr == "" {
		t.Fatalf("fallback %+v; want the one node both public peers reach", r.Fallback)
	}

	none := ""
	if _, err := f.svc.UpdateSite(b.ID, nil, &none); err != nil {
		t.Fatal(err)
	}
	r = f.svc.Route("A", net.ParseIP("198.51.100.10"), "B", net.ParseIP("198.51.100.200"))
	if r.Kind != Pair || !r.Reverse || r.Dial != "203.0.113.1:21125" {
		t.Fatalf("no VPN, B has no public leg address: %+v; want B dialing A's public leg address", r)
	}

	legs.legs[na.ID] = [2]string{"10.1.0.5:21125", ""}
	r = f.svc.Route("A", net.ParseIP("198.51.100.10"), "B", net.ParseIP("198.51.100.200"))
	if r.Kind != Same {
		t.Fatalf("no public leg address on either node: %+v; want the one-node route", r)
	}
}

func TestSiteRouteNeedsNodesAtBothSites(t *testing.T) {
	f := newFixture(t)
	a := f.site("org", "berlin", "", netSpec{"10.1.0.0/16", private})
	f.site("org", "hamburg", "", netSpec{"10.2.0.0/16", private})
	f.node(a.ID, "10.1.0.5:21117", "203.0.113.1:21117")
	f.device("A", "org")
	f.device("B", "org")
	if r := f.svc.Route("A", net.ParseIP("10.1.0.10"), "B", net.ParseIP("10.2.0.10")); r.Kind != None {
		t.Errorf("node at the initiator's site only: %+v; want None", r)
	}
	if r := f.svc.Route("A", net.ParseIP("10.1.0.10"), "B", net.ParseIP("192.168.0.1")); r.Kind != None {
		t.Errorf("target at no site: %+v; want None", r)
	}
}

func TestSiteValidateNetwork(t *testing.T) {
	for _, c := range []struct {
		cidr, kind, want string
	}{
		{"10.0.0.0/8", private, "10.0.0.0/8"},
		{" 10.1.2.3/16 ", private, "10.1.0.0/16"},
		{"172.16.5.0/24", private, "172.16.5.0/24"},
		{"192.168.0.0/16", private, "192.168.0.0/16"},
		{"100.64.0.0/10", private, "100.64.0.0/10"},
		{"fd12:3456::/32", private, "fd12:3456::/32"},
		{"198.51.100.0/24", public, "198.51.100.0/24"},
		{"2001:db8::/32", public, "2001:db8::/32"},
		{"0.0.0.0/0", public, "0.0.0.0/0"},
		{"10.0.0.0/8", public, ""},
		{"10.0.0.0/7", private, ""},
		{"172.32.0.0/16", private, ""},
		{"100.128.0.0/16", private, ""},
		{"198.51.100.0/24", private, ""},
		{"fd00::/8", public, ""},
		{"10.0.0.0", private, ""},
		{"nonsense", public, ""},
		{"10.0.0.0/8", "lan", ""},
	} {
		got, err := ValidateNetwork(c.cidr, c.kind)
		if c.want == "" {
			if !errors.Is(err, ErrInvalidNetwork) {
				t.Errorf("%q %s: %q %v; want ErrInvalidNetwork", c.cidr, c.kind, got, err)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("%q %s: %q %v; want %q", c.cidr, c.kind, got, err, c.want)
		}
	}
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private})
	if _, err := f.svc.ReplaceNetworks(s.ID, []db.SiteNetwork{{CIDR: "10.1.0.0/16", Kind: private}, {CIDR: "8.8.8.0/24", Kind: private}}); !errors.Is(err, ErrInvalidNetwork) {
		t.Errorf("one bad network: %v", err)
	}
	if _, err := f.svc.ReplaceNetworks(s.ID, []db.SiteNetwork{{CIDR: "10.1.0.0/16", Kind: private}, {CIDR: "10.1.2.0/16", Kind: private}}); !errors.Is(err, ErrInvalidNetwork) {
		t.Errorf("one network twice: %v", err)
	}
	if nets, _ := f.store.ListSiteNetworks(s.ID); len(nets) != 1 || nets[0].CIDR != "10.0.0.0/8" {
		t.Errorf("networks after refused replacements %+v; want them unchanged", nets)
	}
}

func TestSiteNameLimits(t *testing.T) {
	f := newFixture(t)
	for _, name := range []string{"", "   ", strings.Repeat("x", 101)} {
		if _, err := f.svc.CreateSite("org", name, ""); !errors.Is(err, ErrInvalidName) {
			t.Errorf("name %q: %v; want ErrInvalidName", name, err)
		}
	}
	s, err := f.svc.CreateSite("org", "  "+strings.Repeat("ü", 100)+"  ", "")
	if err != nil || s.Name != strings.Repeat("ü", 100) {
		t.Errorf("100 characters: %+v %v; want it trimmed and kept", s, err)
	}
	empty := " "
	if _, err := f.svc.UpdateSite(s.ID, &empty, nil); !errors.Is(err, ErrInvalidName) {
		t.Errorf("rename to blank: %v; want ErrInvalidName", err)
	}
	if err := f.svc.RenameNode("whatever", ""); !errors.Is(err, ErrInvalidName) {
		t.Errorf("blank node name: %v; want ErrInvalidName", err)
	}
}

func TestSiteEnrollmentTokenEnrollsOneNode(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "")
	token, stored, err := f.svc.CreateEnrollmentToken(s.ID, "admin")
	if err != nil {
		t.Fatal(err)
	}
	list, _ := f.store.ListSiteEnrollmentTokens(s.ID)
	if len(list) != 1 || list[0].TokenHash != HashToken(token) || list[0].TokenHash == token || len(list[0].TokenHash) != 64 {
		t.Fatalf("stored tokens %+v; want only the sha256 hex of the token", list)
	}
	if got := stored.ExpiresAt.Sub(stored.CreatedAt); got != 24*time.Hour {
		t.Errorf("token lives %v; want 24h", got)
	}

	n, err := f.svc.ConsumeEnrollmentToken(token, &db.RelayNode{PublicKey: "pk-1", Name: "rack", LANAddr: "10.0.0.5:21117"})
	if err != nil {
		t.Fatal(err)
	}
	if n.SiteID != s.ID || n.ID == "" || n.Name != "rack" {
		t.Errorf("enrolled node %+v; want it at the token's site", n)
	}
	if got, _ := f.store.GetRelayNodeByKey("pk-1"); got == nil || got.ID != n.ID {
		t.Errorf("stored node %+v", got)
	}
	if _, err := f.svc.ConsumeEnrollmentToken(token, &db.RelayNode{PublicKey: "pk-2"}); !errors.Is(err, ErrTokenInvalid) {
		t.Errorf("second use: %v; want ErrTokenInvalid", err)
	}

	token2, _, err := f.svc.CreateEnrollmentToken(s.ID, "admin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.ConsumeEnrollmentToken(token2, &db.RelayNode{PublicKey: "pk-1"}); !errors.Is(err, ErrNodeKeyTaken) {
		t.Errorf("enrolled key: %v; want ErrNodeKeyTaken", err)
	}
	f.clock = f.clock.Add(25 * time.Hour)
	if _, err := f.svc.ConsumeEnrollmentToken(token2, &db.RelayNode{PublicKey: "pk-3"}); !errors.Is(err, ErrTokenInvalid) {
		t.Errorf("token after 25 hours: %v; want ErrTokenInvalid", err)
	}
}

func TestSiteDeleteDropsRoutesAndHooksNodes(t *testing.T) {
	f := newFixture(t)
	s := f.site("org", "office", "", netSpec{"10.0.0.0/8", private})
	n := f.node(s.ID, "10.0.0.5:21117", "")
	f.device("A", "org")
	f.device("B", "org")
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != Same {
		t.Fatalf("before delete: %+v", r)
	}
	var hooked []string
	f.svc.SetRevokeHook(func(ids []string) { hooked = ids })
	if err := f.svc.DeleteSite(s.ID); err != nil {
		t.Fatal(err)
	}
	if r := f.svc.Route("A", net.ParseIP("10.0.0.10"), "B", net.ParseIP("10.0.0.11")); r.Kind != None {
		t.Errorf("after delete: %+v; want None", r)
	}
	if len(hooked) != 1 || hooked[0] != n.ID {
		t.Errorf("revoke hook got %v; want the site's node", hooked)
	}
	if err := f.svc.DeleteSite(s.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("second delete: %v; want ErrNotFound", err)
	}
}

// TestNodeForAddrAnswersOnlyWithThePairsOwnNodes: the relay address a
// target names maps to a node only when that node may relay the pair. Two
// organizations whose nodes share a LAN address, or a node that claims
// the central relay's address, never get another organization's session.
func TestNodeForAddrAnswersOnlyWithThePairsOwnNodes(t *testing.T) {
	f := newFixture(t)
	const shared = "192.168.1.10:21117"
	const central = "203.0.113.1:21117"
	s1 := f.site("org1", "one", "", netSpec{"192.168.0.0/16", private})
	s2 := f.site("org2", "two", "", netSpec{"192.168.0.0/16", private})
	n1 := f.node(s1.ID, shared, central)
	n2 := f.node(s2.ID, shared, "198.51.100.2:21117")
	f.device("A1", "org1")
	f.device("A2", "org1")
	f.device("B1", "org2")
	f.device("B2", "org2")
	f.device("C1", "org3")
	f.device("C2", "org3")
	lan1, lan2 := net.ParseIP("192.168.1.20"), net.ParseIP("192.168.1.21")

	n, ia, ta, ok := f.svc.NodeForAddr("B1", lan1, "B2", lan2, shared)
	if !ok || n.ID != n2.ID || ia != shared || ta != shared {
		t.Fatalf("org2 pair: node %v %q %q %v; want org2's node", n, ia, ta, ok)
	}
	n, _, _, ok = f.svc.NodeForAddr("A1", lan1, "A2", lan2, shared)
	if !ok || n.ID != n1.ID {
		t.Fatalf("org1 pair: node %v %v; want org1's node", n, ok)
	}
	pub1, pub2 := net.ParseIP("192.0.2.10"), net.ParseIP("192.0.2.11")
	if n, _, _, ok := f.svc.NodeForAddr("C1", pub1, "C2", pub2, central); ok {
		t.Fatalf("org3 pair naming the central relay got node %s", n.ID)
	}
	if n, _, _, ok := f.svc.NodeForAddr("B1", lan1, "B2", lan2, central); ok {
		t.Fatalf("org2 pair got org1's node %s by its public address", n.ID)
	}
	if n, _, _, ok := f.svc.NodeForAddr("A1", lan1, "B2", lan2, shared); ok {
		t.Fatalf("pair across organizations got node %s", n.ID)
	}
}
