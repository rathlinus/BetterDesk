package sites

import (
	"fmt"
	"net"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/console/access"
	"github.com/neodeskapp/neodesk/neodesk-server/console/goapi"
	"github.com/neodeskapp/neodesk/neodesk-server/console/kit"
	"github.com/neodeskapp/neodesk/neodesk-server/console/sitedata"
	"github.com/neodeskapp/neodesk/neodesk-server/db"
	sitesvc "github.com/neodeskapp/neodesk/neodesk-server/sites"
)

// siteJSON is a site in the answers.
type siteJSON struct {
	ID        string        `json:"id"`
	Name      string        `json:"name"`
	OrgID     string        `json:"org_id"`
	OrgName   string        `json:"org_name"`
	VPNGroup  string        `json:"vpn_group"`
	CreatedAt time.Time     `json:"created_at"`
	Networks  []networkJSON `json:"networks"`
	Nodes     []nodeJSON    `json:"nodes"`
	// Devices is how many devices the account may see are at the site.
	Devices int `json:"devices"`
}

type networkJSON struct {
	CIDR string `json:"cidr"`
	Kind string `json:"kind"`
}

// nodeJSON is a relay node in the answers.
type nodeJSON struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	SiteID         string     `json:"site_id"`
	Online         bool       `json:"online"`
	Version        string     `json:"version"`
	LastSeen       *time.Time `json:"last_seen"`
	CreatedAt      time.Time  `json:"created_at"`
	LANAddr        string     `json:"lan_addr"`
	PublicAddr     string     `json:"public_addr"`
	ActiveSessions int        `json:"active_sessions"`
	BytesUp        int64      `json:"bytes_up"`
	BytesDown      int64      `json:"bytes_down"`
	// ForwardedDevices is how many devices reach the server through the
	// node now (sites without internet access)
	ForwardedDevices int        `json:"forwarded_devices"`
	Revoked          bool       `json:"revoked"`
	RevokedAt        *time.Time `json:"revoked_at"`
}

func (h *handlers) nodeOf(n db.RelayNode) nodeJSON {
	live := sitedata.Live{}
	if n.RevokedAt == nil {
		live = h.data.Live(n.ID)
	}
	return nodeJSON{
		ID: n.ID, Name: n.Name, SiteID: n.SiteID, Online: live.Online, Version: n.Version,
		LastSeen: n.LastSeen, CreatedAt: n.CreatedAt, LANAddr: n.LANAddr, PublicAddr: n.PublicAddr,
		ActiveSessions: live.Active, BytesUp: live.Up, BytesDown: live.Down, ForwardedDevices: live.Forwarded,
		Revoked: n.RevokedAt != nil, RevokedAt: n.RevokedAt,
	}
}

// listAnswer is the data of GET /api/sites.
type listAnswer struct {
	Sites []siteJSON `json:"sites"`
	// NodesEnabled says the relay node hub runs: enrollment strings can
	// be made and nodes come online.
	NodesEnabled bool `json:"nodes_enabled"`
	// Organizations are the organizations the account may make sites for.
	Organizations []sitedata.Org `json:"organizations"`
	// Unassigned is whether the account may make sites of no
	// organization.
	Unassigned bool `json:"unassigned"`
}

// list answers GET /api/sites: the sites the account may see, by name, with their networks, nodes and how many of the account's devices
// are at each.
func (h *handlers) list(w http.ResponseWriter, r *http.Request) {
	if !h.ready(w, r) {
		return
	}
	sc, ok := h.scope(w, r)
	if !ok {
		return
	}
	store := h.data.DB()
	all, err := store.ListSites("", true)
	if err != nil {
		h.serverError(w, r, "List sites error:", err)
		return
	}
	nets, err := store.ListAllSiteNetworks()
	if err != nil {
		h.serverError(w, r, "List site networks error:", err)
		return
	}
	nodes, err := store.ListRelayNodes("")
	if err != nil {
		h.serverError(w, r, "List relay nodes error:", err)
		return
	}
	orgs, err := h.data.Orgs(sitedata.Scope{All: true})
	if err != nil {
		h.serverError(w, r, "List organizations error:", err)
		return
	}
	orgName := map[string]string{}
	var mine []sitedata.Org
	for _, o := range orgs {
		orgName[o.ID] = o.Name
		if sc.Has(o.ID) {
			mine = append(mine, o)
		}
	}
	if mine == nil {
		mine = []sitedata.Org{}
	}
	counts := h.deviceCounts(r)

	out := listAnswer{Sites: []siteJSON{}, NodesEnabled: h.data.Glue() != nil, Organizations: mine, Unassigned: sc.Has("")}
	for _, s := range all {
		if !sc.Has(s.OrgID) {
			continue
		}
		item := siteJSON{
			ID: s.ID, Name: s.Name, OrgID: s.OrgID, OrgName: orgName[s.OrgID], VPNGroup: s.VPNGroup,
			CreatedAt: s.CreatedAt, Networks: []networkJSON{}, Nodes: []nodeJSON{}, Devices: counts[s.ID],
		}
		for _, n := range nets {
			if n.SiteID == s.ID {
				item.Networks = append(item.Networks, networkJSON{CIDR: n.CIDR, Kind: n.Kind})
			}
		}
		for _, n := range nodes {
			if n.SiteID == s.ID {
				item.Nodes = append(item.Nodes, h.nodeOf(n))
			}
		}
		out.Sites = append(out.Sites, item)
	}
	sort.SliceStable(out.Sites, func(i, j int) bool {
		return strings.ToLower(out.Sites[i].Name) < strings.ToLower(out.Sites[j].Name)
	})
	kit.OK(w, r, out)
}

