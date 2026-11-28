// sites-e2e-peer is a fake RustDesk peer and setup helper for the end to
// end run of sites and relay nodes (scripts/e2e-sites.sh). It speaks the
// parts of the client protocol a relayed session needs.
//
// Usage:
//
//	sites-e2e-peer setup  -db F -data D -control H:P -out D -site 'name|cidr:kind,...|vpn' ... -pin dev=site ...
//	sites-e2e-peer target -server H:P -id ID -key KEY
//	sites-e2e-peer connect -server H:P -id ID -target ID -key KEY [-bytes N]
//	sites-e2e-peer online -server H:P -id ID
//	sites-e2e-peer nattest -server H:P
//	sites-e2e-peer reach -addr H:P
//
// setup prepares a central server's data directory before its first
// start: sites, networks, VPN groups, device pins, one enrollment string
// per site (out/<site>.join), the server key (data/id_ed25519) and its
// public half (out/key.pub).
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/neodeskapp/neodesk/neodesk-server/codec"
	"github.com/neodeskapp/neodesk/neodesk-server/crypto"
	"github.com/neodeskapp/neodesk/neodesk-server/db"
	pb "github.com/neodeskapp/neodesk/neodesk-server/proto"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/hub"
	"github.com/neodeskapp/neodesk/neodesk-server/relaynode/wire"
	"github.com/neodeskapp/neodesk/neodesk-server/sites"
	"google.golang.org/protobuf/proto"
)

type multi []string

func (m *multi) String() string     { return strings.Join(*m, " ") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	if len(os.Args) < 2 {
		log.Fatal("usage: sites-e2e-peer setup|target|connect|online|nattest|reach ...")
	}
	cmd, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	server := fs.String("server", "", "ID server host:port (or NAT test port for online/nattest)")
	id := fs.String("id", "", "this peer's id")
	target := fs.String("target", "", "the peer to connect to")
	key := fs.String("key", "", "the central server's public key (base64)")
	nbytes := fs.Int("bytes", 65536, "bytes to send through the relay")
	addr := fs.String("addr", "", "address to try (reach)")
	dbPath := fs.String("db", "", "central database (setup)")
	dataDir := fs.String("data", "", "central data directory (setup)")
	control := fs.String("control", "", "central control address for the join strings (setup)")
	outDir := fs.String("out", "", "where setup writes join strings and the key")
	var siteSpecs, pins multi
	fs.Var(&siteSpecs, "site", "name|cidr:kind,...|vpn (setup, repeated)")
	fs.Var(&pins, "pin", "device=site (setup, repeated)")
	_ = fs.Parse(args)

	switch cmd {
	case "setup":
		setup(*dbPath, *dataDir, *control, *outDir, siteSpecs, pins)
	case "target":
		runTarget(*server, *id, *key)
	case "connect":
		os.Exit(runConnect(*server, *id, *target, *key, *nbytes))
	case "online":
		fmt.Println(online(*server, *id))
	case "nattest":
		natTest(*server)
	case "reach":
		c, err := net.DialTimeout("tcp", *addr, 2*time.Second)
		if err != nil {
			fmt.Printf("unreachable %s: %v\n", *addr, err)
			return
		}
		c.Close()
		fmt.Printf("reachable %s\n", *addr)
	default:
		log.Fatalf("unknown command %q", cmd)
	}
}

// ---- setup ----

