package signal

import (
	"errors"
	"log"
	"net"
	"strings"
	"sync"

	"github.com/neodeskapp/neodesk/neodesk-server/relay"
)

// NodeRelay is a relay node route for one session: what each peer dials,
// the node's ticket store and the Via value ("node:<id>", or
// "nodes:<a>,<b>" for two nodes).
type NodeRelay struct {
	Addr       string
	TargetAddr string
	Tickets    relay.Tickets
	Via        string
	// Fallback is the one-node route of a route over two nodes, used
	// when the two nodes can't take the tickets in time; nil for none.
	Fallback *NodeRelay
}

// SiteRouter finds relay node routes. NodeRoute is asked for every
// session; NodeForAddr maps a relay address the target already dials (the
// RelayResponse it sends after a punch hole) back to its node, and only
// to a node that may relay this pair.
type SiteRouter interface {
	NodeRoute(initiatorID string, initiatorIP net.IP, targetID string, targetIP net.IP) (NodeRelay, bool)
	NodeForAddr(addr, initiatorID string, initiatorIP net.IP, targetID string, targetIP net.IP) (NodeRelay, bool)
}

// ForwardRouter is optional on SiteRouter: the route of a session in
// which a peer reaches this server only through a relay node.
// initiatorNode and targetNode name the node each peer came through, ""
// for a peer that reaches the server directly. Only those nodes may
// carry a forwarded peer; ok false means there is no route it can use.
type ForwardRouter interface {
	ForwardedNodeRoute(initiatorID string, initiatorIP net.IP, initiatorNode, targetID string, targetIP net.IP, targetNode string) (NodeRelay, bool)
}

// SetSiteRouter turns relay node routing on; nil turns it off.
func (s *Server) SetSiteRouter(r SiteRouter) {
	s.siteMu.Lock()
	s.siteRouter = r
	s.siteMu.Unlock()
}

func (s *Server) sites() SiteRouter {
	s.siteMu.RLock()
	defer s.siteMu.RUnlock()
	return s.siteRouter
}

// nodeRoute is the relay node route for req, if any. The org network
// policy wins: a node whose address allowed_relay_servers excludes is
// not used.
func (s *Server) nodeRoute(req relayRouteRequest) (NodeRelay, bool) {
	router := s.sites()
	if router == nil || req.noNodes {
		return NodeRelay{}, false
	}
	if req.relayHint != "" {
		return s.hintedNodeRoute(router, req)
	}
	route, ok := s.fullNodeRoute(router, req)
	if !ok {
		return NodeRelay{}, false
	}
	return route, true
}

// fullNodeRoute asks the router for the route between the two peers and
// applies the org network policy to it and its fallback.
func (s *Server) fullNodeRoute(router SiteRouter, req relayRouteRequest) (NodeRelay, bool) {
	initiatorIP, targetIP, ok := req.peerIPs()
	if !ok {
		return NodeRelay{}, false
	}
	var route NodeRelay
	if req.fwdA != "" || req.fwdB != "" {
		initiatorNode, targetNode := req.fwdA, req.fwdB
		if req.targetIsA {
			initiatorNode, targetNode = req.fwdB, req.fwdA
		}
		fr, can := router.(ForwardRouter)
		if !can {
			return NodeRelay{}, false
		}
		route, ok = fr.ForwardedNodeRoute(req.initiatorID, initiatorIP, initiatorNode, req.targetID, targetIP, targetNode)
		if !ok {
			log.Printf("[signal] no relay node route for %s -> %s, which come through relay nodes %q and %q: refusing the relay",
				req.initiatorID, req.targetID, initiatorNode, targetNode)
		}
	} else {
		route, ok = router.NodeRoute(req.initiatorID, initiatorIP, req.targetID, targetIP)
	}
	if !ok {
		return NodeRelay{}, false
	}
	if route.Fallback != nil && !s.nodeAllowed(*route.Fallback, req) {
		route.Fallback = nil
	}
	if !s.nodeAllowed(route, req) {
		if route.Fallback == nil {
			return NodeRelay{}, false
		}
		route = *route.Fallback
	}
	return route, true
}

// peerIPs are the initiator's and the target's addresses; false when a
// peer id or address is missing.
func (req relayRouteRequest) peerIPs() (initiatorIP, targetIP net.IP, ok bool) {
	if req.initiatorID == "" || req.targetID == "" {
		return nil, nil, false
	}
	initiatorAddr, targetAddr := req.a, req.b
	if req.targetIsA {
		initiatorAddr, targetAddr = req.b, req.a
	}
	if initiatorAddr == nil || targetAddr == nil {
		return nil, nil, false
	}
	return initiatorAddr.IP, targetAddr.IP, true
}

// nodeAllowed applies the org network policy to a node route: a node
// whose address allowed_relay_servers excludes is not used.
func (s *Server) nodeAllowed(r NodeRelay, req relayRouteRequest) bool {
	peers := []string{req.initiatorID, req.targetID}
	for _, addr := range []string{r.Addr, r.TargetAddr} {
		if s.applyNetworkRelayPolicy(addr, peers...) != addr {
			log.Printf("[signal] relay node %s excluded by allowed_relay_servers for %s -> %s", addr, req.initiatorID, req.targetID)
			return false
		}
	}
	return true
}

