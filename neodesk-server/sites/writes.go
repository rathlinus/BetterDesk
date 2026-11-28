package sites

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/neodeskapp/neodesk/neodesk-server/db"
)

// EnrollmentTokenTTL is how long an enrollment token can be used.
const EnrollmentTokenTTL = 24 * time.Hour

// CreateSite stores a new site of orgID ("" for an installation without
// organizations).
func (s *Service) CreateSite(orgID, name, vpnGroup string) (*db.Site, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, err
	}
	vpnGroup, err = cleanVPNGroup(vpnGroup)
	if err != nil {
		return nil, err
	}
	site := &db.Site{OrgID: orgID, Name: name, VPNGroup: vpnGroup, CreatedAt: s.now().UTC()}
	if err := s.db.CreateSite(site); err != nil {
		return nil, err
	}
	s.Invalidate()
	return site, nil
}

// UpdateSite changes the name and the VPN group of a site; a nil value
// keeps what the site has.
func (s *Service) UpdateSite(id string, name, vpnGroup *string) (*db.Site, error) {
	site, err := s.site(id)
	if err != nil {
		return nil, err
	}
	if name != nil {
		if site.Name, err = cleanName(*name); err != nil {
			return nil, err
		}
	}
	if vpnGroup != nil {
		if site.VPNGroup, err = cleanVPNGroup(*vpnGroup); err != nil {
			return nil, err
		}
	}
	if err := s.db.UpdateSite(site); err != nil {
		return nil, err
	}
	s.Invalidate()
	return site, nil
}

// DeleteSite removes a site with its networks, nodes, tokens and pins, and
// tells the revoke hook about its nodes.
func (s *Service) DeleteSite(id string) error {
	if _, err := s.site(id); err != nil {
		return err
	}
	nodes, err := s.db.ListRelayNodes(id)
	if err != nil {
		return err
	}
	if err := s.db.DeleteSite(id); err != nil {
		return err
	}
	s.Invalidate()
	ids := make([]string, 0, len(nodes))
	for _, n := range nodes {
		ids = append(ids, n.ID)
	}
	s.revoked(ids)
	return nil
}

// ReplaceNetworks makes nets the networks of a site and returns them as
// stored, CIDRs in canonical form. Every network is checked first; one bad
// or repeated network changes nothing.
func (s *Service) ReplaceNetworks(siteID string, nets []db.SiteNetwork) ([]db.SiteNetwork, error) {
	if _, err := s.site(siteID); err != nil {
		return nil, err
	}
	clean := make([]db.SiteNetwork, 0, len(nets))
	seen := make(map[string]bool, len(nets))
	for _, n := range nets {
		kind := strings.TrimSpace(n.Kind)
		cidr, err := ValidateNetwork(n.CIDR, kind)
		if err != nil {
			return nil, err
		}
		if seen[cidr] {
			return nil, fmt.Errorf("%w: %s is listed twice", ErrInvalidNetwork, cidr)
		}
		seen[cidr] = true
		clean = append(clean, db.SiteNetwork{SiteID: siteID, CIDR: cidr, Kind: kind})
	}
	if err := s.db.ReplaceSiteNetworks(siteID, clean); err != nil {
		return nil, err
	}
	s.Invalidate()
	return clean, nil
}