func setup(dbPath, dataDir, control, outDir string, specs, pins multi) {
	database, err := db.OpenSQLite(dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer database.Close()
	if err := database.Migrate(); err != nil {
		log.Fatal(err)
	}
	kp, err := crypto.LoadOrGenerateKeyPair(filepath.Join(dataDir, "id_ed25519"))
	if err != nil {
		log.Fatal(err)
	}
	_, pin, err := hub.LoadOrCreateCert(dataDir)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		log.Fatal(err)
	}
	must(os.WriteFile(filepath.Join(outDir, "key.pub"), []byte(kp.PublicKeyBase64()), 0o644))
	svc := sites.New(database)
	byName := map[string]string{}
	for _, spec := range specs {
		parts := strings.Split(spec, "|")
		for len(parts) < 3 {
			parts = append(parts, "")
		}
		site, err := svc.CreateSite("", parts[0], parts[2])
		if err != nil {
			log.Fatalf("site %s: %v", parts[0], err)
		}
		var nets []db.SiteNetwork
		for _, n := range strings.Split(parts[1], ",") {
			if n == "" {
				continue
			}
			cidr, kind, _ := strings.Cut(n, ":")
			nets = append(nets, db.SiteNetwork{CIDR: cidr, Kind: kind})
		}
		if _, err := svc.ReplaceNetworks(site.ID, nets); err != nil {
			log.Fatalf("site %s networks: %v", parts[0], err)
		}
		token, _, err := svc.CreateEnrollmentToken(site.ID, "e2e")
		if err != nil {
			log.Fatal(err)
		}
		join := wire.Join{Server: control, Pin: pin, Token: token}.Encode()
		must(os.WriteFile(filepath.Join(outDir, parts[0]+".join"), []byte(join), 0o644))
		byName[parts[0]] = site.ID
		log.Printf("site %s (%s) networks %s vpn %q", parts[0], site.ID, parts[1], parts[2])
	}
	for _, p := range pins {
		dev, site, _ := strings.Cut(p, "=")
		if err := svc.SetPin(db.SitePinDevice, dev, byName[site]); err != nil {
			log.Fatalf("pin %s: %v", p, err)
		}
	}
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

// ---- peers ----

func newKey() ed25519.PublicKey {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	return pub
}

func registerPk(id string, pk []byte) *pb.RendezvousMessage {
	return &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPk{RegisterPk: &pb.RegisterPk{Id: id, Uuid: []byte("e2e-" + id), Pk: pk}}}
}

// runTarget registers over UDP as a controlled client, heartbeats, and
// answers every RequestRelay by dialing the named relay and echoing.
func runTarget(server, id, key string) {
	pk := newKey()
	c, err := net.ListenUDP("udp4", nil)
	must(err)
	srv, err := net.ResolveUDPAddr("udp4", server)
	must(err)
	send := func(m *pb.RendezvousMessage) {
		b, _ := proto.Marshal(m)
		_, _ = c.WriteToUDP(b, srv)
	}
	go func() {
		for {
			send(&pb.RendezvousMessage{Union: &pb.RendezvousMessage_RegisterPeer{RegisterPeer: &pb.RegisterPeer{Id: id, Serial: 1}}})
			time.Sleep(3 * time.Second)
		}
	}()
	seen := map[string]bool{}
	registered := false
	buf := make([]byte, 65535)
	for {
		n, _, err := c.ReadFromUDP(buf)
		must(err)
		m := &pb.RendezvousMessage{}
		if proto.Unmarshal(buf[:n], m) != nil {
			continue
		}
		switch {
		case m.GetRegisterPeerResponse() != nil:
			if m.GetRegisterPeerResponse().GetRequestPk() {
				send(registerPk(id, pk))
			}
		case m.GetRegisterPkResponse() != nil:
			if !registered {
				log.Printf("target %s registered at %s (%v)", id, server, m.GetRegisterPkResponse().GetResult())
				registered = true
			}
		case m.GetRequestRelay() != nil:
			rr := m.GetRequestRelay()
			if seen[rr.Uuid] {
				continue
			}
			seen[rr.Uuid] = true
			log.Printf("target %s RequestRelay uuid=%s relay=%s", id, rr.Uuid, rr.RelayServer)
			go echoRelay(rr.RelayServer, rr.Uuid, key)
		case m.GetPunchHole() != nil:
			log.Printf("target %s got a PunchHole (relay %s)", id, m.GetPunchHole().GetRelayServer())
		}
	}
}

func dialRelay(addr, id, key string) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	if err := codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{Uuid: id, LicenceKey: key}}}); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

func echoRelay(addr, id, key string) {
	c, err := dialRelay(addr, id, key)
	if err != nil {
		log.Printf("target relay %s: %v", addr, err)
		return
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(60 * time.Second))
	_, _ = io.Copy(c, c)
}

type result struct {
	OK       bool   `json:"ok"`
	From     string `json:"from"`
	To       string `json:"to"`
	UUID     string `json:"uuid,omitempty"`
	Relay    string `json:"relay,omitempty"`
	Refuse   string `json:"refuse,omitempty"`
	SignedPK bool   `json:"signed_by_central"`
	Bytes    int    `json:"bytes,omitempty"`
	Millis   int64  `json:"ms"`
	Error    string `json:"error,omitempty"`
}

