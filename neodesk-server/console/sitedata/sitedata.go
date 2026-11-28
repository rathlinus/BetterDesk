// Package sitedata is the console's access to sites and relay nodes: the
// server's database, the sites service that makes every write (the one of
// the running relay node hub, so its cache and its revoke hook stay
// current), what the hub knows about connected nodes, which sites an
// account may see, the site of a device and the relay a session took.
//
// Reads work from the database when relay nodes are off; only what needs
// the hub (online state, enrollment strings) is missing then.
package sitedata

import (
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/neodeskapp/neodesk/neodesk-server/auth"
	"github.com/neodeskapp/neodesk/neodesk-server/db"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/central"
	"github.com/neodeskapp/neodesk/neodesk-server/sites"
)

// Service is the console's view of sites and relay nodes.
type Service struct {
	db   db.Database
	glue func() *central.Glue

	mu    sync.Mutex
	local *sites.Service
}

// New returns the service on the server's database; nil for none, and
// every method of a nil Service reports nothing.
func New(database db.Database) *Service {
	if database == nil {
		return nil
	}
	return &Service{db: database, glue: central.Default}
}

// DB is the server's database.
func (s *Service) DB() db.Database { return s.db }

// Glue is the running relay node glue, nil when relay nodes are off.
func (s *Service) Glue() *central.Glue {
	if s == nil || s.glue == nil {
		return nil
	}
	return s.glue()
}

