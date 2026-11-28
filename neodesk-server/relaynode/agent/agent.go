package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/config"
	"github.com/neodeskapp/neodesk/neodesk-server/ratelimit"
	"github.com/neodeskapp/neodesk/neodesk-server/relay"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

const (
	dialTimeout  = 10 * time.Second
	writeTimeout = 10 * time.Second
	// clockSkew is how far a ticket's expiry may lie in the past (by this
	// node's clock) before the node refuses it
	clockSkew = time.Minute
	// maxQueued bounds the started/ended reports kept while offline
	maxQueued = 1024
)

// RefusedError is central's error frame.
type RefusedError struct{ Code, Msg string }

func (e *RefusedError) Error() string {
	return fmt.Sprintf("central refused the node: %s (%s)", e.Code, e.Msg)
}

// Agent is a relay node.
type Agent struct {
	cfg       Config
	key       ed25519.PrivateKey
	cert      tls.Certificate
	statePath string
	reg       *relay.AuthorizationRegistry
	gate      *gate
	srv       *relay.Server // set by Run
	active    func() int

	mu      sync.Mutex
	state   *State     // nil until enrolled
	join    *wire.Join // set while an enrollment is due
	conn    *wire.Conn
	queue   []wire.Message
	pending map[string]pendingTicket // pushed tickets not started yet
	revoked bool
	legs    *legListener // nil while the leg listener is off
	fwd     *forwarder   // nil while forwarding is off

	upTotal, downTotal atomic.Int64
}

type pendingTicket struct {
	initiator string
	expires   time.Time
}

// New loads the node's key and state, or prepares the enrollment that
// cfg.Join names. A Join other than the one the node enrolled with makes
// a new key (the old one moves to node.key.old) and enrolls again.
func New(cfg Config) (*Agent, error) {
	if cfg.DataDir == "" {
		return nil, errors.New("no data dir: set NODE_DATA_DIR")
	}
	if cfg.Relay == nil {
		cfg.Relay = config.DefaultConfig()
	}
	if cfg.Logf == nil {
		cfg.Logf = log.Printf
	}
	if cfg.StatsInterval <= 0 {
		cfg.StatsInterval = 30 * time.Second
	}
	if cfg.IdleTimeout <= 0 {
		cfg.IdleTimeout = 45 * time.Second
	}
	if cfg.BackoffMin <= 0 {
		cfg.BackoffMin = time.Second
	}
	if cfg.BackoffMax <= 0 {
		cfg.BackoffMax = 60 * time.Second
	}
	if cfg.LegsPerMinute <= 0 {
		cfg.LegsPerMinute = DefaultLegsPerMinute
	}
	if cfg.LegRefusalsLimit <= 0 {
		cfg.LegRefusalsLimit = DefaultLegRefusalsLimit
	}
	a := &Agent{
		cfg:       cfg,
		statePath: filepath.Join(cfg.DataDir, StateFileName),
		reg:       relay.NewAuthorizationRegistry(),
		pending:   make(map[string]pendingTicket),
	}
	a.gate = newGate(a, a.reg)
	st, err := loadState(a.statePath)
	if err != nil {
		return nil, err
	}
	a.state = st
	keyPath := filepath.Join(cfg.DataDir, KeyFileName)
	if cfg.Join != "" && (st == nil || st.JoinHash != joinHash(cfg.Join)) {
		j, err := wire.ParseJoin(cfg.Join)
		if err != nil {
			return nil, fmt.Errorf("NODE_JOIN: %w", err)
		}
		a.join = &j
		if st != nil {
			// A new enrollment: the old key stays bound to the old node
			if err := os.Rename(keyPath, keyPath+".old"); err != nil && !errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("move the old key aside: %w", err)
			}
			cfg.Logf("[node] New enrollment string: enrolling again with a new key (was node %s)", st.NodeID)
		}
	}
	if a.state == nil && a.join == nil {
		return nil, errors.New("this node is not enrolled: set NODE_JOIN or run neodesk-server node --join <enrollment string>")
	}
	key, created, err := wire.LoadOrGenerateKey(keyPath)
	if err != nil {
		return nil, err
	}
	if created {
		cfg.Logf("[node] Made the node key %s", keyPath)
	}
	a.key = key
	a.cert, err = wire.SelfSignedCert(key, "neodesk relay node")
	if err != nil {
		return nil, err
	}
	return a, nil
}

// Registry is the ticket store the node's relay claims from.
func (a *Agent) Registry() *relay.AuthorizationRegistry { return a.reg }

