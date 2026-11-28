package sites

import (
	"log"
	"net"

	"github.com/neodeskapp/neodesk/neodesk-server/db"
)

// RouteForwarded is Route for a connection in which one or both peers
// reach the server only through a relay node (phase 3 forwarding).
// initiatorNode and targetNode name the node each peer came through, ""
// for a peer that reaches the server directly. A forwarded peer reaches
// nothing but its node, on the node's LAN, so (D18):
//
//   - the other peer at the forwarding node's site (also forwarded by
//     another node there): Same on the forwarding node;
//   - both forwarded by nodes of two sites: Pair of those two nodes, no
//     fallback;
//   - the other peer at another site with online nodes: Pair of the
//     forwarding node and that site's nodes, with the forwarding node
//     alone as the fallback when the other peer's address is public;
//   - the other peer at no site or a site without online nodes: Same on
//     the forwarding node when the other peer's address is public;
//   - anything else, a forwarding node that is offline, revoked or of
//     another organization, and peers of two organizations: None.
//
// The site of a forwarded peer is its node's site, and it always dials
// the node's LAN address.
func (s *Service) RouteForwarded(initiatorID string, initiatorAddr net.IP, initiatorNode, targetID string, targetAddr net.IP, targetNode string) NodeRoute {
	if initiatorID == "" || targetID == "" || (initiatorNode == "" && targetNode == "") {
		return NodeRoute{}
	}
	snap := s.snapshot()
	if snap == nil {
		return NodeRoute{}
	}
	iOrg, ok1 := s.orgOf(initiatorID)
	tOrg, ok2 := s.orgOf(targetID)
	if !ok1 || !ok2 || iOrg != tOrg {
		return NodeRoute{}
	}
	s.mu.Lock()
	live := s.liveness
	s.mu.Unlock()
	if live == nil {
		return NodeRoute{}
	}
	x, xok := forwardingNode(snap, live, initiatorNode, iOrg, initiatorID)
	y, yok := forwardingNode(snap, live, targetNode, tOrg, targetID)
	if !xok || !yok {
		return NodeRoute{}
	}
	iSite, iInside, iPrivate := s.forwardedSite(snap, x, initiatorID, iOrg, initiatorAddr)
	tSite, tInside, tPrivate := s.forwardedSite(snap, y, targetID, tOrg, targetAddr)

	if iSite != nil && tSite != nil && iSite.ID == tSite.ID {
		n := x
		if n == nil {
			n = y
		}
		ia, ta := sameSiteAddr(n, iInside), sameSiteAddr(n, tInside)
		if ia == "" || ta == "" {
			return NodeRoute{}
		}
		return NodeRoute{Kind: Same, A: n, InitiatorAddr: ia, TargetAddr: ta}
	}
	if x != nil && y != nil {
		return pairOver(snap, live, iSite, tSite, []*db.RelayNode{x}, []*db.RelayNode{y}, iInside, tInside, NodeRoute{})
	}
	if x != nil {
		single := singleNode([]*db.RelayNode{x}, nil, live, iSite.ID, idOf(tSite), iInside, tInside, iPrivate, tPrivate)
		if tSite == nil {
			return single
		}
		bs := onlineNodes(snap, live, tSite.ID)
		if len(bs) == 0 {
			return single
		}
		return pairOver(snap, live, iSite, tSite, []*db.RelayNode{x}, bs, iInside, tInside, single)
	}
	single := singleNode([]*db.RelayNode{y}, nil, live, idOf(iSite), tSite.ID, iInside, tInside, iPrivate, tPrivate)
	if iSite == nil {
		return single
	}
	as := onlineNodes(snap, live, iSite.ID)
	if len(as) == 0 {
		return single
	}
	return pairOver(snap, live, iSite, tSite, as, []*db.RelayNode{y}, iInside, tInside, single)
}

func idOf(s *db.Site) string {
	if s == nil {
		return ""
	}
	return s.ID
}

// forwardingNode is a copy of the node a peer of org came through; nil
// and true for a peer that reaches the server directly (nodeID ""),
// false when the node can't carry it: unknown, revoked, offline, or at a
// site of another organization.
func forwardingNode(snap *snapshot, live NodeLiveness, nodeID, org, deviceID string) (*db.RelayNode, bool) {
	if nodeID == "" {
		return nil, true
	}
	for siteID, nodes := range snap.nodes {
		for _, n := range nodes {
			if n.ID != nodeID {
				continue
			}
			if site := snap.sites[siteID]; site == nil || site.OrgID != org {
				log.Printf("[sites] %s comes through relay node %s of another organization; no route", deviceID, nodeID)
				return nil, false
			}
			if !live.Online(n.ID) {
				return nil, false
			}
			c := n
			return &c, true
		}
	}
	return nil, false
}

// forwardedSite is the site of a peer, whether it dials the LAN address
// of nodes at its site and whether its address is private: a forwarded
// peer's node's site and its LAN, else the site its pins or address give
// and whether the peer is inside that site.
func (s *Service) forwardedSite(snap *snapshot, node *db.RelayNode, deviceID, org string, addr net.IP) (site *db.Site, inside, private bool) {
	if node != nil {
		return snap.sites[node.SiteID], true, true
	}
	site = s.resolve(snap, deviceID, org, addr)
	if site != nil {
		inside = insideSite(snap, site.ID, addr)
	}
	return site, inside, IsPrivate(addr)
}
