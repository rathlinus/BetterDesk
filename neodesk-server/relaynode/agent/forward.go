package agent

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/config"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
)

// Forwarding (phase 3, D19): with NODE_FORWARD=Y the node listens on the
// ID server's ports for the computers at its site and carries every TCP
// connection, and every UDP datagram, to central over the control port,
// with the computer's address. A computer there sets the node's LAN
// address as its ID server and central's key as its key.

// Defaults of the forward ports.
const (
	DefaultForwardSignalPort = 21116 // TCP and UDP; NAT test - 1, WebSocket + 2
	DefaultForwardAPIPort    = 21121 // NEODESK_API_PORT of the client
	// forwardMaxOpen bounds the open forwarded TCP connections; central
	// limits per computer
	forwardMaxOpen = 4096
	// forwardUDPTTL is how long a computer's UDP address may get answers
	// after its last datagram; the node sends nothing to others
	forwardUDPTTL = 5 * time.Minute
)

// forwarder is the node's forward listeners.
type forwarder struct {
	a    *Agent
	sem  chan struct{}
	lns  []net.Listener
	udp  *net.UDPConn
	wg   sync.WaitGroup
	addr map[string]string // service -> listen address, for tests

	mu      sync.Mutex
	clients map[string]udpClient // claimed address -> real one
	uconn   *wire.Conn           // the UDP forwarding connection, nil while down
}

type udpClient struct {
	addr *net.UDPAddr
	seen time.Time
}

// forwardListenAddr is where a forward listener on port listens.
func (a *Agent) forwardListenAddr(port int) string {
	host := a.cfg.ForwardListen
	if host == "" {
		if h, _, err := net.SplitHostPort(a.cfg.LanAddr); err == nil && net.ParseIP(h) != nil {
			host = h
		}
	}
	if host == "" {
		return config.ListenAddr(port)
	}
	return net.JoinHostPort(host, strconv.Itoa(port))
}

// clientAddr is the address the node vouches for: the computer's own.
func (a *Agent) clientAddr(addr net.Addr) string {
	if a.cfg.ClientAddr != nil {
		return a.cfg.ClientAddr(addr)
	}
	return addr.String()
}

// startForward opens the forward listeners; they close when ctx ends.
func (a *Agent) startForward(ctx context.Context) error {
	if !a.cfg.Forward {
		return nil
	}
	sig, api := a.cfg.ForwardSignalPort, a.cfg.ForwardAPIPort
	if sig <= 0 {
		sig = DefaultForwardSignalPort
	}
	if api <= 0 {
		api = DefaultForwardAPIPort
	}
	f := &forwarder{a: a, sem: make(chan struct{}, forwardMaxOpen), addr: map[string]string{}, clients: map[string]udpClient{}}
	for _, l := range []struct {
		service string
		port    int
	}{{wire.ServiceSignal, sig}, {wire.ServiceNAT, sig - 1}, {wire.ServiceWS, sig + 2}, {wire.ServiceAPI, api}} {
		ln, err := net.Listen("tcp", a.forwardListenAddr(l.port))
		if err != nil {
			f.close()
			return fmt.Errorf("forward %s: %w", l.service, err)
		}
		f.lns = append(f.lns, ln)
		f.addr[l.service] = ln.Addr().String()
		f.wg.Add(1)
		go f.acceptTCP(ctx, l.service, ln)
	}
	uaddr, err := net.ResolveUDPAddr("udp", a.forwardListenAddr(sig))
	if err == nil {
		f.udp, err = net.ListenUDP("udp", uaddr)
	}
	if err != nil {
		f.close()
		return fmt.Errorf("forward UDP: %w", err)
	}
	f.addr["udp"] = f.udp.LocalAddr().String()
	f.wg.Add(2)
	go f.readUDP(ctx)
	go f.keepUDPChannel(ctx)
	a.mu.Lock()
	a.fwd = f
	a.mu.Unlock()
	go func() {
		<-ctx.Done()
		f.close()
	}()
	a.cfg.Logf("[node] Forwarding signal %s, NAT test %s, WebSocket %s, API %s and UDP %s to central",
		f.addr[wire.ServiceSignal], f.addr[wire.ServiceNAT], f.addr[wire.ServiceWS], f.addr[wire.ServiceAPI], f.addr["udp"])
	return nil
}

func (f *forwarder) close() {
	for _, ln := range f.lns {
		ln.Close()
	}
	if f.udp != nil {
		f.udp.Close()
	}
	f.mu.Lock()
	if f.uconn != nil {
		f.uconn.Close()
	}
	f.mu.Unlock()
}

// ForwardAddr is the listen address of a forward service (wire.Service*,
// or "udp"), "" while forwarding is off.
func (a *Agent) ForwardAddr(service string) string {
	a.mu.Lock()
	f := a.fwd
	a.mu.Unlock()
	if f == nil {
		return ""
	}
	return f.addr[service]
}