// PublicKey is the node's public key as central stores it.
func (a *Agent) PublicKey() string {
	return wire.PublicKeyBase64(a.key.Public().(ed25519.PublicKey))
}

// NodeID is the node's id, "" before the first welcome.
func (a *Agent) NodeID() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.state == nil {
		return ""
	}
	return a.state.NodeID
}

// Run starts the relay (TCP and WebSocket) with the pushed tickets and
// keeps the control connection until ctx ends.
func (a *Agent) Run(ctx context.Context) error {
	cfg := a.cfg.Relay
	srv := relay.New(cfg)
	srv.SetTicketClaims(a.gate)
	a.srv = srv
	srv.SetBandwidthLimiter(ratelimit.NewBandwidthLimiter(config.DefaultTotalBandwidth, config.DefaultSingleBandwidth))
	if cfg.RelayMaxConnsIP > 0 {
		srv.SetConnLimiter(ratelimit.NewConnLimiterFromInt(cfg.RelayMaxConnsIP))
		srv.SetSessionLimiter(ratelimit.NewConnLimiterFromInt(cfg.RelayMaxConnsIP))
	}
	srv.SetSessionReporter(relay.SessionReporterFuncs{
		Started: a.SessionStarted,
		Ended: func(uuid string, st relay.SessionStats) {
			a.SessionEnded(uuid, st.BytesFromFirst, st.BytesFromSecond)
		},
	})
	a.active = func() int { return int(srv.ActiveSessions.Load()) }
	if err := srv.Start(ctx); err != nil {
		return err
	}
	defer srv.Stop()
	if err := a.startLegListener(ctx); err != nil {
		return err
	}
	if err := a.startForward(ctx); err != nil {
		return err
	}
	if a.cfg.Ready != nil {
		a.cfg.Ready()
	}
	return a.RunControl(ctx)
}

// RunControl keeps the control connection to central until ctx ends,
// reconnecting with exponential backoff (BackoffMin to BackoffMax, with
// jitter). A connection that got a welcome starts the backoff over.
func (a *Agent) RunControl(ctx context.Context) error {
	backoff := a.cfg.BackoffMin
	for {
		welcomed, err := a.session(ctx)
		if ctx.Err() != nil {
			return nil
		}
		if welcomed {
			backoff = a.cfg.BackoffMin
		}
		wait := jitter(backoff)
		if err != nil {
			a.cfg.Logf("[node] Control connection: %v; retrying in %s", err, wait.Round(100*time.Millisecond))
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(wait):
		}
		backoff = min(backoff*2, a.cfg.BackoffMax)
	}
}

// jitter is d give or take 20 %.
func jitter(d time.Duration) time.Duration {
	return time.Duration(float64(d) * (0.8 + 0.4*rand.Float64()))
}

// target is where to connect and with which pin and token.
func (a *Agent) target() (server, pin, token, nodeID string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.join != nil {
		return a.join.Server, a.join.Pin, a.join.Token, ""
	}
	return a.state.Server, a.state.Pin, "", a.state.NodeID
}

// session runs one control connection. welcomed says central accepted it.
func (a *Agent) session(ctx context.Context) (welcomed bool, err error) {
	server, pin, token, nodeID := a.target()
	d := net.Dialer{Timeout: dialTimeout}
	raw, err := d.DialContext(ctx, "tcp", server)
	if err != nil {
		return false, err
	}
	tc := tls.Client(raw, wire.ClientTLS(a.cert, pin))
	hctx, cancel := context.WithTimeout(ctx, dialTimeout)
	err = tc.HandshakeContext(hctx)
	cancel()
	if err != nil {
		raw.Close()
		return false, fmt.Errorf("TLS with %s: %w", server, err)
	}
	c := wire.NewConn(tc)
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()

	if err := c.Write(a.hello(nodeID, token, tc.LocalAddr()), writeTimeout); err != nil {
		return false, err
	}
	f, err := c.Read(dialTimeout + 5*time.Second)
	if err != nil {
		return false, err
	}
	switch f.Type {
	case wire.TypeError:
		var e wire.Error
		_ = f.Decode(&e)
		a.refused(e)
		return false, &RefusedError{e.Code, e.Msg}
	case wire.TypeWelcome:
	default:
		return false, fmt.Errorf("central sent %s before welcome", f.Type)
	}
	var w wire.Welcome
	if err := f.Decode(&w); err != nil {
		return false, err
	}
	if err := a.welcomed(server, pin, w); err != nil {
		return true, err
	}
	a.cfg.Logf("[node] Connected to %s as node %s (%s), site %s", server, w.NodeID, w.Name, w.SiteID)

	// What happened while offline goes first, in order; reports wait for
	// the lock meanwhile
	a.mu.Lock()
	for len(a.queue) > 0 {
		if err := c.Write(a.queue[0], writeTimeout); err != nil {
			a.mu.Unlock()
			return true, err
		}
		a.queue = a.queue[1:]
	}
	a.conn = c
	a.revoked = false
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		if a.conn == c {
			a.conn = nil
		}
		a.mu.Unlock()
	}()

	done := make(chan struct{})
	defer close(done)
	go a.statsLoop(c, done)
	_ = a.sendStats(c)
	for {
		f, err := c.Read(a.cfg.IdleTimeout)
		if err != nil {
			return true, err
		}
		if err := a.handle(c, f); err != nil {
			return true, err
		}
	}
}

