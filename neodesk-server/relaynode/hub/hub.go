package hub

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Defaults of Config's timings.
const (
	DefaultPingInterval    = 15 * time.Second
	DefaultIdleTimeout     = 45 * time.Second
	DefaultAuthorizeBudget = 1500 * time.Millisecond
	DefaultEnrollPerMinute = 10
	DefaultAuditInterval   = 5 * time.Minute

	handshakeTimeout = 10 * time.Second
	writeTimeout     = 10 * time.Second
	closeTimeout     = 2 * time.Second
	// liveMaxAge is how long a session the node never reported ended is kept
	liveMaxAge = 7 * 24 * time.Hour
)

// Config sets up a Hub.
type Config struct {
	Addr     string          // listen address, ":21123"
	Cert     tls.Certificate // LoadOrCreateCert
	ServerPK string          // the server's public key (id_ed25519.pub), for welcome
	Store    Store
	Events   Events                           // optional
	Audit    Auditor                          // optional
	Logf     func(format string, args ...any) // log.Printf when nil

	PingInterval    time.Duration // DefaultPingInterval when 0
	IdleTimeout     time.Duration // DefaultIdleTimeout when 0
	AuthorizeBudget time.Duration // DefaultAuthorizeBudget when 0
	EnrollPerMinute int           // per remote IP; DefaultEnrollPerMinute when 0
	AuditInterval   time.Duration // DefaultAuditInterval when 0
	Now             func() time.Time
}

// Hub accepts relay node connections and keeps the connected ones.
type Hub struct {
	cfg    Config
	tls    *tls.Config
	ln     net.Listener
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
	nextID atomic.Uint64

	mu       sync.Mutex
	nodes    map[string]*nodeState
	sessions map[string]string // ticket uuid -> node id
	enroll   map[string]*window
}

type nodeState struct {
	id     string
	siteID string
	conn   *nodeConn // nil while offline
	active int
	// up and down are the bytes the node relayed since it started, from
	// its last stats
	up, down int64
	tickets  map[string]*ticket
	counts   ticketCounts
	legs     legTotals
}

type ticket struct {
	initiator string
	target    string
	account   int64
	session   string
	expires   time.Time
	live      bool
	since     time.Time
	// leg is the node's role in a session over two nodes ("" for one
	// node): the dialing node's started and ended don't reach Events,
	// the accepting node's do
	leg string
}

type ticketCounts struct {
	pushed, ok, rejected, unavailable int
	// legs from other nodes since the last audit: accepted, refused by
	// reason
	legsAccepted int64
	legsRefused  map[string]int64
}

// legTotals are the leg counts of the node's last stats.
type legTotals struct {
	accepted int64
	refused  map[string]int64
}

type window struct {
	start time.Time
	count int
}

