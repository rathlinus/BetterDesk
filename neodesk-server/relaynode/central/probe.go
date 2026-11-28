package central

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/db"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Defaults of the probe rounds.
const (
	DefaultProbeInterval = 5 * time.Minute
	DefaultProbeDelay    = 2 * time.Second
)

// probes is the glue's probe state: what each node was asked to check,
// so a node can only report on the targets central gave it.
type probes struct {
	interval, delay time.Duration

	mu      sync.Mutex
	asked   map[[2]string]probeAsk // from node, to node
	pending *time.Timer            // a round after a node connected
}

type probeAsk struct {
	addr, via string
	at        time.Time
}

// runProbes probes every interval until ctx ends.
func (g *Glue) runProbes(ctx context.Context) {
	t := time.NewTicker(g.probes.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			g.ProbeRound()
		}
	}
}

// NodeConnected starts a probe round shortly after a node connects, so
// the new node and the others learn about each other (hub.ConnectEvents).
// Nodes that connect together share one round.
func (g *Glue) NodeConnected(string) {
	p := &g.probes
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.pending != nil || p.delay <= 0 {
		return
	}
	p.pending = time.AfterFunc(p.delay, func() {
		p.mu.Lock()
		p.pending = nil
		p.mu.Unlock()
		g.ProbeRound()
	})
}

// ProbeRound sends every online node a probe of the other online nodes of
// its organization at other sites: their leg listener's LAN address when
// both sites have the same VPN group, else its public address, the
// address a session between the two sites would dial.
func (g *Glue) ProbeRound() {
	if g.Hub == nil {
		return
	}
	nodes, err := g.DB.ListRelayNodes("")
	if err != nil {
		log.Printf("[relay-node] probe round: %v", err)
		return
	}
	all, err := g.DB.ListSites("", true)
	if err != nil {
		log.Printf("[relay-node] probe round: %v", err)
		return
	}
	siteOf := make(map[string]db.Site, len(all))
	for _, s := range all {
		siteOf[s.ID] = s
	}
	var online []db.RelayNode
	for _, n := range nodes {
		if !n.Revoked() && g.Hub.Online(n.ID) {
			online = append(online, n)
		}
	}
	now := time.Now()
	p := &g.probes
	for _, x := range online {
		sx, ok := siteOf[x.SiteID]
		if !ok {
			continue
		}
		var targets []wire.ProbeTarget
		for _, y := range online {
			sy, ok := siteOf[y.SiteID]
			if !ok || y.SiteID == x.SiteID || sy.OrgID != sx.OrgID {
				continue
			}
			via, addr := db.SiteNetworkPublic, ""
			lan, public := g.Hub.LegAddrs(y.ID)
			if sx.VPNGroup != "" && sx.VPNGroup == sy.VPNGroup {
				via, addr = db.SiteNetworkPrivate, lan
			} else {
				addr = public
			}
			if addr == "" || y.PublicKey == "" {
				continue
			}
			targets = append(targets, wire.ProbeTarget{NodeID: y.ID, Addr: addr, Key: y.PublicKey})
			p.mu.Lock()
			if p.asked == nil {
				p.asked = make(map[[2]string]probeAsk)
			}
			p.asked[[2]string{x.ID, y.ID}] = probeAsk{addr: addr, via: via, at: now}
			p.mu.Unlock()
		}
		if len(targets) == 0 {
			continue
		}
		if err := g.Hub.Probe(x.ID, targets); err != nil {
			log.Printf("[relay-node] probe of node %s not sent: %v", x.ID, err)
		}
	}
}

// NodeProbed stores the results of a probe the node was asked for
// (hub.ProbeEvents). A result for a target or an address central did not
// give the node, or for an ask older than two intervals, is dropped.
func (g *Glue) NodeProbed(nodeID string, results []wire.ProbeResult) {
	now := time.Now()
	p := &g.probes
	for _, r := range results {
		key := [2]string{nodeID, r.NodeID}
		p.mu.Lock()
		ask, ok := p.asked[key]
		if ok && ask.addr == r.Addr {
			delete(p.asked, key)
		}
		p.mu.Unlock()
		if !ok || ask.addr != r.Addr || now.Sub(ask.at) > 2*p.interval {
			log.Printf("[relay-node] node %s reported a probe of node %s at %s that it was not asked for; dropped", nodeID, r.NodeID, r.Addr)
			continue
		}
		rtt := r.RTTMs
		if !r.OK || rtt < 0 {
			rtt = 0
		}
		if rtt > 60_000 {
			rtt = 60_000
		}
		if err := g.Sites.RecordReachability(db.SiteReachability{
			FromNode: nodeID, ToNode: r.NodeID, Via: ask.via, OK: r.OK, RTTMs: int(rtt), CheckedAt: now.UTC(),
		}); err != nil {
			log.Printf("[relay-node] store probe of node %s by node %s: %v", r.NodeID, nodeID, err)
		}
	}
}