// deviceCounts counts the devices the account may see by site. A device
// list that can't be read gives no counts.
func (h *handlers) deviceCounts(r *http.Request) map[string]int {
	counts := map[string]int{}
	if h.d.Backend == nil {
		return counts
	}
	devices := h.d.Backend.GetAllDevices(r.Context(), goapi.DeviceFilters{})
	if h.d.DeviceGroups != nil {
		scope, err := h.d.DeviceGroups.DeviceScopeForUser(r.Context(), kit.User(r), devices)
		if err != nil {
			h.log.Error("Device scope error:", err)
			return counts
		}
		devices = access.FilterByScope(devices, scope, func(d *goapi.Object) string { return d.Str("id") })
	}
	for _, d := range devices {
		if site := h.data.DeviceSite(d.Str("id"), d.Str("ip")); site != nil {
			counts[site.ID]++
		}
	}
	return counts
}

// create answers POST /api/sites with {name, vpn_group?, org_id?}. An
// account that sees one organization only makes sites of it when org_id
// is left out.
func (h *handlers) create(w http.ResponseWriter, r *http.Request) {
	if !h.ready(w, r) {
		return
	}
	sc, ok := h.scope(w, r)
	if !ok {
		return
	}
	body := kit.Body(r)
	name, _ := body.Get("name").Str()
	group, _ := body.Get("vpn_group").Str()
	org, given := body.Get("org_id").Str()
	if !given && !sc.All && !sc.Has("") && len(sc.Orgs) == 1 {
		for only := range sc.Orgs {
			org = only
		}
	}
	org = strings.TrimSpace(org)
	if !sc.Has(org) {
		fail(w, r, http.StatusBadRequest, "sites.org_invalid")
		return
	}
	if org != "" {
		if o, err := h.data.DB().GetOrganization(org); err != nil || o == nil {
			fail(w, r, http.StatusBadRequest, "sites.org_invalid")
			return
		}
	}
	site, err := h.data.Sites().CreateSite(org, name, group)
	if err != nil {
		h.writeError(w, r, "Create site error:", err)
		return
	}
	h.audit(r, "site_created", fmt.Sprintf("Created site %s (%s)", site.Name, site.ID))
	kit.OK(w, r, h.siteAnswer(site))
}

// siteAnswer is a site without its networks and nodes, after a write.
func (h *handlers) siteAnswer(s *db.Site) siteJSON {
	out := siteJSON{ID: s.ID, Name: s.Name, OrgID: s.OrgID, VPNGroup: s.VPNGroup, CreatedAt: s.CreatedAt, Networks: []networkJSON{}, Nodes: []nodeJSON{}}
	if s.OrgID != "" {
		if o, err := h.data.DB().GetOrganization(s.OrgID); err == nil && o != nil {
			out.OrgName = o.Name
		}
	}
	return out
}

// update answers PATCH /api/sites/{id} with {name?, vpn_group?}.
func (h *handlers) update(w http.ResponseWriter, r *http.Request) {
	if !h.ready(w, r) {
		return
	}
	sc, ok := h.scope(w, r)
	if !ok {
		return
	}
	site := h.site(w, r, sc, r.PathValue("id"))
	if site == nil {
		return
	}
	body := kit.Body(r)
	var name, group *string
	if v := body.Get("name"); v.Exists() {
		text, isText := v.Str()
		if !isText {
			fail(w, r, http.StatusBadRequest, "sites.name_invalid", "max", sitesvc.MaxNameLen)
			return
		}
		name = &text
	}
	if v := body.Get("vpn_group"); v.Exists() {
		text, _ := v.Str()
		group = &text
	}
	updated, err := h.data.Sites().UpdateSite(site.ID, name, group)
	if err != nil {
		h.writeError(w, r, "Update site error:", err)
		return
	}
	h.audit(r, "site_updated", fmt.Sprintf("Updated site %s (%s)", updated.Name, updated.ID))
	kit.OK(w, r, h.siteAnswer(updated))
}

