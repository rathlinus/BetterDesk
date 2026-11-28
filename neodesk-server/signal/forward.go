package signal

import (
	"context"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/peer"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"google.golang.org/protobuf/proto"
)

// Forwarding (phase 3, D17/D18 in the sites decisions): a relay node at a
// site without internet access forwards the signal, NAT test, WebSocket
// signal and API ports of the computers there. The node hub hands each
// forwarded TCP stream to ServeForwardedTCP as a connection whose
// RemoteAddr is the computer's own address, and the node's datagrams to
// ServeForwardedUDP. Signal remembers per ip:port which node a computer
// came through: answers to it go back through that node, and its
// sessions are relayed by that node only.

// Services of ServeForwardedTCP, as the node names them.
const (
	ForwardSignal = "signal"
	ForwardNAT    = "nat"
	ForwardWS     = "ws"
	ForwardAPI    = "api"
)

// forwardUDPTTL is how long an ip:port that came through a node over UDP
// keeps its node without another datagram.
const forwardUDPTTL = 5 * time.Minute

// PacketChannel is a node's UDP forwarding connection.
type PacketChannel interface {
	// ReadPacket returns the next datagram and the computer's address.
	ReadPacket() (*net.UDPAddr, []byte, error)
	// WritePacket sends a datagram to the computer at to.
	WritePacket(to *net.UDPAddr, data []byte) error
	Close() error
}

// forwards is which ip:port came through which node.
type forwards struct {
	mu  sync.Mutex
	udp map[string]udpForward // normalizeAddrKey -> node and channel
	tcp map[string]tcpForward // normalizeAddrKey -> node, open streams

	once  sync.Once
	ws    *forwardHTTP
	api   *forwardHTTP
	nowFn func() time.Time
}

type udpForward struct {
	node string
	ch   PacketChannel
	seen time.Time
}

type tcpForward struct {
	node string
	refs int
}

func (f *forwards) now() time.Time {
	if f.nowFn != nil {
		return f.nowFn()
	}
	return time.Now()
}

// forwardNode is the node addr came through, "" when it reaches this
// server directly.
func (s *Server) forwardNode(addr net.Addr) string {
	if s == nil || addr == nil {
		return ""
	}
	return s.forwardNodeKey(normalizeAddrKey(addr.String()))
}

func (s *Server) forwardNodeKey(key string) string {
	f := &s.fwd
	f.mu.Lock()
	defer f.mu.Unlock()
	if e, ok := f.udp[key]; ok && f.now().Sub(e.seen) < forwardUDPTTL {
		return e.node
	}
	if e, ok := f.tcp[key]; ok {
		return e.node
	}
	return ""
}

// forwardNodeUDP is forwardNode for a possibly nil *net.UDPAddr.
func (s *Server) forwardNodeUDP(addr *net.UDPAddr) string {
	if addr == nil {
		return ""
	}
	return s.forwardNode(addr)
}

// PeerForwardNode is the relay node the peer reaches this server
// through, "" when it reaches it directly or is not here.
func (s *Server) PeerForwardNode(id string) string {
	e := s.peers.GetLocal(id)
	if e == nil {
		return ""
	}
	return s.forwardNodeKey(normalizeAddrKey(e.IP))
}

// ForwardedPeers counts the peers that reach this server through the
// node now.
func (s *Server) ForwardedPeers(nodeID string) int {
	n := 0
	s.peers.ForEach(func(e *peer.Entry) {
		if e.Owner == "" && s.forwardNodeKey(normalizeAddrKey(e.IP)) == nodeID {
			n++
		}
	})
	return n
}

// trackTCPForward records an open forwarded stream of key; the returned
// function forgets it.
func (s *Server) trackTCPForward(key, node string) func() {
	f := &s.fwd
	f.mu.Lock()
	if f.tcp == nil {
		f.tcp = make(map[string]tcpForward)
	}
	e := f.tcp[key]
	e.node, e.refs = node, e.refs+1
	f.tcp[key] = e
	f.mu.Unlock()
	return func() {
		f.mu.Lock()
		if e, ok := f.tcp[key]; ok {
			e.refs--
			if e.refs <= 0 {
				delete(f.tcp, key)
			} else {
				f.tcp[key] = e
			}
		}
		f.mu.Unlock()
	}
}

// ServeForwardedTCP serves one stream a relay node forwarded for a
// computer at its site; c's RemoteAddr is the computer's address. It
// returns when the stream is over and closes c.
func (s *Server) ServeForwardedTCP(nodeID, service string, c net.Conn) {
	remote := c.RemoteAddr().String()
	key := normalizeAddrKey(remote)
	defer s.trackTCPForward(key, nodeID)()
	host := hostFromAddrString(remote)
	switch service {
	case ForwardSignal:
		if s.limiter != nil && !s.allowSignalConnection(host) {
			c.Close()
			return
		}
		s.recoverMessagePanic("TCP", remote, func() { s.handleTCPConn(c) })
	case ForwardNAT:
		if !s.natConns.acquire(host) {
			c.Close()
			return
		}
		defer s.natConns.release(host)
		s.recoverMessagePanic("NAT", remote, func() { s.handleNATConn(c) })
	case ForwardWS, ForwardAPI:
		s.fwd.once.Do(s.startForwardHTTP)
		h := s.fwd.ws
		if service == ForwardAPI {
			h = s.fwd.api
		}
		h.serve(s.baseContext(), c)
	default:
		c.Close()
	}
}

