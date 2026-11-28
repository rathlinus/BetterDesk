package central

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/db"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/signal"
	"github.com/neodeskapp/neodesk/neodesk-server/sites"
)

// Config sets up Start.
type Config struct {
	// Addr is the control listener's address, ":21123".
	Addr string
	// CertDir holds the control certificate (node_control.crt/.key),
	// made there on the first start: the server's data dir.
	CertDir string
	// ServerPK is the server's public key, sent to nodes in welcome.
	ServerPK string
	DB       db.Database
	Billing  Billing // optional
	Signal   *signal.Server
	// Hub overrides hub settings other than Addr, Cert, ServerPK and the
	// store, events and auditor (timings, Logf); zero values are the
	// hub's defaults.
	Hub hub.Config
	// ProbeInterval is how often nodes check that they reach the nodes
	// of their organization at other sites (DefaultProbeInterval when
	// 0); ProbeDelay is the wait after a node connects before a round
	// (DefaultProbeDelay when 0, negative for none).
	ProbeInterval time.Duration
	ProbeDelay    time.Duration
}

// Start opens the control listener relay nodes connect to and turns on
// relay node routing in signal: the sites service learns from the hub
// which nodes are online, revoking a node closes its connection, and
// signal asks the glue for node routes. The caller stops the hub
// (Glue.Hub.Stop) and makes the glue the default when it wants the
// console to reach it.
func Start(ctx context.Context, cfg Config) (*Glue, error) {
	cert, pin, err := hub.LoadOrCreateCert(cfg.CertDir)
	if err != nil {
		return nil, fmt.Errorf("control certificate: %w", err)
	}
	svc := sites.New(cfg.DB)
	glue := &Glue{DB: cfg.DB, Sites: svc, Pin: pin, Billing: cfg.Billing}
	glue.probes.interval, glue.probes.delay = cfg.ProbeInterval, cfg.ProbeDelay
	if glue.probes.interval <= 0 {
		glue.probes.interval = DefaultProbeInterval
	}
	if glue.probes.delay == 0 {
		glue.probes.delay = DefaultProbeDelay
	}
	hc := cfg.Hub
	hc.Addr, hc.Cert, hc.ServerPK = cfg.Addr, cert, cfg.ServerPK
	hc.Store, hc.Events, hc.Audit = glue, glue, glue
	h, err := hub.New(hc)
	if err != nil {
		return nil, err
	}
	if err := h.Start(ctx); err != nil {
		return nil, err
	}
	if a, ok := h.Addr().(*net.TCPAddr); ok {
		glue.ControlPort = a.Port
	}
	glue.Hub = h
	svc.SetLiveness(h)
	svc.SetRevokeHook(func(ids []string) {
		for _, id := range ids {
			h.Disconnect(id)
		}
	})
	if cfg.Signal != nil {
		glue.OwnRelay = cfg.Signal.IsOwnRelay
		cfg.Signal.SetSiteRouter(glue)
	}
	go glue.runProbes(ctx)
	return glue, nil
}