// remove answers DELETE /api/sites/{id}: the site goes with its networks,
// pins and enrollment tokens, and its nodes are refused from now on.
func (h *handlers) remove(w http.ResponseWriter, r *http.Request) {
	if !h.ready(w, r) {
		return
	}
	sc, ok := h.scope(w, r)
	if !ok {
		return
	}
	site := h.site(w, r, sc, r.PathValue("id"))
	if site == nil {
		return
	}
	if err := h.data.Sites().DeleteSite(site.ID); err != nil {
		h.writeError(w, r, "Delete site error:", err)
		return
	}
	h.audit(r, "site_deleted", fmt.Sprintf("Deleted site %s (%s)", site.Name, site.ID))
	kit.JSON(w, r, http.StatusOK, done{Success: true})
}

// networkProblem is the answer to a network that can't be stored: which
// entry of the list (0-based) and why.
type networkProblem struct {
	Success bool   `json:"success"`
	Error   string `json:"error"`
	Index   int    `json:"index"`
}

// networks answers PUT /api/sites/{id}/networks with
// {networks:[{cidr, kind}]}: the site's networks become the list. One
// entry that can't be stored changes nothing and is named in the answer.
func (h *handlers) networks(w http.ResponseWriter, r *http.Request) {
	if !h.ready(w, r) {
		return
	}
	sc, ok := h.scope(w, r)
	if !ok {
		return
	}
	site := h.site(w, r, sc, r.PathValue("id"))
	if site == nil {
		return
	}
	list, isList := kit.Body(r).Get("networks").Array()
	if !isList {
		fail(w, r, http.StatusBadRequest, "sites.networks_required")
		return
	}
	nets := make([]db.SiteNetwork, 0, len(list))
	seen := map[string]bool{}
	for i, item := range list {
		obj, _ := item.Object()
		cidr, _ := obj.Get("cidr").Str()
		kind, _ := obj.Get("kind").Str()
		key, vars, clean := checkNetwork(cidr, kind)
		if key == "" && seen[clean] {
			key, vars = "sites.network_twice", []any{"cidr", clean}
		}
		if key != "" {
			kit.JSON(w, r, http.StatusBadRequest, networkProblem{Error: kit.T(r, key, kit.Vars(vars...)), Index: i})
			return
		}
		seen[clean] = true
		nets = append(nets, db.SiteNetwork{CIDR: clean, Kind: strings.TrimSpace(kind)})
	}
	stored, err := h.data.Sites().ReplaceNetworks(site.ID, nets)
	if err != nil {
		h.writeError(w, r, "Replace site networks error:", err)
		return
	}
	out := make([]networkJSON, 0, len(stored))
	texts := make([]string, 0, len(stored))
	for _, n := range stored {
		out = append(out, networkJSON{CIDR: n.CIDR, Kind: n.Kind})
		texts = append(texts, n.CIDR+" "+n.Kind)
	}
	h.audit(r, "site_networks_updated", fmt.Sprintf("Networks of site %s (%s): %s", site.Name, site.ID, strings.Join(texts, ", ")))
	kit.OK(w, r, map[string]any{"networks": out})
}

// checkNetwork says what is wrong with a network as a language key and
// its variables ("" when nothing is), and gives its canonical CIDR.
func checkNetwork(cidr, kind string) (key string, vars []any, clean string) {
	cidr, kind = strings.TrimSpace(cidr), strings.TrimSpace(kind)
	if kind != db.SiteNetworkPublic && kind != db.SiteNetworkPrivate {
		return "sites.network_kind_invalid", nil, ""
	}
	if _, _, err := net.ParseCIDR(cidr); err != nil {
		return "sites.network_not_cidr", []any{"cidr", cidr}, ""
	}
	clean, err := sitesvc.ValidateNetwork(cidr, kind)
	if err != nil {
		if kind == db.SiteNetworkPrivate {
			return "sites.network_not_private", []any{"cidr", cidr}, ""
		}
		return "sites.network_is_private", []any{"cidr", cidr}, ""
	}
	return "", nil, clean
}