// New makes a hub; Start listens.
func New(cfg Config) (*Hub, error) {
	if cfg.Store == nil {
		return nil, errors.New("hub: no store")
	}
	if len(cfg.Cert.Certificate) == 0 {
		return nil, errors.New("hub: no certificate")
	}
	if cfg.Logf == nil {
		cfg.Logf = log.Printf
	}
	if cfg.PingInterval <= 0 {
		cfg.PingInterval = DefaultPingInterval
	}
	if cfg.IdleTimeout <= 0 {
		cfg.IdleTimeout = DefaultIdleTimeout
	}
	if cfg.AuthorizeBudget <= 0 {
		cfg.AuthorizeBudget = DefaultAuthorizeBudget
	}
	if cfg.EnrollPerMinute <= 0 {
		cfg.EnrollPerMinute = DefaultEnrollPerMinute
	}
	if cfg.AuditInterval <= 0 {
		cfg.AuditInterval = DefaultAuditInterval
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &Hub{
		cfg:      cfg,
		tls:      wire.ServerTLS(cfg.Cert),
		nodes:    make(map[string]*nodeState),
		sessions: make(map[string]string),
		enroll:   make(map[string]*window),
	}, nil
}

// Start opens the listener and serves until ctx ends or Stop.
func (h *Hub) Start(ctx context.Context) error {
	ln, err := net.Listen("tcp", h.cfg.Addr)
	if err != nil {
		return fmt.Errorf("relay node control: listen %s: %w", h.cfg.Addr, err)
	}
	h.ln = ln
	h.ctx, h.cancel = context.WithCancel(ctx)
	h.wg.Add(2)
	go h.accept()
	go h.auditLoop()
	go func() {
		<-h.ctx.Done()
		ln.Close()
	}()
	h.cfg.Logf("[nodes] Control listener on %s (TLS 1.3, pinned)", ln.Addr())
	return nil
}

// Addr is the listener's address.
func (h *Hub) Addr() net.Addr {
	if h.ln == nil {
		return nil
	}
	return h.ln.Addr()
}

// Stop closes the listener and every node connection.
func (h *Hub) Stop() {
	if h.cancel == nil {
		return
	}
	h.cancel()
	h.mu.Lock()
	var conns []*nodeConn
	for _, n := range h.nodes {
		if n.conn != nil {
			conns = append(conns, n.conn)
		}
	}
	h.mu.Unlock()
	for _, c := range conns {
		c.close()
	}
	h.wg.Wait()
	h.flushAudit()
}

func (h *Hub) accept() {
	defer h.wg.Done()
	for {
		c, err := h.ln.Accept()
		if err != nil {
			if h.ctx.Err() != nil {
				return
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			h.cfg.Logf("[nodes] accept: %v", err)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			h.serve(c)
		}()
	}
}

func (h *Hub) audit(event string, fields map[string]string) {
	if h.cfg.Audit != nil {
		h.cfg.Audit.Audit(event, fields)
	}
}

func remoteIP(c net.Conn) string {
	host, _, err := net.SplitHostPort(c.RemoteAddr().String())
	if err != nil {
		return c.RemoteAddr().String()
	}
	return host
}

// serve runs one connection: handshake, hello, welcome, then messages.
func (h *Hub) serve(raw net.Conn) {
	ip := remoteIP(raw)
	tc := tls.Server(raw, h.tls)
	_ = tc.SetDeadline(time.Now().Add(handshakeTimeout))
	if err := tc.HandshakeContext(h.ctx); err != nil {
		h.cfg.Logf("[nodes] TLS handshake from %s failed: %v", ip, err)
		tc.Close()
		return
	}
	_ = tc.SetDeadline(time.Time{})
	key, err := wire.PeerKey(tc.ConnectionState())
	if err != nil {
		tc.Close()
		return
	}
	c := wire.NewConn(tc)
	f, err := c.Read(handshakeTimeout)
	if err != nil || f.Type != wire.TypeHello {
		h.refuse(c, ip, "", wire.CodeBadHello, "the first frame must be hello")
		return
	}
	var hello wire.Hello
	if err := f.Decode(&hello); err != nil {
		h.refuse(c, ip, "", wire.CodeBadHello, "hello does not decode")
		return
	}
	node, site, code, msg := h.authenticate(ip, wire.PublicKeyBase64(key), hello)
	if code != "" {
		h.refuse(c, ip, hello.NodeID, code, msg)
		return
	}
	if err := c.Write(wire.Welcome{NodeID: node.ID, SiteID: site.ID, OrgID: site.OrgID, Name: node.Name, ServerPK: h.cfg.ServerPK}, writeTimeout); err != nil {
		c.Close()
		return
	}
	if err := h.cfg.Store.UpdateRelayNodeState(node.ID, hello.Version, hello.LanAddr, hello.PublicAddr, h.cfg.Now()); err != nil {
		h.cfg.Logf("[nodes] node %s: save state: %v", node.ID, err)
	}
	nc := &nodeConn{h: h, nodeID: node.ID, c: c, ip: ip, hello: hello, acks: make(map[uint64]chan wire.Ack), done: make(chan struct{})}
	h.register(nc, node.SiteID)
	h.cfg.Logf("[nodes] Node %s (%s) connected from %s, version %s", node.ID, node.Name, ip, hello.Version)
	nc.run()
	h.unregister(nc)
	h.cfg.Logf("[nodes] Node %s disconnected", node.ID)
}

func (h *Hub) refuse(c *wire.Conn, ip, nodeID, code, msg string) {
	h.cfg.Logf("[nodes] Refused node connection from %s: %s (%s)", ip, code, msg)
	if code != wire.CodeBadHello && code != wire.CodeInternal {
		fields := map[string]string{"remote": ip, "code": code}
		if nodeID != "" {
			fields["node_id"] = nodeID
		}
		h.audit("relay_node.auth_failed", fields)
	}
	_ = c.Write(wire.Error{Code: code, Msg: msg}, closeTimeout)
	c.Close()
}

// authenticate finds or enrolls the node of the client key. code is the
// refusal, "" when the node may connect.
func (h *Hub) authenticate(ip, key string, hello wire.Hello) (node *Node, site *Site, code, msg string) {
	st := h.cfg.Store
	existing, err := st.GetRelayNodeByKey(key)
	if err != nil {
		h.cfg.Logf("[nodes] look up node key: %v", err)
		return nil, nil, wire.CodeInternal, "node lookup failed"
	}
	// A known key that still sends a token is a node whose welcome got
	// lost after it enrolled: the key proves it, the token is not used again
	if existing == nil && hello.Token != "" {
		return h.enrollNode(ip, key, hello)
	}
	if existing == nil {
		return nil, nil, wire.CodeUnknownNode, "this node is not enrolled; join it with a new enrollment string"
	}
	if hello.NodeID != "" && hello.NodeID != existing.ID {
		return nil, nil, wire.CodeMismatch, "node id does not match the client key"
	}
	if existing.Revoked {
		return nil, nil, wire.CodeRevoked, "this node was revoked"
	}
	site, err = st.GetSite(existing.SiteID)
	if err != nil {
		h.cfg.Logf("[nodes] look up site %s: %v", existing.SiteID, err)
		return nil, nil, wire.CodeInternal, "site lookup failed"
	}
	if site == nil {
		return nil, nil, wire.CodeSiteGone, "the node's site was deleted"
	}
	return existing, site, "", ""
}

func (h *Hub) enrollNode(ip, key string, hello wire.Hello) (*Node, *Site, string, string) {
	if !h.allowEnroll(ip) {
		return nil, nil, wire.CodeRateLimited, "too many enrollment attempts, try again in a minute"
	}
	now := h.cfg.Now()
	id := uuid.NewString()
	siteID, err := h.cfg.Store.ConsumeEnrollmentToken(hello.Token, id, now)
	if err != nil {
		return nil, nil, wire.CodeBadToken, "the enrollment token is unknown, used or expired"
	}
	site, err := h.cfg.Store.GetSite(siteID)
	if err != nil {
		h.cfg.Logf("[nodes] look up site %s: %v", siteID, err)
		return nil, nil, wire.CodeInternal, "site lookup failed"
	}
	if site == nil {
		return nil, nil, wire.CodeSiteGone, "the token's site was deleted"
	}
	n := &Node{
		ID: id, SiteID: siteID, Name: "node-" + id[:8], PublicKey: key,
		LanAddr: hello.LanAddr, PublicAddr: hello.PublicAddr, Version: hello.Version, CreatedAt: now,
	}
	if err := h.cfg.Store.CreateRelayNode(n); err != nil {
		h.cfg.Logf("[nodes] create node: %v", err)
		return nil, nil, wire.CodeInternal, "the node could not be saved"
	}
	h.audit("relay_node.enrolled", map[string]string{"node_id": id, "site_id": siteID, "remote": ip})
	h.cfg.Logf("[nodes] Enrolled node %s for site %s from %s", id, siteID, ip)
	return n, site, "", ""
}

// allowEnroll counts an enrollment attempt of ip; false past the limit.
func (h *Hub) allowEnroll(ip string) bool {
	now := h.cfg.Now()
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.enroll) > 4096 {
		for k, w := range h.enroll {
			if now.Sub(w.start) >= time.Minute {
				delete(h.enroll, k)
			}
		}
	}
	w := h.enroll[ip]
	if w == nil || now.Sub(w.start) >= time.Minute {
		w = &window{start: now}
		h.enroll[ip] = w
	}
	w.count++
	return w.count <= h.cfg.EnrollPerMinute
}

func (h *Hub) state(nodeID string) *nodeState {
	n := h.nodes[nodeID]
	if n == nil {
		n = &nodeState{id: nodeID, tickets: make(map[string]*ticket)}
		h.nodes[nodeID] = n
	}
	return n
}

func (h *Hub) register(nc *nodeConn, siteID string) {
	h.mu.Lock()
	n := h.state(nc.nodeID)
	old := n.conn
	n.conn = nc
	n.siteID = siteID
	h.mu.Unlock()
	if old != nil {
		go old.closeWith(wire.Error{Code: wire.CodeReplaced, Msg: "the node connected again"})
	}
	if ce, ok := h.cfg.Events.(ConnectEvents); ok {
		ce.NodeConnected(nc.nodeID)
	}
}

func (h *Hub) unregister(nc *nodeConn) {
	nc.close()
	h.mu.Lock()
	defer h.mu.Unlock()
	if n := h.nodes[nc.nodeID]; n != nil && n.conn == nc {
		n.conn = nil
	}
}

func (h *Hub) conn(nodeID string) *nodeConn {
	h.mu.Lock()
	defer h.mu.Unlock()
	if n := h.nodes[nodeID]; n != nil {
		return n.conn
	}
	return nil
}

// Online reports whether the node has a control connection
// (sites.NodeLiveness).
func (h *Hub) Online(nodeID string) bool { return h.conn(nodeID) != nil }

// ActiveSessions is the node's running sessions: its last stats, moved by
// the started and ended it reported since (sites.NodeLiveness).
func (h *Hub) ActiveSessions(nodeID string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	if n := h.nodes[nodeID]; n != nil && n.conn != nil {
		return n.active
	}
	return 0
}

// Traffic is the bytes the node relayed up and down since it started, as
// its last stats said; 0, 0 while it is offline.
func (h *Hub) Traffic(nodeID string) (up, down int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if n := h.nodes[nodeID]; n != nil && n.conn != nil {
		return n.up, n.down
	}
	return 0, 0
}

// Disconnect ends the node's connection with error{code:"revoked"}: the
// node was revoked, or its site or org deleted. The caller marks that in
// the store first, so the node's reconnects are refused.
func (h *Hub) Disconnect(nodeID string) {
	h.mu.Lock()
	var nc *nodeConn
	if n := h.nodes[nodeID]; n != nil {
		nc = n.conn
		for id, t := range n.tickets {
			if !t.live {
				delete(n.tickets, id)
				delete(h.sessions, id)
			}
		}
	}
	h.mu.Unlock()
	h.audit("relay_node.revoked", map[string]string{"node_id": nodeID})
	h.cfg.Logf("[nodes] Node %s revoked", nodeID)
	if nc != nil {
		nc.closeWith(wire.Error{Code: wire.CodeRevoked, Msg: "this node was revoked"})
	}
}

// DisconnectSite is Disconnect for every connected node of the site.
func (h *Hub) DisconnectSite(siteID string) {
	h.mu.Lock()
	var ids []string
	for id, n := range h.nodes {
		if n.siteID == siteID && n.conn != nil {
			ids = append(ids, id)
		}
	}
	h.mu.Unlock()
	for _, id := range ids {
		h.Disconnect(id)
	}
}

// RevokeForPeer drops the unclaimed tickets involving peer on every node.
func (h *Hub) RevokeForPeer(peer string) {
	if peer == "" {
		return
	}
	h.mu.Lock()
	var conns []*nodeConn
	for _, n := range h.nodes {
		n.dropPeerLocked(h, peer)
		if n.conn != nil {
			conns = append(conns, n.conn)
		}
	}
	h.mu.Unlock()
	for _, c := range conns {
		go c.send(wire.Revoke{Peer: peer})
	}
}

// End asks the nodes that run the session uuid to end it (two for a
// session between two sites); every node when the hub does not know
// which.
func (h *Hub) End(uuid string) {
	if uuid == "" {
		return
	}
	h.mu.Lock()
	var conns []*nodeConn
	for _, n := range h.nodes {
		if n.tickets[uuid] != nil && n.conn != nil {
			conns = append(conns, n.conn)
		}
	}
	if len(conns) == 0 {
		if id, ok := h.sessions[uuid]; ok {
			if n := h.nodes[id]; n != nil && n.conn != nil {
				conns = append(conns, n.conn)
			}
		} else {
			for _, n := range h.nodes {
				if n.conn != nil {
					conns = append(conns, n.conn)
				}
			}
		}
	}
	h.mu.Unlock()
	for _, c := range conns {
		go c.send(wire.End{UUID: uuid})
	}
}

func (n *nodeState) dropPeerLocked(h *Hub, peer string) {
	for id, t := range n.tickets {
		if !t.live && (t.initiator == peer || t.target == peer) {
			delete(n.tickets, id)
			delete(h.sessions, id)
		}
	}
}

func (n *nodeState) pruneLocked(h *Hub, now time.Time) {
	for id, t := range n.tickets {
		if (!t.live && !t.expires.After(now)) || (t.live && now.Sub(t.since) > liveMaxAge) {
			delete(n.tickets, id)
			delete(h.sessions, id)
		}
	}
}

func (h *Hub) count(nodeID string, f func(*ticketCounts)) {
	h.mu.Lock()
	f(&h.state(nodeID).counts)
	h.mu.Unlock()
}

func (h *Hub) auditLoop() {
	defer h.wg.Done()
	t := time.NewTicker(h.cfg.AuditInterval)
	defer t.Stop()
	for {
		select {
		case <-h.ctx.Done():
			return
		case <-t.C:
			h.flushAudit()
		}
	}
}

// flushAudit records the ticket pushes per node since the last flush.
func (h *Hub) flushAudit() {
	h.mu.Lock()
	type row struct {
		id string
		c  ticketCounts
	}
	var rows []row
	for id, n := range h.nodes {
		if n.counts.pushed > 0 || n.counts.legsAccepted > 0 || len(n.counts.legsRefused) > 0 {
			rows = append(rows, row{id, n.counts})
			n.counts = ticketCounts{}
		}
	}
	h.mu.Unlock()
	for _, r := range rows {
		if r.c.legsAccepted > 0 || len(r.c.legsRefused) > 0 {
			fields := map[string]string{"node_id": r.id, "accepted": strconv.FormatInt(r.c.legsAccepted, 10)}
			var refused int64
			for reason, n := range r.c.legsRefused {
				fields["refused_"+reason] = strconv.FormatInt(n, 10)
				refused += n
			}
			h.audit("relay_node.legs", fields)
			h.cfg.Logf("[nodes] Node %s legs from other nodes: %d accepted, %d refused", r.id, r.c.legsAccepted, refused)
		}
		if r.c.pushed == 0 {
			continue
		}
		h.audit("relay_node.tickets", map[string]string{
			"node_id":     r.id,
			"pushed":      strconv.Itoa(r.c.pushed),
			"ok":          strconv.Itoa(r.c.ok),
			"rejected":    strconv.Itoa(r.c.rejected),
			"unavailable": strconv.Itoa(r.c.unavailable),
		})
		h.cfg.Logf("[nodes] Node %s tickets: %d pushed, %d ok, %d rejected, %d unavailable",
			r.id, r.c.pushed, r.c.ok, r.c.rejected, r.c.unavailable)
	}
}