// CreateEnrollmentToken makes a token that enrolls one relay node into the
// site within EnrollmentTokenTTL. The token is returned here only; the
// database keeps its hash.
func (s *Service) CreateEnrollmentToken(siteID, createdBy string) (string, *db.SiteEnrollmentToken, error) {
	if _, err := s.site(siteID); err != nil {
		return "", nil, err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, fmt.Errorf("sites: make enrollment token: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	now := s.now().UTC()
	t := &db.SiteEnrollmentToken{
		TokenHash: HashToken(token),
		SiteID:    siteID,
		CreatedBy: createdBy,
		CreatedAt: now,
		ExpiresAt: now.Add(EnrollmentTokenTTL),
	}
	if err := s.db.CreateSiteEnrollmentToken(t); err != nil {
		return "", nil, err
	}
	return token, t, nil
}

// ConsumeEnrollmentToken uses an enrollment token for a new node and
// stores the node at the token's site. node gives the public key (required)
// and what the node reports (name, version, addresses); its ID, SiteID and
// CreatedAt are set here. A key that is already enrolled fails before the
// token is used; a token that can't be used gives ErrTokenInvalid.
func (s *Service) ConsumeEnrollmentToken(token string, node *db.RelayNode) (*db.RelayNode, error) {
	if node == nil || strings.TrimSpace(node.PublicKey) == "" {
		return nil, fmt.Errorf("sites: enrollment without a public key")
	}
	if existing, err := s.db.GetRelayNodeByKey(node.PublicKey); err != nil {
		return nil, err
	} else if existing != nil {
		return nil, ErrNodeKeyTaken
	}
	n := *node
	n.ID = uuid.NewString()
	n.RevokedAt = nil
	now := s.now().UTC()
	t, err := s.db.ConsumeSiteEnrollmentToken(HashToken(token), n.ID, now)
	if err != nil {
		return nil, err
	}
	if _, err := s.site(t.SiteID); err != nil {
		return nil, err
	}
	n.SiteID = t.SiteID
	n.CreatedAt = now
	if n.Name, err = cleanName(n.Name); err != nil {
		n.Name = "node-" + n.ID[:8]
	}
	if err := s.db.CreateRelayNode(&n); err != nil {
		return nil, err
	}
	s.Invalidate()
	return &n, nil
}

// SetPin pins a device (ref is its id) or a folder (ref is its id in
// decimal) to a site; siteID "" removes the pin. A device can only be
// pinned to a site of its own organization.
func (s *Service) SetPin(kind, ref, siteID string) error {
	ref = strings.TrimSpace(ref)
	switch kind {
	case db.SitePinDevice:
		if ref == "" {
			return ErrInvalidPin
		}
	case db.SitePinFolder:
		id, err := strconv.ParseInt(ref, 10, 64)
		if err != nil || id <= 0 {
			return ErrInvalidPin
		}
		ref = strconv.FormatInt(id, 10)
	default:
		return ErrInvalidPin
	}
	if siteID != "" {
		site, err := s.site(siteID)
		if err != nil {
			return err
		}
		if kind == db.SitePinDevice {
			org, err := s.db.GetDeviceOrgID(ref)
			if err != nil {
				return err
			}
			if org != site.OrgID {
				return ErrOtherOrg
			}
		}
	}
	if err := s.db.SetSitePin(kind, ref, siteID); err != nil {
		return err
	}
	s.Invalidate()
	return nil
}

// RevokeNode revokes a node: it gets no more sessions, and the revoke hook
// hears of it.
func (s *Service) RevokeNode(id string) error {
	if err := s.db.RevokeRelayNode(id, s.now().UTC()); err != nil {
		return err
	}
	s.Invalidate()
	s.revoked([]string{id})
	return nil
}

// RenameNode changes the name of a node.
func (s *Service) RenameNode(id, name string) error {
	name, err := cleanName(name)
	if err != nil {
		return err
	}
	if err := s.db.RenameRelayNode(id, name); err != nil {
		return err
	}
	s.Invalidate()
	return nil
}

// UpdateNodeState stores what a connected node reports, seen now. The
// cache is dropped only when an address changed, since routing reads
// those.
func (s *Service) UpdateNodeState(id, version, lanAddr, publicAddr string) error {
	if err := s.db.UpdateRelayNodeState(id, version, lanAddr, publicAddr, s.now().UTC()); err != nil {
		return err
	}
	s.mu.Lock()
	snap := s.snap
	s.mu.Unlock()
	if snap != nil {
		for _, nodes := range snap.nodes {
			for _, n := range nodes {
				if n.ID == id && n.LANAddr == lanAddr && n.PublicAddr == publicAddr && n.Version == version {
					return nil
				}
			}
		}
	}
	s.Invalidate()
	return nil
}

// RecordReachability stores a probe result; Route reads it for pairs of
// nodes.
func (s *Service) RecordReachability(r db.SiteReachability) error {
	if r.CheckedAt.IsZero() {
		r.CheckedAt = s.now().UTC()
	}
	if err := s.db.UpsertSiteReachability(&r); err != nil {
		return err
	}
	// Routing reads only which pairs failed; a result that does not
	// change that keeps the cache
	s.mu.Lock()
	snap := s.snap
	s.mu.Unlock()
	if snap != nil && snap.failed[[3]string{r.FromNode, r.ToNode, r.Via}] == !r.OK {
		return nil
	}
	s.Invalidate()
	return nil
}
