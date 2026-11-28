package hub

import (
	"context"
	"fmt"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/config"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Errors of NodeTickets.Authorize. Signal falls back to the central relay
// on ErrUnavailable.
var (
	ErrUnavailable = relay.ErrTicketsUnavailable
	ErrRejected    = relay.ErrTicketRejected
)

var _ relay.Tickets = (*NodeTickets)(nil)

// NodeTickets is the remote ticket store of one node. It works whether
// the node is connected or not: Authorize then returns ErrUnavailable.
type NodeTickets struct {
	h      *Hub
	nodeID string
}

// Tickets returns the ticket store of the node.
func (h *Hub) Tickets(nodeID string) *NodeTickets {
	return &NodeTickets{h: h, nodeID: nodeID}
}

// NodeID is the node the store pushes to.
func (t *NodeTickets) NodeID() string { return t.nodeID }

// Authorize pushes a ticket to the node and waits for its ack until ctx's
// deadline, AuthorizeBudget when ctx has none. The account and console
// session stay on central (for Admitted and Live); the node gets the pair.
func (t *NodeTickets) Authorize(ctx context.Context, tk relay.Ticket) error {
	return t.AuthorizePair(ctx, tk.UUID, tk.Initiator, tk.Target, tk.Account, tk.ConsoleSession, tk.Expires)
}

// AuthorizePair is Authorize with the ticket's fields.
func (t *NodeTickets) AuthorizePair(ctx context.Context, uuid, initiator, target string, account int64, session string, expires time.Time) error {
	return t.h.push(ctx, t.nodeID, uuid, initiator, target, account, session, expires, nil)
}

// push sends a ticket, with a leg for a session over two nodes, to the
// node and waits for its ack.
func (h *Hub) push(ctx context.Context, nodeID, uuid, initiator, target string, account int64, session string, expires time.Time, leg *wire.Leg) error {
	if uuid == "" || initiator == "" || target == "" {
		return fmt.Errorf("%w: incomplete ticket", ErrRejected)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, h.cfg.AuthorizeBudget)
		defer cancel()
	}
	h.count(nodeID, func(c *ticketCounts) { c.pushed++ })
	unavailable := func(why string) error {
		h.count(nodeID, func(c *ticketCounts) { c.unavailable++ })
		return fmt.Errorf("%w: %s", ErrUnavailable, why)
	}

	nc := h.conn(nodeID)
	if nc == nil {
		return unavailable("not connected")
	}
	id := h.nextID.Add(1)
	ch := nc.addAck(id)
	if ch == nil {
		return unavailable("connection lost")
	}
	defer nc.removeAck(id)

	msg := wire.Authorize{ID: id, UUID: uuid, Initiator: initiator, Target: target, Leg: leg}
	if !expires.IsZero() {
		msg.ExpiresUnixMs = expires.UnixMilli()
	}
	deadline, _ := ctx.Deadline()
	wait := time.Until(deadline)
	if wait <= 0 {
		return unavailable("no time left")
	}
	if err := nc.c.Write(msg, wait); err != nil {
		nc.close()
		return unavailable("send failed")
	}
	select {
	case a := <-ch:
		if !a.OK {
			h.count(nodeID, func(c *ticketCounts) { c.rejected++ })
			return fmt.Errorf("%w: %s", ErrRejected, a.Err)
		}
	case <-ctx.Done():
		return unavailable("no ack in time")
	case <-nc.done:
		return unavailable("connection lost")
	}
	h.count(nodeID, func(c *ticketCounts) { c.ok++ })
	now := h.cfg.Now()
	if expires.IsZero() {
		expires = now.Add(config.RelayPairTimeout)
	}
	h.mu.Lock()
	n := h.state(nodeID)
	n.pruneLocked(h, now)
	tk := &ticket{initiator: initiator, target: target, account: account, session: session, expires: expires}
	if leg != nil {
		tk.leg = leg.Role
	}
	n.tickets[uuid] = tk
	h.sessions[uuid] = nodeID
	h.mu.Unlock()
	return nil
}

// RevokeForPeer drops the node's unclaimed tickets involving peer.
func (t *NodeTickets) RevokeForPeer(peer string) {
	if peer == "" {
		return
	}
	h := t.h
	h.mu.Lock()
	if n := h.nodes[t.nodeID]; n != nil {
		n.dropPeerLocked(h, peer)
	}
	h.mu.Unlock()
	if nc := h.conn(t.nodeID); nc != nil {
		go nc.send(wire.Revoke{Peer: peer})
	}
}

// End asks the node to end the session uuid.
func (t *NodeTickets) End(uuid string) {
	if nc := t.h.conn(t.nodeID); nc != nil && uuid != "" {
		go nc.send(wire.End{UUID: uuid})
	}
}

// Admitted reports whether the node acked a ticket of uuid for the pair
// that has not expired, or runs the session.
func (t *NodeTickets) Admitted(uuid, initiator, target string) bool {
	h := t.h
	h.mu.Lock()
	defer h.mu.Unlock()
	n := h.nodes[t.nodeID]
	if n == nil {
		return false
	}
	n.pruneLocked(h, h.cfg.Now())
	tk := n.tickets[uuid]
	return tk != nil && tk.initiator == initiator && tk.target == target
}

// Live returns the session uuid while the node reports it running.
func (t *NodeTickets) Live(uuid string) (relay.LivePair, bool) {
	h := t.h
	h.mu.Lock()
	defer h.mu.Unlock()
	n := h.nodes[t.nodeID]
	if n == nil {
		return relay.LivePair{}, false
	}
	tk := n.tickets[uuid]
	if tk == nil || !tk.live {
		return relay.LivePair{}, false
	}
	return relay.LivePair{Initiator: tk.initiator, Target: tk.target, Account: tk.account, ConsoleSession: tk.session, Since: tk.since}, true
}