// hintedNode is the node the target already dials at req.relayHint, when
// the router says that node may relay this pair and the policy allows it.
func (s *Server) hintedNode(router SiteRouter, req relayRouteRequest) (NodeRelay, bool) {
	initiatorIP, targetIP, ok := req.peerIPs()
	if !ok {
		return NodeRelay{}, false
	}
	node, ok := router.NodeForAddr(req.relayHint, req.initiatorID, initiatorIP, req.targetID, targetIP)
	if !ok || !s.nodeAllowed(node, req) {
		return NodeRelay{}, false
	}
	return node, true
}

// hintedNodeRoute is the route of a session whose target already dials
// req.relayHint (its RelayResponse after a punch hole). When the peers'
// route over two nodes gives the target that very node, the session runs
// over both nodes, with the hinted node alone as the fallback; otherwise
// it is the hinted node alone, as before.
func (s *Server) hintedNodeRoute(router SiteRouter, req relayRouteRequest) (NodeRelay, bool) {
	single, singleOK := s.hintedNode(router, req)
	route, ok := s.fullNodeRoute(router, req)
	if ok && route.Fallback != nil && strings.EqualFold(route.TargetAddr, req.relayHint) {
		if singleOK {
			route.Fallback = &single
		} else {
			route.Fallback = nil
		}
		return route, true
	}
	return single, singleOK
}

// admitRoute is admitSession on the route's ticket store. When a relay
// node can't take the ticket in time, the session moves to the central
// relay: route is replaced by the route without nodes and the ticket is
// issued there, so a session never fails only because a node is down.
//
// A route over two nodes falls back to its one-node route first. A session
// whose target dials a node already (relayHint) never moves to the
// central relay.
func (s *Server) admitRoute(route *RelayRoute, req relayRouteRequest, relayUUID, initiatorID, targetID string, account int64, consoleSession string) string {
	if route.Blocked {
		log.Printf("[signal] relay for uuid=%s refused: %s -> %s has a peer behind a relay node and no node route",
			relayUUIDShort(relayUUID), initiatorID, targetID)
		return refuseRelayUnavailable
	}
	refuse := s.admitSessionErr(route.Tickets, relayUUID, initiatorID, targetID, account, consoleSession)
	if refuse.err != nil && errors.Is(refuse.err, relay.ErrTicketsUnavailable) && route.nodeFallback != nil {
		fb := *route.nodeFallback
		log.Printf("[signal] relay nodes %s unavailable for uuid=%s: %v; falling back to %s",
			route.Via, relayUUIDShort(relayUUID), refuse.err, fb.Via)
		route.Addr, route.TargetAddr, route.Tickets, route.Via = fb.Addr, fb.TargetAddr, fb.Tickets, fb.Via
		route.nodeFallback = nil
		refuse = s.admitSessionErr(route.Tickets, relayUUID, initiatorID, targetID, account, consoleSession)
	}
	if refuse.err != nil && errors.Is(refuse.err, relay.ErrTicketsUnavailable) && isNodeVia(route.Via) && req.relayHint == "" {
		log.Printf("[signal] relay node unavailable for uuid=%s (%s): %v; falling back to the central relay",
			relayUUIDShort(relayUUID), route.Via, refuse.err)
		req.noNodes = true
		*route = s.chooseRelay(req)
		if route.Blocked {
			log.Printf("[signal] relay for uuid=%s refused: a peer behind a relay node can't use the central relay", relayUUIDShort(relayUUID))
			return refuseRelayUnavailable
		}
		refuse = s.admitSessionErr(route.Tickets, relayUUID, initiatorID, targetID, account, consoleSession)
	}
	if refuse.reason == "" && relayUUID != "" {
		s.noteRelayVia(relayUUID, route.Via)
	}
	return refuse.reason
}

func isNodeVia(via string) bool {
	return len(via) > 5 && (via[:5] == "node:" || (len(via) > 6 && via[:6] == "nodes:"))
}

// relayVia remembers how each admitted relay session travels, for the
// session record and live sessions.
var relayVia sync.Map // uuid -> via

func (s *Server) noteRelayVia(uuid, via string) {
	relayVia.Store(uuid, via)
	if s.db != nil {
		if err := s.db.SetConnectionSessionRelayVia(uuid, via); err != nil {
			log.Printf("[signal] relay via not recorded for uuid=%s: %v", relayUUIDShort(uuid), err)
		}
	}
}

// RelayVia is how the relay session uuid travels ("central", "lan",
// "node:<id>", ...), "" when signal did not admit it.
func RelayVia(uuid string) string {
	if v, ok := relayVia.Load(uuid); ok {
		return v.(string)
	}
	return ""
}

// ForgetRelayVia drops the entry of an ended session.
func ForgetRelayVia(uuid string) { relayVia.Delete(uuid) }

// IsOwnRelay reports whether addr is one of the relay addresses this
// server hands out.
func (s *Server) IsOwnRelay(addr string) bool {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return false
	}
	if strings.EqualFold(addr, s.getRelayServer()) {
		return true
	}
	for _, r := range s.cfg.GetRelayServers() {
		if strings.EqualFold(addr, strings.TrimSpace(r)) {
			return true
		}
	}
	return false
}