// ServeForwardedUDP serves a node's UDP forwarding connection until it
// fails: each datagram is handled as if it came to the UDP port from the
// computer's address, and answers to that address go back through ch.
func (s *Server) ServeForwardedUDP(nodeID string, ch PacketChannel) {
	defer s.dropUDPForwards(ch)
	for {
		from, data, err := ch.ReadPacket()
		if err != nil {
			return
		}
		key := normalizeAddrKey(from.String())
		f := &s.fwd
		f.mu.Lock()
		if f.udp == nil {
			f.udp = make(map[string]udpForward)
		}
		prev, had := f.udp[key]
		now := f.now()
		if !had || now.Sub(prev.seen) >= time.Minute || prev.ch != ch {
			for k, e := range f.udp { // sweep, at most once a minute per address
				if now.Sub(e.seen) >= forwardUDPTTL {
					delete(f.udp, k)
				}
			}
		}
		f.udp[key] = udpForward{node: nodeID, ch: ch, seen: now}
		f.mu.Unlock()
		if had && prev.node != nodeID {
			log.Printf("[signal] %s now comes through relay node %s (was %s)", key, nodeID, prev.node)
		}

		msg := &pb.RendezvousMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			continue
		}
		s.recoverMessagePanic("UDP", from.String(), func() { s.handleUDPMessage(msg, from) })
	}
}

func (s *Server) dropUDPForwards(ch PacketChannel) {
	f := &s.fwd
	f.mu.Lock()
	for k, e := range f.udp {
		if e.ch == ch {
			delete(f.udp, k)
		}
	}
	f.mu.Unlock()
}

// sendForwardedUDP sends data to addr through the node it came through;
// handled is false when addr did not come through a node.
func (s *Server) sendForwardedUDP(data []byte, addr *net.UDPAddr) (handled, ok bool) {
	key := normalizeAddrKey(addr.String())
	f := &s.fwd
	f.mu.Lock()
	e, found := f.udp[key]
	f.mu.Unlock()
	if !found || f.now().Sub(e.seen) >= forwardUDPTTL {
		return false, false
	}
	if err := e.ch.WritePacket(addr, data); err != nil {
		log.Printf("[signal] UDP send to %s through relay node %s: %v", addr, e.node, err)
		return true, false
	}
	return true, true
}

// marshalForUDP is the wire form of msg for sendUDPLocal.
func marshalForUDP(msg *pb.RendezvousMessage) ([]byte, bool) {
	data, err := proto.Marshal(msg)
	if err != nil {
		log.Printf("[signal] marshal error: %v", err)
		return nil, false
	}
	return data, true
}

// ---- WebSocket signal and API streams ----

// forwardedHeaders are the request headers that name another client
// address. A forwarded stream's address is the one the node vouched for,
// so they are dropped whatever TRUSTED_PROXIES says.
var forwardedHeaders = []string{"Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Forwarded-Port", "X-Real-Ip"}

func stripForwardedHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, name := range forwardedHeaders {
			r.Header.Del(name)
		}
		h.ServeHTTP(w, r)
	})
}

// forwardHTTP is an HTTP server fed with forwarded streams.
type forwardHTTP struct {
	srv *http.Server
	ln  *connListener
}

func (s *Server) startForwardHTTP() {
	wsMux := http.NewServeMux()
	wsMux.HandleFunc("/", s.handleWSUpgrade)
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := s.apiProxy.Load()
		if h == nil {
			http.Error(w, "the API is not available", http.StatusServiceUnavailable)
			return
		}
		(*h).ServeHTTP(w, r)
	})
	s.fwd.ws = newForwardHTTP(s, stripForwardedHeaders(wsMux))
	s.fwd.api = newForwardHTTP(s, stripForwardedHeaders(api))
}

func newForwardHTTP(s *Server, h http.Handler) *forwardHTTP {
	f := &forwardHTTP{ln: newConnListener()}
	f.srv = &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return s.baseContext() },
	}
	go func() { _ = f.srv.Serve(f.ln) }()
	return f
}

// serve hands c to the server and waits until the server closed it.
func (f *forwardHTTP) serve(ctx context.Context, c net.Conn) {
	nc := &notifyConn{Conn: c, done: make(chan struct{})}
	if !f.ln.push(nc) {
		c.Close()
		return
	}
	select {
	case <-nc.done:
	case <-ctx.Done():
		c.Close()
	}
}

func (f *forwardHTTP) close() {
	f.ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = f.srv.Shutdown(ctx)
}

// stopForwards closes the HTTP servers of forwarded streams.
func (s *Server) stopForwards() {
	if s.fwd.ws != nil {
		s.fwd.ws.close()
	}
	if s.fwd.api != nil {
		s.fwd.api.close()
	}
}

// notifyConn closes done when it is closed.
type notifyConn struct {
	net.Conn
	once sync.Once
	done chan struct{}
}

func (c *notifyConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() { close(c.done) })
	return err
}

// connListener is a net.Listener whose connections are pushed to it.
type connListener struct {
	ch   chan net.Conn
	done chan struct{}
	once sync.Once
}

func newConnListener() *connListener {
	return &connListener{ch: make(chan net.Conn), done: make(chan struct{})}
}

func (l *connListener) push(c net.Conn) bool {
	select {
	case l.ch <- c:
		return true
	case <-l.done:
		return false
	}
}

func (l *connListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.ch:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *connListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *connListener) Addr() net.Addr { return &net.TCPAddr{} }
