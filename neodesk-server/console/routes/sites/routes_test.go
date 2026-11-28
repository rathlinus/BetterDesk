package sites_test

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	serverconfig "github.com/neodeskapp/neodesk/neodesk-server/config"
	"github.com/neodeskapp/neodesk/neodesk-server/console/config"
	"github.com/neodeskapp/neodesk/neodesk-server/console/routes/internal/routetest"
	"github.com/neodeskapp/neodesk/neodesk-server/db"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/agent"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/central"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
	"github.com/neodeskapp/neodesk/neodesk-server/signal"
	"google.golang.org/protobuf/proto"
)

// The made-up API server's devices: A on a LAN address, B on a public
// one, C without an address.
const devices = `{"peers":[{"id":"A","hostname":"a","ip":"10.1.2.3"},{"id":"B","hostname":"b","ip":"203.0.113.9:4321"},{"id":"C","hostname":"c"}]}`

// langDir holds the console's language files.
var langDir = filepath.Join("..", "..", "static", "files", "lang")

type world struct {
	*routetest.World
	data *db.SQLiteDB
	api  *routetest.API
}

// newWorld is a console on a fresh server database with the organizations
// North and South; e2e_operator belongs to North and may edit
// organizations (org.edit), so it stands for an organization admin.
func newWorld(t *testing.T, env ...string) *world {
	t.Helper()
	data, err := db.OpenSQLite(filepath.Join(t.TempDir(), "server.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { data.Close() })
	if err := data.Migrate(); err != nil {
		t.Fatal(err)
	}
	for _, o := range []db.Organization{{ID: "org-north", Name: "North", Slug: "north"}, {ID: "org-south", Name: "South", Slug: "south"}} {
		o.CreatedAt = time.Now()
		if err := data.CreateOrganization(&o); err != nil {
			t.Fatal(err)
		}
	}
	if err := data.CreateOrgUser(&db.OrgUser{ID: "ou-1", OrgID: "org-north", ServerUserID: routetest.RoleIDs["operator"], Username: "e2e_operator", Role: db.OrgRoleAdmin, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	api := routetest.NewAPI()
	api.Fallback = func(c routetest.Call) routetest.Reply {
		switch {
		case c.Target == "/api/peers":
			return routetest.Reply{Status: 200, Body: devices}
		case strings.HasPrefix(c.Target, "/api/peers/A/connection-sessions"):
			return routetest.Reply{Status: 200, Body: sessionsBody}
		case strings.HasPrefix(c.Target, "/api/peers/"):
			id := strings.TrimPrefix(c.Target, "/api/peers/")
			switch id {
			case "A":
				return routetest.Reply{Status: 200, Body: `{"id":"A","hostname":"a","ip":"10.1.2.3"}`}
			case "B":
				return routetest.Reply{Status: 200, Body: `{"id":"B","hostname":"b","ip":"203.0.113.9:4321"}`}
			case forwardedID:
				return routetest.Reply{Status: 200, Body: `{"id":"` + forwardedID + `","hostname":"c","ip":"10.1.2.4"}`}
			}
		case strings.HasPrefix(c.Target, "/api/remote-targets"):
			return routetest.Reply{Status: 200, Body: `{"targets":[]}`}
		}
		return routetest.Reply{Status: 404, Body: `{"error":"not found"}`}
	}
	vars := map[string]string{}
	for i := 0; i+1 < len(env); i += 2 {
		vars[env[i]] = env[i+1]
	}
	w := routetest.New(t, routetest.Options{
		Env:    vars,
		API:    api,
		Data:   data,
		Config: func(cfg *config.Config) { cfg.LangDir = langDir },
		Roles:  routetest.Overrides{"operator": {"org.edit": true}},
	})
	central.SetDefault(nil)
	return &world{World: w, data: data, api: api}
}

var sessionsBody = ""

// startHub turns relay nodes on: a control listener on a free port, the
// default glue the console reaches.
func (w *world) startHub(t *testing.T) *central.Glue {
	t.Helper()
	glue, err := central.Start(context.Background(), central.Config{Addr: "127.0.0.1:0", CertDir: t.TempDir(), ServerPK: "server-pk", DB: w.data})
	if err != nil {
		t.Fatal(err)
	}
	central.SetDefault(glue)
	t.Cleanup(func() {
		central.SetDefault(nil)
		glue.Hub.Stop()
	})
	return glue
}

func want(t *testing.T, what string, got routetest.Answer, status int, body string) {
	t.Helper()
	if got.Status != status || got.Body != body {
		t.Errorf("%s:\n got %d %s\nwant %d %s", what, got.Status, got.Body, status, body)
	}
}

func wantStatus(t *testing.T, what string, got routetest.Answer, status int) {
	t.Helper()
	if got.Status != status {
		t.Errorf("%s: got %d %s, want %d", what, got.Status, got.Body, status)
	}
}

type site struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	OrgID    string `json:"org_id"`
	OrgName  string `json:"org_name"`
	VPNGroup string `json:"vpn_group"`
	Networks []struct {
		CIDR string `json:"cidr"`
		Kind string `json:"kind"`
	} `json:"networks"`
	Nodes []struct {
		ID         string     `json:"id"`
		Name       string     `json:"name"`
		Online     bool       `json:"online"`
		Version    string     `json:"version"`
		PublicAddr string     `json:"public_addr"`
		LastSeen   *time.Time `json:"last_seen"`
		Revoked    bool       `json:"revoked"`
	} `json:"nodes"`
	Devices int `json:"devices"`
}

type listData struct {
	Sites         []site `json:"sites"`
	NodesEnabled  bool   `json:"nodes_enabled"`
	Unassigned    bool   `json:"unassigned"`
	Organizations []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"organizations"`
}

func decode[T any](t *testing.T, a routetest.Answer) T {
	t.Helper()
	var out struct {
		Success bool `json:"success"`
		Data    T    `json:"data"`
	}
	if err := json.Unmarshal([]byte(a.Body), &out); err != nil || !out.Success {
		t.Fatalf("answer %d %s: %v", a.Status, a.Body, err)
	}
	return out.Data
}

func list(t *testing.T, a *routetest.Agent) listData {
	t.Helper()
	got := a.Do("GET", "/api/sites", "")
	if got.Status != 200 {
		t.Fatalf("list: %d %s", got.Status, got.Body)
	}
	return decode[listData](t, got)
}

func names(sites []site) string {
	var out []string
	for _, s := range sites {
		out = append(out, s.Name)
	}
	return strings.Join(out, ",")
}

func create(t *testing.T, a *routetest.Agent, body string) site {
	t.Helper()
	got := a.Do("POST", "/api/sites", body)
	if got.Status != 200 {
		t.Fatalf("create %s: %d %s", body, got.Status, got.Body)
	}
	return decode[site](t, got)
}

func TestSitesCreateRenameDelete(t *testing.T) {
	w := newWorld(t)
	admin, viewer := w.As("admin"), w.As("viewer")

	if got := w.SignedOut().Do("GET", "/api/sites", ""); got.Status != 401 {
		t.Errorf("signed out: %d %s", got.Status, got.Body)
	}
	wantStatus(t, "a viewer creates", viewer.Do("POST", "/api/sites", `{"name":"x"}`), 403)

	want(t, "no name", admin.Do("POST", "/api/sites", `{}`), 400, `{"success":false,"error":"Enter a name of 1 to 100 characters."}`)
	want(t, "blank name", admin.Do("POST", "/api/sites", `{"name":"  "}`), 400, `{"success":false,"error":"Enter a name of 1 to 100 characters."}`)
	want(t, "long name", admin.Do("POST", "/api/sites", `{"name":"`+strings.Repeat("x", 101)+`"}`), 400, `{"success":false,"error":"Enter a name of 1 to 100 characters."}`)
	want(t, "unknown organization", admin.Do("POST", "/api/sites", `{"name":"x","org_id":"org-west"}`), 400, `{"success":false,"error":"Pick an organization you belong to."}`)

	create(t, admin, `{"name":"warehouse"}`)
	want(t, "delete the first", admin.Do("DELETE", "/api/sites/"+list(t, admin).Sites[0].ID, ""), 200, `{"success":true}`)
	office := create(t, admin, `{"name":"  Office ","vpn_group":"hq"}`)
	if office.Name != "Office" || office.VPNGroup != "hq" || office.OrgID != "" || office.ID == "" {
		t.Fatalf("created %+v", office)
	}
	north := create(t, admin, `{"name":"Plant","org_id":"org-north"}`)
	if north.OrgID != "org-north" || north.OrgName != "North" {
		t.Fatalf("created %+v", north)
	}

	l := list(t, viewer)
	if names(l.Sites) != "Office" || l.NodesEnabled || !l.Unassigned || len(l.Organizations) != 0 {
		t.Errorf("a viewer in no organization sees %+v", l)
	}
	create(t, admin, `{"name":"apartment"}`)
	if got := names(list(t, admin).Sites); got != "apartment,Office,Plant" {
		t.Errorf("admin sees %q", got)
	}

	// Renaming
	want(t, "rename to nothing", admin.Do("PATCH", "/api/sites/"+office.ID, `{"name":""}`), 400, `{"success":false,"error":"Enter a name of 1 to 100 characters."}`)
	want(t, "rename to a number", admin.Do("PATCH", "/api/sites/"+office.ID, `{"name":5}`), 400, `{"success":false,"error":"Enter a name of 1 to 100 characters."}`)
	if got := decode[site](t, admin.Do("PATCH", "/api/sites/"+office.ID, `{"name":"Head office"}`)); got.Name != "Head office" || got.VPNGroup != "hq" {
		t.Errorf("renamed %+v", got)
	}
	if got := decode[site](t, admin.Do("PATCH", "/api/sites/"+office.ID, `{"vpn_group":""}`)); got.Name != "Head office" || got.VPNGroup != "" {
		t.Errorf("group cleared %+v", got)
	}
	want(t, "rename what is not there", admin.Do("PATCH", "/api/sites/nope", `{"name":"x"}`), 404, `{"success":false,"error":"Site not found"}`)

	// Deleting
	want(t, "delete", admin.Do("DELETE", "/api/sites/"+office.ID, ""), 200, `{"success":true}`)
	want(t, "delete again", admin.Do("DELETE", "/api/sites/"+office.ID, ""), 404, `{"success":false,"error":"Site not found"}`)
	if got := names(list(t, admin).Sites); got != "apartment,Plant" {
		t.Errorf("after delete admin sees %q", got)
	}

	var actions []string
	for _, row := range w.AuditRows() {
		actions = append(actions, strings.SplitN(row, "|", 2)[0])
	}
	if got := strings.Join(actions, ","); got != "site_created,site_deleted,site_created,site_created,site_created,site_updated,site_updated,site_deleted" {
		t.Errorf("audit: %s", got)
	}
}

func TestSiteNetworks(t *testing.T) {
	w := newWorld(t)
	admin := w.As("admin")
	office := create(t, admin, `{"name":"Office"}`)
	path := "/api/sites/" + office.ID + "/networks"

	want(t, "stored in canonical form", admin.Do("PUT", path, `{"networks":[{"cidr":"10.1.2.3/16","kind":"private"},{"cidr":"198.51.100.0/24","kind":"public"}]}`),
		200, `{"success":true,"data":{"networks":[{"cidr":"10.1.0.0/16","kind":"private"},{"cidr":"198.51.100.0/24","kind":"public"}]}}`)

	for _, c := range []struct{ what, body, answer string }{
		{"no list", `{"networks":"10.0.0.0/8"}`, `{"success":false,"error":"Send the networks as a list."}`},
		{"not a CIDR", `{"networks":[{"cidr":"10.0.0.0/8","kind":"private"},{"cidr":"10.0.0.0/33","kind":"private"}]}`,
			`{"success":false,"error":"10.0.0.0/33 is not a network. Write it as address/prefix, like 10.1.0.0/16.","index":1}`},
		{"public range as private", `{"networks":[{"cidr":"8.8.8.0/24","kind":"private"}]}`,
			`{"success":false,"error":"8.8.8.0/24 is not a private network. Private networks lie in 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 or fc00::/7.","index":0}`},
		{"private range as public", `{"networks":[{"cidr":"192.168.1.0/24","kind":"public"}]}`,
			`{"success":false,"error":"192.168.1.0/24 is a private network. Add it as private.","index":0}`},
		{"unknown kind", `{"networks":[{"cidr":"10.0.0.0/8","kind":"lan"}]}`,
			`{"success":false,"error":"A network is either public or private.","index":0}`},
		{"twice", `{"networks":[{"cidr":"10.0.0.0/8","kind":"private"},{"cidr":"10.9.9.9/8","kind":"private"}]}`,
			`{"success":false,"error":"10.0.0.0/8 is listed twice.","index":1}`},
	} {
		want(t, c.what, admin.Do("PUT", path, c.body), 400, c.answer)
	}
	// None of the refused lists changed what is stored
	l := list(t, admin)
	if len(l.Sites) != 1 || len(l.Sites[0].Networks) != 2 || l.Sites[0].Networks[0].CIDR != "10.1.0.0/16" {
		t.Fatalf("after refusals: %+v", l.Sites)
	}
	// Device A registered from 10.1.2.3, so it is at the site; B is not
	if l.Sites[0].Devices != 1 {
		t.Errorf("devices at the site: %d, want 1", l.Sites[0].Devices)
	}
	devicesAnswer := admin.Do("GET", "/api/devices", "").Body
	if !strings.Contains(devicesAnswer, `"id":"A"`) || !strings.Contains(devicesAnswer, `"site":{"id":"`+office.ID+`","name":"Office"}`) ||
		strings.Count(devicesAnswer, `"site":null`) != 2 {
		t.Errorf("device list sites: %s", devicesAnswer)
	}

	want(t, "an empty list clears them", admin.Do("PUT", path, `{"networks":[]}`), 200, `{"success":true,"data":{"networks":[]}}`)
	want(t, "networks of no site", admin.Do("PUT", "/api/sites/nope/networks", `{"networks":[]}`), 404, `{"success":false,"error":"Site not found"}`)
}

func TestEnrollmentTokenAndNodes(t *testing.T) {
	w := newWorld(t)
	admin := w.As("admin")
	office := create(t, admin, `{"name":"Office"}`)
	path := "/api/sites/" + office.ID + "/enrollment-tokens"

	want(t, "relay nodes off", admin.Do("POST", path, "{}"), 503,
		`{"success":false,"error":"Relay nodes are turned off on this server (NODE_CONTROL_PORT=0). Turn them on and restart the server to add a node."}`)

	glue := w.startHub(t)
	if !list(t, admin).NodesEnabled {
		t.Error("nodes_enabled with the hub running")
	}
	type tokenData struct {
		Token     string    `json:"token"`
		Join      string    `json:"join"`
		Server    string    `json:"server"`
		Command   string    `json:"command"`
		ExpiresAt time.Time `json:"expires_at"`
		Commands  struct {
			Linux, Docker, Windows string
		} `json:"commands"`
	}
	got := admin.Do("POST", path, "{}")
	tok := decode[tokenData](t, got)
	j, err := wire.ParseJoin(tok.Join)
	if err != nil {
		t.Fatalf("join %q: %v", tok.Join, err)
	}
	if j.Token != tok.Token || j.Pin != glue.Pin || j.Server != tok.Server || j.Server != "127.0.0.1:"+strconv.Itoa(glue.ControlPort) {
		t.Errorf("join %+v, answer %+v, port %d", j, tok, glue.ControlPort)
	}
	if tok.Command != "curl -fsSL https://neode.sk/install.sh | sudo bash -s -- --node --join "+tok.Join || tok.Commands.Linux != tok.Command {
		t.Errorf("linux command %q", tok.Command)
	}
	if !strings.Contains(tok.Commands.Docker, "NODE_JOIN="+tok.Join+" docker compose -f docker-compose.relay-node.yml up -d") ||
		!strings.Contains(tok.Commands.Windows, "-Node -Join "+tok.Join) {
		t.Errorf("commands %+v", tok.Commands)
	}
	if left := time.Until(tok.ExpiresAt); left < 23*time.Hour || left > 25*time.Hour {
		t.Errorf("expires in %v", left)
	}
	// Shown once: the list never carries it, the next token is another
	if body := admin.Do("GET", "/api/sites", "").Body; strings.Contains(body, tok.Token) {
		t.Error("the list shows the token")
	}
	if again := decode[tokenData](t, admin.Do("POST", path, "{}")); again.Token == tok.Token || again.Token == "" {
		t.Errorf("second token %q", again.Token)
	}

	// A node enrolls with the string and shows up online
	a, err := agent.New(agent.Config{Join: tok.Join, DataDir: t.TempDir(), PublicAddr: "198.51.100.7:21117", Version: "9.9.9",
		Logf: t.Logf, BackoffMin: 20 * time.Millisecond, BackoffMax: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { a.RunControl(ctx); close(stopped) }()
	t.Cleanup(func() { cancel(); <-stopped })
	waitFor(t, "the node online in the list", func() bool {
		s := list(t, admin).Sites
		return len(s) == 1 && len(s[0].Nodes) == 1 && s[0].Nodes[0].Online
	})
	n := list(t, admin).Sites[0].Nodes[0]
	if n.ID != a.NodeID() || n.Version != "9.9.9" || n.PublicAddr != "198.51.100.7:21117" || n.LastSeen == nil || n.Revoked {
		t.Errorf("node %+v", n)
	}

	// Renaming and revoking
	want(t, "rename to nothing", admin.Do("PATCH", "/api/relay-nodes/"+n.ID, `{"name":" "}`), 400, `{"success":false,"error":"Enter a name of 1 to 100 characters."}`)
	if !strings.Contains(admin.Do("PATCH", "/api/relay-nodes/"+n.ID, `{"name":"Rack 2"}`).Body, `"name":"Rack 2"`) {
		t.Error("rename")
	}
	wantStatus(t, "a viewer revokes", w.As("viewer").Do("POST", "/api/relay-nodes/"+n.ID+"/revoke", "{}"), 403)
	want(t, "revoke", admin.Do("POST", "/api/relay-nodes/"+n.ID+"/revoke", "{}"), 200, `{"success":true}`)
	waitFor(t, "the revoked node off the hub", func() bool { return !glue.Hub.Online(n.ID) })
	n2 := list(t, admin).Sites[0].Nodes[0]
	if !n2.Revoked || n2.Online || n2.Name != "Rack 2" {
		t.Errorf("after revoke %+v", n2)
	}
	want(t, "revoke again", admin.Do("POST", "/api/relay-nodes/"+n.ID+"/revoke", "{}"), 200, `{"success":true}`)
	want(t, "revoke no node", admin.Do("POST", "/api/relay-nodes/nope/revoke", "{}"), 404, `{"success":false,"error":"Relay node not found"}`)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("%s: not within 5 s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestAnOrganizationAdminSeesAndChangesOnlyItsSites(t *testing.T) {
	w := newWorld(t)
	admin, orgAdmin := w.As("admin"), w.As("operator")
	south := create(t, admin, `{"name":"South plant","org_id":"org-south"}`)
	create(t, admin, `{"name":"North plant","org_id":"org-north"}`)
	create(t, admin, `{"name":"Unassigned"}`)
	node := db.RelayNode{ID: "node-south", SiteID: south.ID, Name: "south-1", PublicKey: "key-south", CreatedAt: time.Now()}
	if err := w.data.CreateRelayNode(&node); err != nil {
		t.Fatal(err)
	}

	l := list(t, orgAdmin)
	if names(l.Sites) != "North plant" || l.Unassigned || len(l.Organizations) != 1 || l.Organizations[0].ID != "org-north" {
		t.Errorf("the organization admin sees %+v", l)
	}
	if strings.Contains(orgAdmin.Do("GET", "/api/sites", "").Body, "south") {
		t.Error("the list names the other organization's site or node")
	}

	notFound := `{"success":false,"error":"Site not found"}`
	want(t, "rename", orgAdmin.Do("PATCH", "/api/sites/"+south.ID, `{"name":"Mine"}`), 404, notFound)
	want(t, "networks", orgAdmin.Do("PUT", "/api/sites/"+south.ID+"/networks", `{"networks":[]}`), 404, notFound)
	want(t, "token", orgAdmin.Do("POST", "/api/sites/"+south.ID+"/enrollment-tokens", "{}"), 404, notFound)
	want(t, "delete", orgAdmin.Do("DELETE", "/api/sites/"+south.ID, ""), 404, notFound)
	nodeGone := `{"success":false,"error":"Relay node not found"}`
	want(t, "revoke its node", orgAdmin.Do("POST", "/api/relay-nodes/node-south/revoke", "{}"), 404, nodeGone)
	want(t, "rename its node", orgAdmin.Do("PATCH", "/api/relay-nodes/node-south", `{"name":"x"}`), 404, nodeGone)
	want(t, "create in it", orgAdmin.Do("POST", "/api/sites", `{"name":"x","org_id":"org-south"}`), 400, `{"success":false,"error":"Pick an organization you belong to."}`)
	want(t, "create without an organization", orgAdmin.Do("POST", "/api/sites", `{"name":"x","org_id":""}`), 400, `{"success":false,"error":"Pick an organization you belong to."}`)

	// Probe results between the other organization's nodes stay hidden
	node2 := db.RelayNode{ID: "node-south-2", SiteID: south.ID, Name: "south-2", PublicKey: "key-south-2", CreatedAt: time.Now()}
	if err := w.data.CreateRelayNode(&node2); err != nil {
		t.Fatal(err)
	}
	if err := w.data.UpsertSiteReachability(&db.SiteReachability{FromNode: "node-south", ToNode: "node-south-2", Via: "public", OK: true, RTTMs: 4, CheckedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	want(t, "reachability", orgAdmin.Do("GET", "/api/sites/reachability", ""), 200, `{"success":true,"data":{"results":[]}}`)
	if body := admin.Do("GET", "/api/sites/reachability", "").Body; !strings.Contains(body, `"from":"node-south","to":"node-south-2","via":"public","ok":true,"rtt_ms":4`) {
		t.Errorf("admin's reachability: %s", body)
	}

	// Its own organization is the default
	if mine := create(t, orgAdmin, `{"name":"Depot"}`); mine.OrgID != "org-north" {
		t.Errorf("made %+v", mine)
	}
	if s, _ := w.data.GetSite(south.ID); s == nil || s.Name != "South plant" {
		t.Errorf("the other site after all that: %+v", s)
	}
	if n, _ := w.data.GetRelayNode("node-south"); n == nil || n.RevokedAt != nil || n.Name != "south-1" {
		t.Errorf("the other node after all that: %+v", n)
	}
}

func TestPins(t *testing.T) {
	w := newWorld(t)
	admin, viewer := w.As("admin"), w.As("viewer")
	office := create(t, admin, `{"name":"Office"}`)
	south := create(t, admin, `{"name":"South","org_id":"org-south"}`)

	// Device B is at no site by its address; the pin puts it at Office
	want(t, "pin", admin.Do("PATCH", "/api/devices/B/site", `{"site_id":"`+office.ID+`"}`), 200,
		`{"success":true,"data":{"pin":{"id":"`+office.ID+`","name":"Office"},"site":{"id":"`+office.ID+`","name":"Office"}}}`)
	detail := admin.Do("GET", "/api/devices/B", "").Body
	if !strings.Contains(detail, `"site":{"id":"`+office.ID+`","name":"Office"},"site_pin":{"id":"`+office.ID+`","name":"Office"},"site_source":"pin"`) {
		t.Errorf("device detail: %s", detail)
	}
	if l := list(t, admin); names(l.Sites) != "Office,South" || l.Sites[0].Devices != 1 || l.Sites[1].Devices != 0 {
		t.Errorf("devices at the sites: %+v", l.Sites)
	}
	want(t, "pin to another organization's site", admin.Do("PATCH", "/api/devices/B/site", `{"site_id":"`+south.ID+`"}`), 400,
		`{"success":false,"error":"The site belongs to another organization than the device."}`)
	want(t, "pin to no site", admin.Do("PATCH", "/api/devices/B/site", `{"site_id":"nope"}`), 404, `{"success":false,"error":"Site not found"}`)
	want(t, "pin with a number", admin.Do("PATCH", "/api/devices/B/site", `{"site_id":5}`), 400, `{"success":false,"error":"Pick a site."}`)
	wantStatus(t, "a viewer pins", viewer.Do("PATCH", "/api/devices/B/site", `{"site_id":"`+office.ID+`"}`), 403)
	wantStatus(t, "no such device", admin.Do("PATCH", "/api/devices/Z/site", `{"site_id":""}`), 404)
	want(t, "unpin", admin.Do("PATCH", "/api/devices/B/site", `{"site_id":""}`), 200, `{"success":true,"data":{"pin":null}}`)
	if pin, _ := w.data.GetSitePin(db.SitePinDevice, "B"); pin != "" {
		t.Errorf("pin after unpin: %q", pin)
	}

	// Folders
	if got := admin.Do("POST", "/api/folders", `{"name":"Lab"}`); got.Status != 200 {
		t.Fatalf("folder: %d %s", got.Status, got.Body)
	}
	want(t, "pin a folder", admin.Do("PATCH", "/api/folders/1/site", `{"site_id":"`+office.ID+`"}`), 200,
		`{"success":true,"data":{"pin":{"id":"`+office.ID+`","name":"Office"}}}`)
	if body := admin.Do("GET", "/api/folders", "").Body; !strings.Contains(body, `"site_id":"`+office.ID+`"`) {
		t.Errorf("folder list: %s", body)
	}
	// A device in the folder is at the folder's site
	if got := admin.Do("PATCH", "/api/devices/B/folder", `{"folderId":1}`); got.Status != 200 {
		t.Fatalf("move: %d %s", got.Status, got.Body)
	}
	want(t, "pin no folder", admin.Do("PATCH", "/api/folders/9/site", `{"site_id":"`+office.ID+`"}`), 404, `{"success":false,"error":"Folder not found"}`)
	want(t, "pin a folder id that is no number", admin.Do("PATCH", "/api/folders/x/site", `{"site_id":""}`), 404, `{"success":false,"error":"Folder not found"}`)
	want(t, "unpin the folder", admin.Do("PATCH", "/api/folders/1/site", `{"site_id":null}`), 200, `{"success":true,"data":{"pin":null}}`)
	if pin, _ := w.data.GetSitePin(db.SitePinFolder, "1"); pin != "" {
		t.Errorf("folder pin after unpin: %q", pin)
	}
}

func TestSessionsNameTheirRelay(t *testing.T) {
	w := newWorld(t)
	admin := w.As("admin")
	office := create(t, admin, `{"name":"Office"}`)
	node := db.RelayNode{ID: "node-1", SiteID: office.ID, Name: "rack-1", PublicKey: "key-1", CreatedAt: time.Now()}
	if err := w.data.CreateRelayNode(&node); err != nil {
		t.Fatal(err)
	}
	sessionsBody = `{"sessions":[{"id":1,"relay_via":"node:node-1"},{"id":2,"relay_via":"central"},{"id":3,"relay_via":"nodes:node-1,node-9"},{"id":4},{"id":5,"relay_via":"odd"}]}`
	t.Cleanup(func() { sessionsBody = "" })
	got := admin.Do("GET", "/api/devices/A/connection-sessions", "")
	for _, part := range []string{
		`{"id":1,"relay_via":"node:node-1","relay":{"kind":"node","nodes":[{"id":"node-1","name":"rack-1"}]}}`,
		`{"id":2,"relay_via":"central","relay":{"kind":"central"}}`,
		`{"id":3,"relay_via":"nodes:node-1,node-9","relay":{"kind":"nodes","nodes":[{"id":"node-1","name":"rack-1"},{"id":"node-9","name":"node-9"}]}}`,
		`{"id":4}`,
		`{"id":5,"relay_via":"odd"}`,
	} {
		if !strings.Contains(got.Body, part) {
			t.Errorf("sessions lack %s:\n%s", part, got.Body)
		}
	}
}

// The join string's server is the address clients use for this server.
func TestTheJoinStringNamesThePublicHost(t *testing.T) {
	w := newWorld(t, "PUBLIC_SERVER_ID", "desk.example.com")
	admin := w.As("admin")
	office := create(t, admin, `{"name":"Office"}`)
	glue := w.startHub(t)
	got := admin.Do("POST", "/api/sites/"+office.ID+"/enrollment-tokens", "{}")
	var out struct {
		Data struct {
			Server string `json:"server"`
		} `json:"data"`
	}
	_ = json.Unmarshal([]byte(got.Body), &out)
	if wantServer := net.JoinHostPort("desk.example.com", strconv.Itoa(glue.ControlPort)); out.Data.Server != wantServer {
		t.Errorf("server %q, want %q (%s)", out.Data.Server, wantServer, got.Body)
	}
}

// fwdChannel is a relay node's UDP forwarding connection into signal: the
// test puts datagrams in, what signal sends back is dropped.
type fwdChannel struct {
	in     chan fwdDatagram
	closed chan struct{}
	once   sync.Once
}

type fwdDatagram struct {
	from *net.UDPAddr
	data []byte
}

func (c *fwdChannel) ReadPacket() (*net.UDPAddr, []byte, error) {
	select {
	case d := <-c.in:
		return d.from, d.data, nil
	case <-c.closed:
		return nil, nil, io.EOF
	}
}

func (c *fwdChannel) WritePacket(*net.UDPAddr, []byte) error { return nil }

func (c *fwdChannel) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

// forwardedID is the device that comes through a relay node in
// TestForwardedDevicesAndViaNode.
const forwardedID = "SITECPC1"

// TestForwardedDevicesAndViaNode: a device that registers through a relay
// node (a site without internet access) counts in the node's
// forwarded_devices, and its detail names the node as via_node; a device
// that reaches the server directly has via_node null.
func TestForwardedDevicesAndViaNode(t *testing.T) {
	w := newWorld(t)
	admin := w.As("admin")
	office := create(t, admin, `{"name":"Office"}`)
	glue := w.startHub(t)
	sig := signal.New(serverconfig.DefaultConfig(), nil, w.data)
	glue.Signal = sig

	type tokenData struct {
		Join string `json:"join"`
	}
	tok := decode[tokenData](t, admin.Do("POST", "/api/sites/"+office.ID+"/enrollment-tokens", "{}"))
	a, err := agent.New(agent.Config{Join: tok.Join, DataDir: t.TempDir(), Version: "9.9.9",
		Logf: t.Logf, BackoffMin: 20 * time.Millisecond, BackoffMax: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { a.RunControl(ctx); close(stopped) }()
	t.Cleanup(func() { cancel(); <-stopped })
	waitFor(t, "the node online", func() bool {
		s := list(t, admin).Sites
		return len(s) == 1 && len(s[0].Nodes) == 1 && s[0].Nodes[0].Online
	})
	nodeID := a.NodeID()
	if !strings.Contains(admin.Do("PATCH", "/api/relay-nodes/"+nodeID, `{"name":"Rack 3"}`).Body, `"name":"Rack 3"`) {
		t.Fatal("rename")
	}
	type nodeCount struct {
		Sites []struct {
			Nodes []struct {
				Forwarded int `json:"forwarded_devices"`
			} `json:"nodes"`
		} `json:"sites"`
	}
	forwarded := func() int {
		l := decode[nodeCount](t, admin.Do("GET", "/api/sites", ""))
		return l.Sites[0].Nodes[0].Forwarded
	}
	if n := forwarded(); n != 0 {
		t.Fatalf("forwarded_devices before any device: %d", n)
	}
	if body := admin.Do("GET", "/api/devices/"+forwardedID, "").Body; !strings.Contains(body, `"via_node":null`) {
		t.Errorf("the device before it came through the node: %s", body)
	}

	// The device registers through the node from its own LAN address
	ch := &fwdChannel{in: make(chan fwdDatagram, 4), closed: make(chan struct{})}
	done := make(chan struct{})
	go func() { sig.ServeForwardedUDP(nodeID, ch); close(done) }()
	t.Cleanup(func() { ch.Close(); <-done })
	msg, err := proto.Marshal(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: forwardedID}}})
	if err != nil {
		t.Fatal(err)
	}
	ch.in <- fwdDatagram{from: &net.UDPAddr{IP: net.ParseIP("10.1.2.4"), Port: 40000}, data: msg}
	waitFor(t, "the device forwarded by the node", func() bool { return forwarded() == 1 })

	if body := admin.Do("GET", "/api/devices/"+forwardedID, "").Body; !strings.Contains(body, `"via_node":{"id":"`+nodeID+`","name":"Rack 3"}`) {
		t.Errorf("the forwarded device's detail names no node: %s", body)
	}
	if body := admin.Do("GET", "/api/devices/B", "").Body; !strings.Contains(body, `"via_node":null`) {
		t.Errorf("device B reaches the server directly: %s", body)
	}
}
