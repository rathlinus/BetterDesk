package wire

// Message types. N: node to central, C: central to node.
const (
	TypeHello     = "hello"     // N
	TypeWelcome   = "welcome"   // C
	TypeError     = "error"     // C, then close
	TypeAuthorize = "authorize" // C
	TypeAck       = "ack"       // N
	TypeRevoke    = "revoke"    // C
	TypeEnd       = "end"       // C
	TypeStarted   = "started"   // N
	TypeEnded     = "ended"     // N
	TypeStats     = "stats"     // N
	TypeCancel    = "cancel"    // C
	TypeProbe     = "probe"     // C
	TypeProbed    = "probed"    // N
	TypePing      = "ping"      // C
	TypePong      = "pong"      // N
)

// Error codes central sends before it closes.
const (
	CodeRevoked     = "revoked"      // node revoked, or its site or org deleted
	CodeSiteGone    = "site_gone"    // the node's site no longer exists
	CodeBadToken    = "bad_token"    // enrollment token unknown, used or expired
	CodeUnknownNode = "unknown_node" // no token and the client key is not enrolled
	CodeMismatch    = "node_mismatch"
	CodeRateLimited = "rate_limited"
	CodeBadHello    = "bad_hello"
	CodeReplaced    = "replaced" // the same node connected again
	CodeInternal    = "internal"
)

// Hello is the node's first frame. Token is set on the first start only.
type Hello struct {
	NodeID       string `json:"node_id,omitempty"`
	Token        string `json:"token,omitempty"`
	Version      string `json:"version"`
	LanAddr      string `json:"lan_addr"`
	PublicAddr   string `json:"public_addr"`
	WSLanAddr    string `json:"ws_lan_addr"`
	WSPublicAddr string `json:"ws_public_addr"`
	// LegLanAddr and LegPublicAddr are where other nodes reach this
	// node's leg listener (NODE_LEG_PORT), "" when it has none there
	LegLanAddr    string `json:"leg_lan_addr,omitempty"`
	LegPublicAddr string `json:"leg_public_addr,omitempty"`
}

func (Hello) Type() string { return TypeHello }

// Welcome accepts the node.
type Welcome struct {
	NodeID   string `json:"node_id"`
	SiteID   string `json:"site_id"`
	OrgID    string `json:"org_id"`
	Name     string `json:"name"`
	ServerPK string `json:"server_pk"`
}

func (Welcome) Type() string { return TypeWelcome }

// Error refuses or ends the connection.
type Error struct {
	Code string `json:"code"`
	Msg  string `json:"msg"`
}

func (Error) Type() string { return TypeError }

// Roles of a node in a session over two nodes.
const (
	LegDial   = "dial"   // the node dials the other node when its peer arrives
	LegAccept = "accept" // the node takes the other node's leg as the second side
)

// Leg is the part of a ticket for a session over two nodes: the node
// dials PeerAddr and accepts only PeerKey there (dial), or takes a leg
// from the node with PeerKey (accept, no PeerAddr).
type Leg struct {
	Role     string `json:"role"`
	PeerAddr string `json:"peer_addr,omitempty"`
	PeerKey  string `json:"peer_key"`
}

// Authorize pushes a relay ticket to the node.
type Authorize struct {
	ID            uint64 `json:"id"`
	UUID          string `json:"uuid"`
	Initiator     string `json:"initiator"`
	Target        string `json:"target"`
	ExpiresUnixMs int64  `json:"expires_unix_ms"`
	Leg           *Leg   `json:"leg,omitempty"`
}

func (Authorize) Type() string { return TypeAuthorize }

// Ack answers Authorize with the same ID.
type Ack struct {
	ID  uint64 `json:"id"`
	OK  bool   `json:"ok"`
	Err string `json:"err,omitempty"`
}

func (Ack) Type() string { return TypeAck }

// Revoke drops the node's unclaimed tickets that involve Peer.
type Revoke struct {
	Peer string `json:"peer"`
}

func (Revoke) Type() string { return TypeRevoke }

// End ends a session.
type End struct {
	UUID string `json:"uuid"`
}

func (End) Type() string { return TypeEnd }

// Cancel drops the unclaimed ticket of UUID: the other node of a
// session over two nodes did not take its ticket.
type Cancel struct {
	UUID string `json:"uuid"`
}

func (Cancel) Type() string { return TypeCancel }

// Started reports that both sides of a session reached the node.
type Started struct {
	UUID string `json:"uuid"`
}

func (Started) Type() string { return TypeStarted }

// Ended reports the end of a session and the bytes each way.
type Ended struct {
	UUID string `json:"uuid"`
	Up   int64  `json:"up"`
	Down int64  `json:"down"`
}

func (Ended) Type() string { return TypeEnded }

// Stats is the node's state, every 30 s; it is also the heartbeat.
type Stats struct {
	Active    int   `json:"active"`
	Pending   int   `json:"pending"`
	UpTotal   int64 `json:"up_total"`
	DownTotal int64 `json:"down_total"`
	// Legs counts the legs from other nodes since the node started:
	// accepted, and refused by reason (LegRefused*)
	LegsAccepted int64            `json:"legs_accepted,omitempty"`
	LegsRefused  map[string]int64 `json:"legs_refused,omitempty"`
}

// Reasons a node refuses a leg from another node.
const (
	LegRefusedNoTicket  = "no_ticket"    // no accept ticket for the uuid
	LegRefusedWrongKey  = "wrong_key"    // the dialer's key is not the one central named
	LegRefusedRate      = "rate_limited" // too many legs or refusals from the address
	LegRefusedHandshake = "handshake"    // TLS failed or no Ed25519 client certificate
	LegRefusedBadFrame  = "bad_frame"    // the first frame is not RequestRelay{uuid}
)

func (Stats) Type() string { return TypeStats }

// ProbeTarget is a node to check reachability to: a TLS handshake to its
// leg listener at Addr that must show Key.
type ProbeTarget struct {
	NodeID string `json:"node_id"`
	Addr   string `json:"addr"`
	Key    string `json:"key"`
}

// Probe asks the node to check reachability.
type Probe struct {
	Targets []ProbeTarget `json:"targets"`
}

func (Probe) Type() string { return TypeProbe }

// ProbeResult is one reachability check.
type ProbeResult struct {
	NodeID string `json:"node_id"`
	Addr   string `json:"addr"`
	OK     bool   `json:"ok"`
	RTTMs  int64  `json:"rtt_ms"`
}

// Probed answers Probe.
type Probed struct {
	Results []ProbeResult `json:"results"`
}

func (Probed) Type() string { return TypeProbed }

// Ping asks for a Pong.
type Ping struct{}

func (Ping) Type() string { return TypePing }

// Pong answers Ping.
type Pong struct{}

func (Pong) Type() string { return TypePong }
