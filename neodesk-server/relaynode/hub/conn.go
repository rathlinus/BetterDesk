package hub

import (
	"sync"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// nodeConn is the control connection of one enrolled node.
type nodeConn struct {
	h      *Hub
	nodeID string
	c      *wire.Conn
	ip     string
	key    string // the node's public key (base64), from its client cert
	hello  wire.Hello

	mu   sync.Mutex
	acks map[uint64]chan wire.Ack

	done      chan struct{}
	closeOnce sync.Once
}

func (nc *nodeConn) close() {
	nc.closeOnce.Do(func() {
		close(nc.done)
		nc.c.Close()
	})
}

// closeWith sends m (an error) and closes.
func (nc *nodeConn) closeWith(m wire.Message) {
	nc.closeOnce.Do(func() {
		close(nc.done)
		_ = nc.c.Write(m, closeTimeout)
		nc.c.Close()
	})
}

func (nc *nodeConn) send(m wire.Message) error {
	err := nc.c.Write(m, writeTimeout)
	if err != nil {
		nc.close()
	}
	return err
}

func (nc *nodeConn) closed() bool {
	select {
	case <-nc.done:
		return true
	default:
		return false
	}
}

// addAck registers a waiter for the ack of id; nil once closed.
func (nc *nodeConn) addAck(id uint64) chan wire.Ack {
	nc.mu.Lock()
	defer nc.mu.Unlock()
	if nc.closed() {
		return nil
	}
	ch := make(chan wire.Ack, 1)
	nc.acks[id] = ch
	return ch
}

func (nc *nodeConn) removeAck(id uint64) {
	nc.mu.Lock()
	delete(nc.acks, id)
	nc.mu.Unlock()
}

// run reads frames until the connection ends; a ping goes out every
// PingInterval and IdleTimeout of silence ends it.
func (nc *nodeConn) run() {
	h := nc.h
	go func() {
		t := time.NewTicker(h.cfg.PingInterval)
		defer t.Stop()
		for {
			select {
			case <-nc.done:
				return
			case <-t.C:
				if nc.send(wire.Ping{}) != nil {
					return
				}
			}
		}
	}()
	for {
		f, err := nc.c.Read(h.cfg.IdleTimeout)
		if err != nil {
			if !nc.closed() {
				h.cfg.Logf("[nodes] Node %s: %v", nc.nodeID, err)
			}
			return
		}
		nc.handle(f)
	}
}

func (nc *nodeConn) handle(f wire.Frame) {
	h := nc.h
	switch f.Type {
	case wire.TypePong:
	case wire.TypeAck:
		var a wire.Ack
		if f.Decode(&a) != nil {
			return
		}
		nc.mu.Lock()
		ch := nc.acks[a.ID]
		delete(nc.acks, a.ID)
		nc.mu.Unlock()
		if ch != nil {
			ch <- a
		}
	case wire.TypeStarted:
		var m wire.Started
		if f.Decode(&m) != nil || m.UUID == "" {
			return
		}
		now := h.cfg.Now()
		h.mu.Lock()
		n := h.state(nc.nodeID)
		// Only a session this node holds a ticket for: billing and the
		// session record must never follow another node's (or another
		// organization's) uuid. The dialing node of a two-node session
		// reports quietly: the accepting node drives billing.
		t := n.tickets[m.UUID]
		known := t != nil && !t.live
		quiet := false
		if known {
			n.active++
			t.live = true
			t.since = now
			quiet = t.leg == wire.LegDial
			if !quiet {
				h.sessions[m.UUID] = nc.nodeID
			}
		}
		h.mu.Unlock()
		if !known {
			nc.foreignSession("started", m.UUID)
			return
		}
		if h.cfg.Events != nil && !quiet {
			h.cfg.Events.NodeSessionStarted(nc.nodeID, m.UUID)
		}
	case wire.TypeEnded:
		var m wire.Ended
		if f.Decode(&m) != nil || m.UUID == "" {
			return
		}
		h.mu.Lock()
		n := h.state(nc.nodeID)
		tk, known := n.tickets[m.UUID]
		quiet := known && tk.leg == wire.LegDial
		if known {
			if n.active > 0 {
				n.active--
			}
			delete(n.tickets, m.UUID)
			if h.sessions[m.UUID] == nc.nodeID {
				delete(h.sessions, m.UUID)
			}
		}
		h.mu.Unlock()
		if !known {
			// Central restarted since the ticket: the session record
			// says which node relayed it
			if o, ok := h.cfg.Store.(SessionOwner); ok && o.NodeRelayedSession(nc.nodeID, m.UUID) {
				known = true
			}
		}
		if !known {
			nc.foreignSession("ended", m.UUID)
			return
		}
		if h.cfg.Events != nil && !quiet {
			h.cfg.Events.NodeSessionEnded(nc.nodeID, m.UUID, m.Up, m.Down)
		}
	case wire.TypeStats:
		var s wire.Stats
		if f.Decode(&s) != nil {
			return
		}
		h.mu.Lock()
		n := h.state(nc.nodeID)
		n.active, n.up, n.down = s.Active, s.UpTotal, s.DownTotal
		n.addLegCountsLocked(s)
		h.mu.Unlock()
		if err := h.cfg.Store.UpdateRelayNodeState(nc.nodeID, nc.hello.Version, nc.hello.LanAddr, nc.hello.PublicAddr, h.cfg.Now()); err != nil {
			h.cfg.Logf("[nodes] node %s: save state: %v", nc.nodeID, err)
		}
		if h.cfg.Events != nil {
			h.cfg.Events.NodeStats(nc.nodeID, s)
		}
	case wire.TypeProbed:
		var m wire.Probed
		if f.Decode(&m) != nil {
			return
		}
		if pe, ok := h.cfg.Events.(ProbeEvents); ok {
			pe.NodeProbed(nc.nodeID, m.Results)
		}
	default:
		// types of newer nodes
	}
}

// foreignSession logs and audits a started or ended report for a uuid the
// node holds no ticket for, which the hub ignores.
func (nc *nodeConn) foreignSession(kind, uuid string) {
	nc.h.cfg.Logf("[nodes] Node %s reported %s for uuid %s without a ticket; ignored", nc.nodeID, kind, uuid)
	nc.h.audit("relay_node.unknown_session", map[string]string{"node_id": nc.nodeID, "report": kind, "uuid": uuid})
}

// addLegCountsLocked adds the legs since the node's last stats to the
// counts of the next audit. Totals that went down are a restarted node.
func (n *nodeState) addLegCountsLocked(s wire.Stats) {
	prev := n.legs
	if s.LegsAccepted < prev.accepted {
		prev = legTotals{}
	}
	n.counts.legsAccepted += s.LegsAccepted - prev.accepted
	for reason, total := range s.LegsRefused {
		before := prev.refused[reason]
		if total < before {
			before = 0
		}
		if d := total - before; d > 0 {
			if n.counts.legsRefused == nil {
				n.counts.legsRefused = map[string]int64{}
			}
			n.counts.legsRefused[reason] += d
		}
	}
	n.legs = legTotals{accepted: s.LegsAccepted, refused: s.LegsRefused}
}