func (a *Agent) hello(nodeID, token string, local net.Addr) wire.Hello {
	lan := a.cfg.LanAddr
	if lan == "" {
		if host, _, err := net.SplitHostPort(local.String()); err == nil {
			if ip := net.ParseIP(host); ip != nil && !ip.IsLoopback() {
				lan = net.JoinHostPort(host, strconv.Itoa(a.cfg.Relay.RelayPort))
			}
		}
	}
	wsLan := a.cfg.WSLanAddr
	if wsLan == "" {
		wsLan = plusTwo(lan)
	}
	wsPublic := a.cfg.WSPublicAddr
	if wsPublic == "" {
		wsPublic = plusTwo(a.cfg.PublicAddr)
	}
	h := wire.Hello{
		NodeID: nodeID, Token: token, Version: a.cfg.Version,
		LanAddr: lan, PublicAddr: a.cfg.PublicAddr, WSLanAddr: wsLan, WSPublicAddr: wsPublic,
	}
	if a.LegAddr() != nil {
		h.LegLanAddr = legAddrFor(a.cfg.LegLanAddr, lan, a.cfg.LegPort)
		h.LegPublicAddr = legAddrFor(a.cfg.LegPublicAddr, a.cfg.PublicAddr, a.cfg.LegPort)
	}
	return h
}

// welcomed saves the enrollment the first welcome completes.
func (a *Agent) welcomed(server, pin string, w wire.Welcome) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	st := &State{NodeID: w.NodeID, SiteID: w.SiteID, Server: server, Pin: pin}
	if a.join != nil {
		st.JoinHash = joinHash(a.cfg.Join)
	} else if a.state != nil {
		st.JoinHash = a.state.JoinHash
	}
	if a.state != nil && *a.state == *st {
		return nil
	}
	if err := saveState(a.statePath, st); err != nil {
		return fmt.Errorf("save %s: %w", a.statePath, err)
	}
	if a.join != nil {
		a.cfg.Logf("[node] Enrolled as node %s", w.NodeID)
	}
	a.state = st
	a.join = nil
	return nil
}

// refused handles central's refusal. Revoked: the tickets that no session
// claimed yet are dropped; running sessions go on until they end.
func (a *Agent) refused(e wire.Error) {
	if e.Code != wire.CodeRevoked && e.Code != wire.CodeSiteGone {
		return
	}
	a.mu.Lock()
	a.revoked = true
	peers := make(map[string]bool)
	for _, t := range a.pending {
		peers[t.initiator] = true
	}
	a.pending = make(map[string]pendingTicket)
	a.mu.Unlock()
	for p := range peers {
		a.reg.RevokeForPeer(p)
	}
}

func (a *Agent) handle(c *wire.Conn, f wire.Frame) error {
	switch f.Type {
	case wire.TypePing:
		return c.Write(wire.Pong{}, writeTimeout)
	case wire.TypeAuthorize:
		var m wire.Authorize
		if err := f.Decode(&m); err != nil {
			return err
		}
		return c.Write(a.authorize(m), writeTimeout)
	case wire.TypeRevoke:
		var m wire.Revoke
		if f.Decode(&m) == nil && m.Peer != "" {
			a.reg.RevokeForPeer(m.Peer)
			a.mu.Lock()
			for id, t := range a.pending {
				if t.initiator == m.Peer {
					delete(a.pending, id)
				}
			}
			a.mu.Unlock()
		}
	case wire.TypeEnd:
		var m wire.End
		if f.Decode(&m) == nil && m.UUID != "" {
			a.gate.End(m.UUID)
		}
	case wire.TypeCancel:
		var m wire.Cancel
		if f.Decode(&m) == nil && m.UUID != "" {
			a.gate.cancel(m.UUID)
			a.mu.Lock()
			delete(a.pending, m.UUID)
			a.mu.Unlock()
		}
	case wire.TypeProbe:
		var m wire.Probe
		if f.Decode(&m) == nil {
			go a.probe(c, m)
		}
	case wire.TypeError:
		var e wire.Error
		_ = f.Decode(&e)
		a.refused(e)
		return &RefusedError{e.Code, e.Msg}
	default:
		// types of a newer central
	}
	return nil
}

