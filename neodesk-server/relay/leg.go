package relay

import (
	"log"
	"net"
)

// ServeClaimed pairs conn as one side of the session uuid, like a native
// connection that arrived on the relay port and sent RequestRelay. The
// caller has claimed the side on the relay's ticket store already: a relay
// node joins the leg to or from another node this way. It returns when
// the session ends; callers run it in a goroutine.
func (s *Server) ServeClaimed(conn net.Conn, uuid string) {
	if uuid == "" {
		conn.Close()
		return
	}
	log.Printf("[relay] Leg %s for UUID %s", conn.RemoteAddr(), relayUUIDLogID(uuid))
	s.pairIncomingConn(&pendingConn{
		conn:      conn,
		remote:    conn.RemoteAddr().String(),
		transport: relayTransportTCP,
		created:   timeNow(),
		done:      make(chan struct{}),
	}, uuid)
}

// DropPending closes the connection waiting for its partner under uuid
// and returns its claim, so a peer whose other side can't come (the leg
// to the other node failed) hears it at once instead of after the pair
// timeout. It reports whether one was waiting.
func (s *Server) DropPending(uuid string) bool {
	val, ok := s.pending.LoadAndDelete(uuid)
	if !ok {
		return false
	}
	pc := val.(*pendingConn)
	s.authorizations.Release(uuid)
	pc.close()
	pc.markDone()
	log.Printf("[relay] Dropped the waiting side of UUID %s", relayUUIDLogID(uuid))
	return true
}
