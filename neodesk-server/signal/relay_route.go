package signal

import (
	"net"

	"github.com/neodeskapp/neodesk/neodesk-server/peer"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
)

// RelayRoute is the relay a session uses: the address the initiator dials,
// the address the target is told, the ticket store the session's ticket is
// issued on (the relay at that address claims from it) and how the session
// travels, for live sessions and logs.
type RelayRoute struct {
	// Addr is the relay address the initiator gets (RelayResponse,
	// PunchHoleResponse, PunchHole, FetchLocalAddr).
	Addr string
	// TargetAddr is the relay address in the RequestRelay sent to the
	// target. Stock clients compare it with the relay they configured
	// (relayAdvertisedToTarget), so it can differ from Addr.
	TargetAddr string
	// Tickets is where admitSession issues the session's ticket.
	Tickets relay.Tickets
	// Via says which relay carries the session: viaCentral or viaLAN.
	Via string
	// SameNetwork is true when both peers are on one private network,
	// Hairpin when they share a public address and SAME_NAT_RELAY forces
	// the public relay.
	SameNetwork bool
	Hairpin     bool
	// Forwarded is true when a peer reaches this server only through a
	// relay node (forward.go). Such a session is relayed by that node or
	// not at all: ForceRelay keeps it from a direct punch (unless both
	// peers are on one node's network), Blocked means no relay it can
	// use exists and the session is refused (D18).
	Forwarded  bool
	ForceRelay bool
	Blocked    bool
	// nodeFallback is the one-node route admitRoute moves a route over
	// two nodes to when they can't take the tickets.
	nodeFallback *NodeRelay
}

// Values of RelayRoute.Via.
const (
	// viaCentral is the server's own relay at its public address.
	viaCentral = "central"
	// viaLAN is the server's own relay at its LAN address.
	viaLAN = "lan"
	// viaNodePrefix starts the Via of a relay node route: "node:<id>".
	viaNodePrefix = "node:"
)

// relayRouteRequest is what chooseRelay picks a route from.
type relayRouteRequest struct {
	// base is the relay the session starts from: getRelayServer(), or
	// the relay a client named after sanitizeClientRelayAddress.
	base string
	// a and b are the two peers' addresses for the LAN and shared-NAT
	// checks; either may be nil.
	a, b *net.UDPAddr
	// target fills RelayRoute.TargetAddr; nil leaves it at Addr.
	target *peer.Entry
	// policyPeers are the peers whose org network policy
	// (allowed_relay_servers) applies; none skips the policy.
	policyPeers []string
	// initiatorID and targetID name the two peers for relay node routing
	// (site resolution); either empty skips nodes. a is the initiator's
	// address and b the target's, unless targetIsA.
	initiatorID, targetID string
	targetIsA             bool
	// relayHint is the relay a peer already dials (a target's
	// RelayResponse): the route is that relay's node when it is one.
	relayHint string
	// noNodes skips relay nodes (the fallback after a node failed).
	noNodes bool
	// fwdA and fwdB are the relay nodes a and b came through, "" for a
	// peer that reaches this server directly; chooseRelay fills them.
	fwdA, fwdB string
}

// chooseRelay picks the relay of a session. Every place that names a relay
// to a peer for a session gets it from here, so a new kind of relay (a pod
// of a cluster, a relay node at a site) is added in one spot.
func (s *Server) chooseRelay(req relayRouteRequest) RelayRoute {
	addr, sameNetwork, hairpin := s.selectPeerRelayServer(req.base, req.a, req.b)
	req.fwdA, req.fwdB = s.forwardNodeUDP(req.a), s.forwardNodeUDP(req.b)
	forwarded := req.fwdA != "" || req.fwdB != ""
	if forwarded {
		// Only peers behind one node share a network: two sites with the
		// same private range are not one LAN, and no NAT is shared
		sameNetwork = req.fwdA == req.fwdB && isSameNetwork(req.a, req.b, s.lanNet)
		hairpin = false
	}
	if len(req.policyPeers) > 0 {
		addr = s.applyNetworkRelayPolicy(addr, req.policyPeers...)
	}
	route := RelayRoute{
		Addr:        addr,
		TargetAddr:  addr,
		Tickets:     s.ticketStore(),
		Via:         viaCentral,
		SameNetwork: sameNetwork,
		Hairpin:     hairpin,
		Forwarded:   forwarded,
		ForceRelay:  forwarded && !sameNetwork,
	}
	if sameNetwork && addr != req.base {
		route.Via = viaLAN
	}
	if req.target != nil {
		route.TargetAddr = relayAdvertisedToTarget(req.target, addr)
	}
	// A relay node at the peers' site replaces the server's relay; the
	// target gets the node address as it is (its RequestRelay dials what
	// it is given), not relayAdvertisedToTarget
	if node, ok := s.nodeRoute(req); ok {
		route.Addr, route.TargetAddr = node.Addr, node.TargetAddr
		route.Tickets, route.Via = node.Tickets, node.Via
		route.nodeFallback = node.Fallback
	} else if forwarded {
		// The central relay is out of a forwarded peer's reach
		route.Blocked = true
	}
	return route
}

// SetTickets sets the ticket store signal issues relay tickets on instead
// of the in-process one (relay.DefaultTickets). The relay must claim from
// the same store.
func (s *Server) SetTickets(t relay.Tickets) {
	if t != nil {
		s.tickets = t
	}
}

// ticketStore is the store tickets are issued on and looked up in.
func (s *Server) ticketStore() relay.Tickets {
	if s.tickets == nil {
		return relay.DefaultTickets()
	}
	return s.tickets
}

// punchTargetAddr is the relay the PunchHole to the target names: the
// target's own node on a relay node route (two sites have two nodes),
// otherwise the initiator's relay as before.
func (r RelayRoute) punchTargetAddr() string {
	if isNodeVia(r.Via) {
		return r.TargetAddr
	}
	return r.Addr
}