func (a *Agent) authorize(m wire.Authorize) wire.Ack {
	now := time.Now()
	a.mu.Lock()
	revoked := a.revoked
	a.mu.Unlock()
	if revoked {
		return wire.Ack{ID: m.ID, Err: "revoked"}
	}
	if m.ExpiresUnixMs != 0 && time.UnixMilli(m.ExpiresUnixMs).Before(now.Add(-clockSkew)) {
		return wire.Ack{ID: m.ID, Err: "expired"}
	}
	var lt *legTicket
	if m.Leg != nil {
		var refusal string
		if lt, refusal = a.legTicket(*m.Leg, now); refusal != "" {
			return wire.Ack{ID: m.ID, Err: refusal}
		}
	}
	// The account and console session stay on central; the node's
	// registry only pairs the two sides
	if !a.reg.AuthorizeForSession(m.UUID, m.Initiator, m.Target, 0, "") {
		return wire.Ack{ID: m.ID, Err: "conflict"}
	}
	if lt != nil {
		a.gate.add(m.UUID, lt)
	} else {
		a.gate.forget(m.UUID)
	}
	a.mu.Lock()
	for id, t := range a.pending {
		if !t.expires.After(now) {
			delete(a.pending, id)
		}
	}
	a.pending[m.UUID] = pendingTicket{initiator: m.Initiator, expires: now.Add(config.RelayPairTimeout)}
	a.mu.Unlock()
	return wire.Ack{ID: m.ID, OK: true}
}

// legTicket checks the leg of a pushed ticket; refusal is the ack's error.
func (a *Agent) legTicket(l wire.Leg, now time.Time) (*legTicket, string) {
	if _, err := wire.DecodePublicKey(l.PeerKey); err != nil {
		return nil, "bad_leg"
	}
	switch l.Role {
	case wire.LegDial:
		if _, _, err := net.SplitHostPort(l.PeerAddr); err != nil {
			return nil, "bad_leg"
		}
	case wire.LegAccept:
		if a.LegAddr() == nil {
			return nil, "no_leg_listener"
		}
	default:
		return nil, "bad_leg"
	}
	return &legTicket{role: l.Role, peerAddr: l.PeerAddr, peerKey: l.PeerKey, expires: now.Add(config.RelayPairTimeout)}, ""
}

// SessionStarted reports a session whose two sides paired (relay hook).
func (a *Agent) SessionStarted(uuid string) {
	a.mu.Lock()
	delete(a.pending, uuid)
	a.mu.Unlock()
	a.report(wire.Started{UUID: uuid})
}

// SessionEnded reports a session's end and its bytes (relay hook).
func (a *Agent) SessionEnded(uuid string, up, down int64) {
	a.upTotal.Add(up)
	a.downTotal.Add(down)
	a.report(wire.Ended{UUID: uuid, Up: up, Down: down})
}

// report sends m now, or after the next welcome while offline.
func (a *Agent) report(m wire.Message) {
	a.mu.Lock()
	c := a.conn
	a.mu.Unlock()
	if c != nil && c.Write(m, writeTimeout) == nil {
		return
	}
	a.requeue(m)
}

func (a *Agent) requeue(m wire.Message) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.queue) >= maxQueued {
		a.queue = a.queue[1:]
	}
	a.queue = append(a.queue, m)
}

func (a *Agent) sendStats(c *wire.Conn) error {
	now := time.Now()
	a.mu.Lock()
	pending := 0
	for _, t := range a.pending {
		if t.expires.After(now) {
			pending++
		}
	}
	a.mu.Unlock()
	active := 0
	if a.active != nil {
		active = a.active()
	}
	st := wire.Stats{Active: active, Pending: pending, UpTotal: a.upTotal.Load(), DownTotal: a.downTotal.Load()}
	a.mu.Lock()
	legs := a.legs
	a.mu.Unlock()
	if legs != nil {
		st.LegsAccepted, st.LegsRefused = legs.counts()
	}
	return c.Write(st, writeTimeout)
}

func (a *Agent) statsLoop(c *wire.Conn, done <-chan struct{}) {
	t := time.NewTicker(a.cfg.StatsInterval)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			if a.sendStats(c) != nil {
				c.Close()
				return
			}
		}
	}
}
