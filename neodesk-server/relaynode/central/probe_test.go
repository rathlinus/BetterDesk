package central

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/db"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
	"github.com/neodeskapp/neodesk/neodesk-server/sites"
)

// TestOnlyAskedProbesAreStored: a node's probe result is stored, with the
// via central asked over, only for a target and address central gave it,
// and once; anything else a node claims about reachability is dropped.
func TestOnlyAskedProbesAreStored(t *testing.T) {
	sq, err := db.OpenSQLite(filepath.Join(t.TempDir(), "central.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sq.Close() })
	if err := sq.Migrate(); err != nil {
		t.Fatal(err)
	}
	g := &Glue{DB: sq, Sites: sites.New(sq)}
	g.probes.interval = time.Minute
	g.probes.asked = map[[2]string]probeAsk{
		{"node-a", "node-b"}: {addr: "10.2.0.5:21125", via: "private", at: time.Now()},
		{"node-a", "node-c"}: {addr: "203.0.113.3:21125", via: "public", at: time.Now().Add(-3 * time.Minute)},
	}
	g.NodeProbed("node-a", []wire.ProbeResult{
		{NodeID: "node-b", Addr: "10.2.0.5:21125", OK: true, RTTMs: 7},
		{NodeID: "node-c", Addr: "203.0.113.3:21125", OK: true, RTTMs: 9},  // asked too long ago
		{NodeID: "node-d", Addr: "203.0.113.4:21125", OK: false},           // never asked
		{NodeID: "node-b", Addr: "203.0.113.2:21125", OK: false, RTTMs: 1}, // another address
	})
	g.NodeProbed("node-x", []wire.ProbeResult{{NodeID: "node-b", Addr: "10.2.0.5:21125", OK: false}}) // asked of node-a only
	g.NodeProbed("node-a", []wire.ProbeResult{{NodeID: "node-b", Addr: "10.2.0.5:21125", OK: false}}) // answered already

	rows, err := sq.ListSiteReachability()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("stored %+v, want only node-a -> node-b", rows)
	}
	r := rows[0]
	if r.FromNode != "node-a" || r.ToNode != "node-b" || r.Via != "private" || !r.OK || r.RTTMs != 7 || r.CheckedAt.IsZero() {
		t.Fatalf("stored %+v", r)
	}
}
