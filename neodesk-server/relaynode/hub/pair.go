package hub

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// PairSpec names the two nodes of a session between two sites: the
// dialing node reaches the accepting node's leg listener at Dial. The keys
// are the nodes' enrolled public keys (relay_nodes.public_key).
type PairSpec struct {
	Dialer, Acceptor       string
	DialerKey, AcceptorKey string
	Dial                   string
}

var _ relay.Tickets = (*PairTickets)(nil)

// PairTickets is the ticket store of a session over two nodes: Authorize
// pushes the accepting node a ticket that takes a leg from the dialing
// node's key, and the dialing node one that dials the accepting node.
// Both must ack within the budget; otherwise neither keeps its ticket and
// Authorize returns ErrUnavailable, so signal falls back to one node or
// the central relay.
type PairTickets struct {
	h    *Hub
	spec PairSpec
}

// Pair returns the ticket store of a session between two sites.
func (h *Hub) Pair(spec PairSpec) *PairTickets {
	return &PairTickets{h: h, spec: spec}
}

// Spec is the pair the store pushes to.
func (t *PairTickets) Spec() PairSpec { return t.spec }

// Authorize pushes both tickets at once and waits for both acks until
// ctx's deadline, AuthorizeBudget when ctx has none.
func (t *PairTickets) Authorize(ctx context.Context, tk relay.Ticket) error {
	h, sp := t.h, t.spec
	if sp.Dialer == "" || sp.Acceptor == "" || sp.Dial == "" || sp.DialerKey == "" || sp.AcceptorKey == "" {
		return fmt.Errorf("%w: incomplete pair of nodes", ErrUnavailable)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, h.cfg.AuthorizeBudget)
		defer cancel()
	}
	accept := &wire.Leg{Role: wire.LegAccept, PeerKey: sp.DialerKey}
	dial := &wire.Leg{Role: wire.LegDial, PeerAddr: sp.Dial, PeerKey: sp.AcceptorKey}
	errs := make(chan [2]any, 2)
	for _, p := range []struct {
		node string
		leg  *wire.Leg
	}{{sp.Acceptor, accept}, {sp.Dialer, dial}} {
		go func() {
			err := h.push(ctx, p.node, tk.UUID, tk.Initiator, tk.Target, tk.Account, tk.ConsoleSession, tk.Expires, p.leg)
			errs <- [2]any{p.node, err}
		}()
	}
	var failed []string
	for range 2 {
		r := <-errs
		if err, _ := r[1].(error); err != nil {
			failed = append(failed, fmt.Sprintf("node %s: %v", r[0], err))
		}
	}
	if len(failed) == 0 {
		return nil
	}
	// Neither node keeps a ticket of a pair that can't run. The cancels go
	// out before signal pushes the fallback ticket, on the same
	// connections, so a node that is the fallback gets them in order.
	t.cancel(tk.UUID)
	return fmt.Errorf("%w: %s", ErrUnavailable, strings.Join(failed, "; "))
}

// cancel drops uuid on both nodes and in the hub.
func (t *PairTickets) cancel(uuid string) {
	h := t.h
	for _, id := range []string{t.spec.Acceptor, t.spec.Dialer} {
		h.mu.Lock()
		if n := h.nodes[id]; n != nil {
			if tk := n.tickets[uuid]; tk != nil && !tk.live {
				delete(n.tickets, uuid)
			}
		}
		h.mu.Unlock()
		if nc := h.conn(id); nc != nil {
			_ = nc.c.Write(wire.Cancel{UUID: uuid}, closeTimeout)
		}
	}
}

// Admitted reports whether the accepting node, whose reports drive the
// session, holds a ticket of uuid for the pair or runs the session.
func (t *PairTickets) Admitted(uuid, initiator, target string) bool {
	return t.h.Tickets(t.spec.Acceptor).Admitted(uuid, initiator, target)
}

// RevokeForPeer drops the unclaimed tickets of peer on both nodes.
func (t *PairTickets) RevokeForPeer(peer string) {
	t.h.Tickets(t.spec.Acceptor).RevokeForPeer(peer)
	t.h.Tickets(t.spec.Dialer).RevokeForPeer(peer)
}

// Live returns the session uuid while the accepting node reports it
// running.
func (t *PairTickets) Live(uuid string) (relay.LivePair, bool) {
	return t.h.Tickets(t.spec.Acceptor).Live(uuid)
}

// End asks both nodes to end the session uuid.
func (t *PairTickets) End(uuid string) {
	t.h.Tickets(t.spec.Acceptor).End(uuid)
	t.h.Tickets(t.spec.Dialer).End(uuid)
}

// LegAddrs is where other nodes reach the node's leg listener, as its
// hello said: on the LAN (or a VPN) and from outside. "" while the node is
// offline or has no leg listener there (sites.NodeLegs).
func (h *Hub) LegAddrs(nodeID string) (lan, public string) {
	if nc := h.conn(nodeID); nc != nil {
		return nc.hello.LegLanAddr, nc.hello.LegPublicAddr
	}
	return "", ""
}

// ErrOffline is Probe's error for a node without a control connection.
var ErrOffline = errors.New("relay node is offline")

// Probe asks the node to check that it reaches the targets' leg
// listeners; the answer comes to ProbeEvents.
func (h *Hub) Probe(nodeID string, targets []wire.ProbeTarget) error {
	nc := h.conn(nodeID)
	if nc == nil {
		return ErrOffline
	}
	return nc.send(wire.Probe{Targets: targets})
}
