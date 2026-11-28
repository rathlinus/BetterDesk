package central

import (
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/signal"
	"github.com/neodeskapp/neodesk/neodesk-server/sites"
)

// pairRoute is the route between two sites: the initiator dials node A,
// the target node B, and the dialing node (A, or B when only that way
// works) reaches the other's leg listener at r.Dial. The tickets go to
// both nodes; when they can't take them in time the session moves to the
// one-node fallback, else to the central relay (signal's admitRoute).
func (g *Glue) pairRoute(r sites.NodeRoute) (signal.NodeRelay, bool) {
	fallback, hasFallback := g.singleRoute(r.Fallback)
	if r.A == nil || r.B == nil || r.Dial == "" || !g.Hub.Online(r.A.ID) || !g.Hub.Online(r.B.ID) {
		return fallback, hasFallback
	}
	dialer, acceptor := r.A, r.B
	if r.Reverse {
		dialer, acceptor = r.B, r.A
	}
	nr := signal.NodeRelay{
		Addr: r.InitiatorAddr, TargetAddr: r.TargetAddr,
		Tickets: g.Hub.Pair(hub.PairSpec{
			Dialer: dialer.ID, Acceptor: acceptor.ID,
			DialerKey: dialer.PublicKey, AcceptorKey: acceptor.PublicKey,
			Dial: r.Dial,
		}),
		Via: "nodes:" + r.A.ID + "," + r.B.ID,
	}
	if hasFallback {
		nr.Fallback = &fallback
	}
	return nr, true
}

// singleRoute is the route of a one-node route, if its node is online.
func (g *Glue) singleRoute(r *sites.NodeRoute) (signal.NodeRelay, bool) {
	if r == nil || r.Kind != sites.Same || r.A == nil || !g.Hub.Online(r.A.ID) {
		return signal.NodeRelay{}, false
	}
	return signal.NodeRelay{
		Addr: r.InitiatorAddr, TargetAddr: r.TargetAddr,
		Tickets: g.Hub.Tickets(r.A.ID), Via: "node:" + r.A.ID,
	}, true
}