// dialCentral opens a TLS connection to central's control port with the
// node certificate; an error while the node is not enrolled yet.
func (a *Agent) dialCentral(ctx context.Context) (*tls.Conn, error) {
	a.mu.Lock()
	st := a.state
	a.mu.Unlock()
	if st == nil {
		return nil, errors.New("not enrolled yet")
	}
	d := net.Dialer{Timeout: dialTimeout}
	raw, err := d.DialContext(ctx, "tcp", st.Server)
	if err != nil {
		return nil, err
	}
	tc := tls.Client(raw, wire.ClientTLS(a.cert, st.Pin))
	hctx, cancel := context.WithTimeout(ctx, dialTimeout)
	err = tc.HandshakeContext(hctx)
	cancel()
	if err != nil {
		raw.Close()
		return nil, err
	}
	return tc, nil
}

func (f *forwarder) acceptTCP(ctx context.Context, service string, ln net.Listener) {
	defer f.wg.Done()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		select {
		case f.sem <- struct{}{}:
		default:
			c.Close()
			continue
		}
		go func() {
			defer func() { <-f.sem }()
			f.forwardTCP(ctx, service, c)
		}()
	}
}

// forwardTCP carries one TCP connection of a computer to central.
func (f *forwarder) forwardTCP(ctx context.Context, service string, client net.Conn) {
	a := f.a
	defer client.Close()
	tc, err := a.dialCentral(ctx)
	if err != nil {
		a.cfg.Logf("[node] Forward %s from %s: %v", service, client.RemoteAddr(), err)
		return
	}
	defer tc.Close()
	if err := wire.WriteFrame(tc, wire.ForwardTCP{Service: service, ClientAddr: a.clientAddr(client.RemoteAddr())}); err != nil {
		return
	}
	// The computer's bytes go out right after the header; central's come
	// after its one answer frame
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(tc, client)
		done <- struct{}{}
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		_ = tc.SetReadDeadline(time.Now().Add(dialTimeout))
		fr, err := wire.ReadFrame(tc)
		if err != nil {
			return
		}
		if fr.Type != wire.TypeForwardOK {
			var e wire.Error
			_ = fr.Decode(&e)
			a.cfg.Logf("[node] Central refused the %s forward of %s: %s (%s)", service, client.RemoteAddr(), e.Code, e.Msg)
			return
		}
		_ = tc.SetReadDeadline(time.Time{})
		_, _ = io.Copy(client, tc)
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// readUDP reads the computers' datagrams and sends them to central.
func (f *forwarder) readUDP(ctx context.Context) {
	defer f.wg.Done()
	buf := make([]byte, 65536)
	for {
		n, from, err := f.udp.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		claimed := f.a.clientAddr(from)
		now := time.Now()
		f.mu.Lock()
		if _, ok := f.clients[claimed]; !ok && len(f.clients) > 4096 {
			for k, c := range f.clients {
				if now.Sub(c.seen) >= forwardUDPTTL {
					delete(f.clients, k)
				}
			}
		}
		f.clients[claimed] = udpClient{addr: from, seen: now}
		c := f.uconn
		f.mu.Unlock()
		if c == nil {
			continue // central is not reachable now; UDP may drop
		}
		_ = c.Write(wire.Datagram{Addr: claimed, Data: append([]byte(nil), buf[:n]...)}, writeTimeout)
	}
}

// keepUDPChannel keeps the UDP forwarding connection to central open,
// reopening it with backoff, and delivers central's datagrams.
func (f *forwarder) keepUDPChannel(ctx context.Context) {
	defer f.wg.Done()
	a := f.a
	backoff := a.cfg.BackoffMin
	for ctx.Err() == nil {
		opened, err := f.udpSession(ctx)
		if ctx.Err() != nil {
			return
		}
		if opened {
			backoff = a.cfg.BackoffMin
		}
		if err != nil && !errors.Is(err, io.EOF) {
			a.cfg.Logf("[node] UDP forwarding: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(jitter(backoff)):
		}
		backoff = min(backoff*2, a.cfg.BackoffMax)
	}
}

func (f *forwarder) udpSession(ctx context.Context) (opened bool, err error) {
	tc, err := f.a.dialCentral(ctx)
	if err != nil {
		return false, err
	}
	c := wire.NewConn(tc)
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	if err := c.Write(wire.ForwardUDP{}, writeTimeout); err != nil {
		return false, err
	}
	fr, err := c.Read(dialTimeout)
	if err != nil {
		return false, err
	}
	if fr.Type != wire.TypeForwardOK {
		var e wire.Error
		_ = fr.Decode(&e)
		return false, &RefusedError{e.Code, e.Msg}
	}
	f.mu.Lock()
	f.uconn = c
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		if f.uconn == c {
			f.uconn = nil
		}
		f.mu.Unlock()
	}()
	for {
		fr, err := c.Read(0)
		if err != nil {
			return true, err
		}
		if fr.Type != wire.TypeDatagram {
			continue
		}
		var d wire.Datagram
		if fr.Decode(&d) != nil {
			continue
		}
		// Only to a computer that sent from there lately: central can't
		// use the node to send datagrams anywhere on the site network
		f.mu.Lock()
		cl, ok := f.clients[d.Addr]
		f.mu.Unlock()
		if !ok || time.Since(cl.seen) >= forwardUDPTTL {
			continue
		}
		_, _ = f.udp.WriteToUDP(d.Data, cl.addr)
	}
}