// runConnect starts a relayed session as a controlling client does and
// prints one JSON line; exit status 0 only when bytes went through.
func runConnect(server, id, target, key string, n int) int {
	start := time.Now()
	res := result{From: id, To: target}
	out := func() int {
		res.Millis = time.Since(start).Milliseconds()
		b, _ := json.Marshal(res)
		fmt.Println(string(b))
		if res.OK {
			return 0
		}
		return 1
	}
	fail := func(err error) int { res.Error = err.Error(); return out() }
	sig, err := net.DialTimeout("tcp", server, 5*time.Second)
	if err != nil {
		return fail(err)
	}
	defer sig.Close()
	if m, err := codec.ReadRawProto(sig, 5*time.Second); err != nil || m.GetKeyExchange() == nil {
		return fail(fmt.Errorf("want KeyExchange first: %v %v", m, err))
	}
	if err := codec.WriteRawProto(sig, registerPk(id, newKey())); err != nil {
		return fail(err)
	}
	if m, err := codec.ReadRawProto(sig, 5*time.Second); err != nil || m.GetRegisterPkResponse().GetResult() != pb.RegisterPkResponse_OK {
		return fail(fmt.Errorf("RegisterPk: %v %v", m, err))
	}
	res.UUID = uuid.NewString()
	if err := codec.WriteRawProto(sig, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_RequestRelay{RequestRelay: &pb.RequestRelay{Id: target, Uuid: res.UUID, LicenceKey: key}}}); err != nil {
		return fail(err)
	}
	m, err := codec.ReadRawProto(sig, 10*time.Second)
	if err != nil {
		return fail(err)
	}
	rr := m.GetRelayResponse()
	if rr == nil {
		return fail(fmt.Errorf("want RelayResponse, got %v", m))
	}
	res.Relay, res.Refuse = rr.GetRelayServer(), rr.GetRefuseReason()
	res.SignedPK = signedByCentral(rr.GetPk(), key, target)
	if res.Refuse != "" {
		return out()
	}
	c, err := dialRelay(res.Relay, res.UUID, key)
	if err != nil {
		return fail(err)
	}
	defer c.Close()
	payload := make([]byte, n)
	_, _ = rand.Read(payload)
	_ = c.SetDeadline(time.Now().Add(20 * time.Second))
	go func() { _, _ = c.Write(payload) }()
	got := make([]byte, n)
	if _, err := io.ReadFull(c, got); err != nil {
		return fail(fmt.Errorf("echo: %w", err))
	}
	if !bytes.Equal(got, payload) {
		return fail(fmt.Errorf("echo differs"))
	}
	res.OK, res.Bytes = true, n
	return out()
}

func signedByCentral(signed []byte, key, id string) bool {
	pub, err := wire.DecodePublicKey(key)
	if err != nil || len(signed) <= ed25519.SignatureSize {
		return false
	}
	if !ed25519.Verify(pub, signed[ed25519.SignatureSize:], signed[:ed25519.SignatureSize]) {
		return false
	}
	var idpk pb.IdPk
	return proto.Unmarshal(signed[ed25519.SignatureSize:], &idpk) == nil && idpk.Id == id
}

func online(server, id string) bool {
	c, err := net.DialTimeout("tcp", server, 5*time.Second)
	must(err)
	defer c.Close()
	must(codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_OnlineRequest{OnlineRequest: &pb.OnlineRequest{Id: "E2EASK", Peers: []string{id}}}}))
	m, err := codec.ReadRawProto(c, 5*time.Second)
	must(err)
	st := m.GetOnlineResponse().GetStates()
	return len(st) > 0 && st[0]&0x80 != 0
}

func natTest(server string) {
	c, err := net.DialTimeout("tcp", server, 5*time.Second)
	must(err)
	defer c.Close()
	must(codec.WriteRawProto(c, &pb.RendezvousMessage{Union: &pb.RendezvousMessage_TestNatRequest{TestNatRequest: &pb.TestNatRequest{}}}))
	m, err := codec.ReadRawProto(c, 5*time.Second)
	must(err)
	r := m.GetTestNatResponse()
	fmt.Printf("nat test: local port %d, server saw port %d, config update %v\n", c.LocalAddr().(*net.TCPAddr).Port, r.GetPort(), r.GetCu() != nil)
}