// Sites is the service every write goes through: the hub's while relay
// nodes are on, else one of the console's own.
func (s *Service) Sites() *sites.Service {
	if g := s.Glue(); g != nil && g.Sites != nil {
		return g.Sites
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.local == nil {
		s.local = sites.New(s.db)
	}
	return s.local
}

// Live is what the hub knows about a node now.
type Live struct {
	Online bool
	Active int
	Up     int64
	Down   int64
	// Forwarded is how many devices reach the server through the node
	// now (NODE_FORWARD)
	Forwarded int
}

// Live returns the node's state at the hub; all zero while relay nodes
// are off or the node is not connected.
func (s *Service) Live(nodeID string) Live {
	g := s.Glue()
	if g == nil || g.Hub == nil || !g.Hub.Online(nodeID) {
		return Live{}
	}
	up, down := g.Hub.Traffic(nodeID)
	return Live{Online: true, Active: g.Hub.ActiveSessions(nodeID), Up: up, Down: down, Forwarded: g.ForwardedDevices(nodeID)}
}

// Scope is the organizations whose sites an account may see.
type Scope struct {
	// All is set for the server-level roles, which see every site.
	All bool
	// Orgs are the organizations the account belongs to; "" stands for
	// the sites of no organization, which an account in no organization
	// sees.
	Orgs map[string]bool
}

// Has says the account may see the sites of org.
func (sc Scope) Has(org string) bool { return sc.All || sc.Orgs[org] }

// ScopeFor returns the scope of an account: every site for the
// server-level roles, else the sites of the organizations it is linked
// to, else the sites of no organization.
func (s *Service) ScopeFor(userID int64, role string) (Scope, error) {
	if auth.IsServerLevel(role) {
		return Scope{All: true}, nil
	}
	orgs, err := s.db.ListUserOrganizations(userID)
	if err != nil {
		return Scope{}, err
	}
	out := Scope{Orgs: map[string]bool{}}
	for _, o := range orgs {
		if o != nil {
			out.Orgs[o.ID] = true
		}
	}
	if len(out.Orgs) == 0 {
		out.Orgs[""] = true
	}
	return out, nil
}

// Org is an organization an account may make sites for.
type Org struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Orgs lists the organizations of a scope by name; "" (no organization)
// is not in it.
func (s *Service) Orgs(sc Scope) ([]Org, error) {
	all, err := s.db.ListOrganizations()
	if err != nil {
		return nil, err
	}
	out := []Org{}
	for _, o := range all {
		if o != nil && o.ID != "" && sc.Has(o.ID) {
			out = append(out, Org{ID: o.ID, Name: o.Name})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out, nil
}

// SiteRef names a site in a device or folder answer.
type SiteRef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// DeviceSite returns the site of a device that registered from ip (the
// device answer's "ip": an address, with or without a port), nil for
// none.
func (s *Service) DeviceSite(deviceID, ip string) *SiteRef {
	if s == nil || deviceID == "" {
		return nil
	}
	site := s.Sites().DeviceSite(deviceID, ParseIP(ip))
	if site == nil {
		return nil
	}
	return &SiteRef{ID: site.ID, Name: site.Name}
}

// Finder returns DeviceSite while the server has a site, nil while it has
// none (or no database), so that a device answer gets a site member only
// on a server that uses sites.
func (s *Service) Finder() func(deviceID, ip string) *SiteRef {
	if s == nil {
		return nil
	}
	list, err := s.db.ListSites("", true)
	if err != nil || len(list) == 0 {
		return nil
	}
	return s.DeviceSite
}

// Placement is where a device's site comes from.
type Placement struct {
	// Site is the site the device is at, nil for none.
	Site *SiteRef `json:"site"`
	// Pin is the site the device is pinned to, nil for none. A pin to a
	// site of another organization is listed but not used.
	Pin *SiteRef `json:"pin"`
	// Source is "pin" (the device's own pin), "folder" (its folder's
	// pin), "network" (its address) or "" for no site.
	Source string `json:"source"`
	// ViaNode is the relay node the device reaches the server through
	// (a site without internet access), nil when it reaches it directly.
	ViaNode *SiteRef `json:"via_node"`
}

// PlacementOf says where a device is and why. folderID is the device's
// folder, 0 for none.
func (s *Service) PlacementOf(deviceID, ip string, folderID int64) Placement {
	out := Placement{Site: s.DeviceSite(deviceID, ip), ViaNode: s.viaNode(deviceID)}
	if id, err := s.db.GetSitePin(db.SitePinDevice, deviceID); err == nil && id != "" {
		if site, err := s.db.GetSite(id); err == nil && site != nil {
			out.Pin = &SiteRef{ID: site.ID, Name: site.Name}
		}
	}
	if out.Site == nil {
		return out
	}
	switch {
	case out.Pin != nil && out.Pin.ID == out.Site.ID:
		out.Source = "pin"
	case folderID > 0 && s.folderPin(folderID) == out.Site.ID:
		out.Source = "folder"
	default:
		out.Source = "network"
	}
	return out
}

// viaNode is the relay node the device comes through now, nil for none.
func (s *Service) viaNode(deviceID string) *SiteRef {
	g := s.Glue()
	if g == nil || g.Signal == nil {
		return nil
	}
	id := g.Signal.PeerForwardNode(deviceID)
	if id == "" {
		return nil
	}
	name := id
	if n, err := s.db.GetRelayNode(id); err == nil && n != nil && n.Name != "" {
		name = n.Name
	}
	return &SiteRef{ID: id, Name: name}
}

func (s *Service) folderPin(folderID int64) string {
	id, err := s.db.GetSitePin(db.SitePinFolder, strconv.FormatInt(folderID, 10))
	if err != nil {
		return ""
	}
	return id
}

// FolderPins maps folder ids (decimal) to the site each is pinned to.
func (s *Service) FolderPins() map[string]string {
	out := map[string]string{}
	if s == nil {
		return out
	}
	pins, err := s.db.ListSitePins()
	if err != nil {
		return out
	}
	for _, p := range pins {
		if p.Kind == db.SitePinFolder {
			out[p.Ref] = p.SiteID
		}
	}
	return out
}

// ParseIP reads an address as devices report it: "1.2.3.4",
// "1.2.3.4:5678", "[::1]:5678", "::ffff:1.2.3.4". nil for anything else.
func ParseIP(text string) net.IP {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	if ip := net.ParseIP(text); ip != nil {
		return ip
	}
	if host, _, err := net.SplitHostPort(text); err == nil {
		return net.ParseIP(strings.Trim(host, "[]"))
	}
	return net.ParseIP(strings.Trim(text, "[]"))
}

// Relay is how a session was relayed, for the console.
type Relay struct {
	// Kind is "direct", "central", "lan", "node" (one relay node), "nodes"
	// (a node at each end), or "" when the server did not record it.
	Kind string `json:"kind"`
	// Nodes names the relay nodes of "node" and "nodes", in order.
	Nodes []SiteRef `json:"nodes,omitempty"`
}

// NodeNames maps node ids to names, for RelayOf.
type NodeNames map[string]string

// NodeNames reads the names of every relay node, revoked ones included.
func (s *Service) NodeNames() NodeNames {
	out := NodeNames{}
	if s == nil {
		return out
	}
	nodes, err := s.db.ListRelayNodes("")
	if err != nil {
		return out
	}
	for _, n := range nodes {
		out[n.ID] = n.Name
	}
	return out
}

// RelayOf reads a peer_connection_sessions.relay_via value: "direct",
// "central", "lan", "node:<id>" or "nodes:<a>,<b>". A node the names
// don't know keeps its id as its name.
func RelayOf(via string, names NodeNames) Relay {
	via = strings.TrimSpace(via)
	switch {
	case via == "direct" || via == "central" || via == "lan":
		return Relay{Kind: via}
	case strings.HasPrefix(via, "node:"):
		return Relay{Kind: "node", Nodes: refs([]string{strings.TrimPrefix(via, "node:")}, names)}
	case strings.HasPrefix(via, "nodes:"):
		return Relay{Kind: "nodes", Nodes: refs(strings.Split(strings.TrimPrefix(via, "nodes:"), ","), names)}
	}
	return Relay{}
}

func refs(ids []string, names NodeNames) []SiteRef {
	out := make([]SiteRef, 0, len(ids))
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		name := names[id]
		if name == "" {
			name = id
		}
		out = append(out, SiteRef{ID: id, Name: name})
	}
	return out
}
