/**
 * The Sites page's logic without a DOM: how a node's state reads, the
 * sentence under a site's name, the network rows of the editor, which site
 * is open, and how a session's relay reads. Labels come back as language
 * keys with their values; the page translates them.
 */

import type { Reachability, RelayNode, Site } from '#lib/api/sites.ts';

export interface Keyed {
	key: string;
	params?: Record<string, string | number>;
}

/** A node's state as a status: revoked, online or offline */
export function nodeStatus(n: Pick<RelayNode, 'online' | 'revoked'>): { tone: string; key: string } {
	if (n.revoked) return { tone: 'neutral', key: 'sites.node_revoked' };
	if (n.online) return { tone: 'good', key: 'sites.node_online' };
	return { tone: 'offline', key: 'sites.node_offline' };
}

/** Nodes as the table lists them: working ones first, revoked last, each group by name */
export function sortNodes(nodes: readonly RelayNode[]): RelayNode[] {
	return [...nodes].sort(
		(a, b) =>
			Number(a.revoked) - Number(b.revoked) ||
			Number(b.online) - Number(a.online) ||
			a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }) ||
			a.id.localeCompare(b.id)
	);
}

/** How many of the site's nodes that are not revoked are online */
export function nodeCounts(site: Pick<Site, 'nodes'>): { online: number; total: number } {
	const live = site.nodes.filter((n) => !n.revoked);
	return { online: live.filter((n) => n.online).length, total: live.length };
}

/** The sentence under the open site's name: how many of its relay nodes are online */
export function siteSummary(site: Pick<Site, 'nodes'>): Keyed {
	const { online, total } = nodeCounts(site);
	if (total === 0) return { key: 'sites.summary_no_nodes' };
	if (total === 1) return { key: online ? 'sites.summary_one_online' : 'sites.summary_one_offline' };
	return { key: 'sites.summary', params: { online, total } };
}

/** A row of the networks editor */
export interface NetworkRow {
	cidr: string;
	kind: 'private' | 'public';
}

/** The site's networks as editor rows */
export function networkRows(site: Pick<Site, 'networks'> | null): NetworkRow[] {
	return (site?.networks ?? []).map((n) => ({
		cidr: n.cidr,
		kind: n.kind === 'public' ? 'public' : 'private'
	}));
}

/** The kind an address range most likely is, for a new row: private for the private ranges, else public */
export function guessKind(cidr: string): NetworkRow['kind'] {
	const text = cidr.trim().toLowerCase();
	const v4 = /^(\d{1,3})\.(\d{1,3})\./.exec(text);
	if (v4) {
		const a = Number(v4[1]);
		const b = Number(v4[2]);
		if (
			a === 10 ||
			(a === 172 && b >= 16 && b <= 31) ||
			(a === 192 && b === 168) ||
			(a === 100 && b >= 64 && b <= 127)
		)
			return 'private';
		return 'public';
	}
	return /^f[cd][0-9a-f]{0,2}:/.test(text) ? 'private' : 'public';
}

/** What is sent: rows with an address, trimmed; blank rows are dropped */
export function networksToSave(rows: readonly NetworkRow[]): { cidr: string; kind: string }[] {
	return rows.map((r) => ({ cidr: r.cidr.trim(), kind: r.kind })).filter((r) => r.cidr !== '');
}

/** The index in `rows` of the server's refused entry, which counts only the rows that were sent */
export function rowOfSentIndex(rows: readonly NetworkRow[], sent: number): number {
	let n = -1;
	for (const [i, row] of rows.entries()) {
		if (row.cidr.trim() === '') continue;
		n++;
		if (n === sent) return i;
	}
	return -1;
}

/** Whether the editor's rows differ from what the site has */
export function networksChanged(site: Pick<Site, 'networks'> | null, rows: readonly NetworkRow[]): boolean {
	const a = networksToSave(networkRows(site));
	const b = networksToSave(rows);
	return a.length !== b.length || a.some((x, i) => x.cidr !== b[i]?.cidr || x.kind !== b[i]?.kind);
}

/** The site to show: the one the address names if it is there, else the first */
export function openSite<T extends { id: string }>(sites: readonly T[], wanted: string | null): T | null {
	return sites.find((s) => s.id === wanted) ?? sites[0] ?? null;
}

/** How a session was relayed, as the device's session list gets it */
export interface SessionRelay {
	kind?: string;
	nodes?: { id?: string; name?: string }[];
}

/** A session's relay as text: direct, the central relay, the LAN relay, or the relay nodes by name */
export function relayLabel(relay: SessionRelay | null | undefined): Keyed | null {
	if (!relay?.kind) return null;
	const names = (relay.nodes ?? []).map((n) => n.name || n.id || '').filter(Boolean);
	switch (relay.kind) {
		case 'direct':
			return { key: 'sites.relay_direct' };
		case 'central':
			return { key: 'sites.relay_central' };
		case 'lan':
			return { key: 'sites.relay_lan' };
		case 'node':
			return names[0] ? { key: 'sites.relay_node', params: { name: names[0] } } : null;
		case 'nodes': {
			const [from, to] = names;
			if (from && to) return { key: 'sites.relay_nodes', params: { from, to } };
			return from ? { key: 'sites.relay_node', params: { name: from } } : null;
		}
	}
	return null;
}

/** Where a device's site comes from, as a language key; null when it is at no site */
export function placementKey(source: string | null | undefined): string | null {
	switch (source) {
		case 'pin':
			return 'sites.source_pin';
		case 'folder':
			return 'sites.source_folder';
		case 'network':
			return 'sites.source_network';
	}
	return null;
}

/** Whether the open site's node table shows the forwarded devices: a node that works forwards some now */
export function showsForwarded(
	nodes: readonly Pick<RelayNode, 'online' | 'revoked' | 'forwarded_devices'>[]
): boolean {
	return nodes.some((n) => n.online && !n.revoked && n.forwarded_devices > 0);
}

/** The relay node a device comes through, as text; null when it reaches the server directly */
export function viaNodeLabel(via: { id?: string; name?: string } | null | undefined): Keyed | null {
	const name = via?.name || via?.id || '';
	return name ? { key: 'sites.via_node_value', params: { name } } : null;
}

/** A row of the site to site table: a probe from one site's node to another's */
export interface SiteToSiteRow {
	key: string;
	fromSite: string;
	fromNode: string;
	toSite: string;
	toNode: string;
	via: 'private' | 'public';
	ok: boolean;
	rttMs: number;
	checkedAt: string;
}

/**
 * The probe results between nodes of different sites, named by site and
 * node, sorted by the sites' names. Results naming a node the account
 * can't see, and between two nodes of one site, are left out.
 */
export function siteToSiteRows(
	sites: readonly Pick<Site, 'id' | 'name' | 'nodes'>[],
	reach: readonly Reachability[]
): SiteToSiteRow[] {
	const where = new Map<string, { site: string; siteId: string; node: string }>();
	for (const s of sites)
		for (const n of s.nodes) where.set(n.id, { site: s.name, siteId: s.id, node: n.name || n.id });
	const rows: SiteToSiteRow[] = [];
	for (const r of reach) {
		const from = where.get(r.from);
		const to = where.get(r.to);
		if (!from || !to || from.siteId === to.siteId) continue;
		rows.push({
			key: `${r.from}|${r.to}|${r.via}`,
			fromSite: from.site,
			fromNode: from.node,
			toSite: to.site,
			toNode: to.node,
			via: r.via === 'private' ? 'private' : 'public',
			ok: r.ok,
			rttMs: r.rtt_ms,
			checkedAt: r.checked_at
		});
	}
	const cmp = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: 'base' });
	return rows.sort(
		(a, b) =>
			cmp(a.fromSite, b.fromSite) ||
			cmp(a.toSite, b.toSite) ||
			cmp(a.fromNode, b.fromNode) ||
			cmp(a.toNode, b.toNode)
	);
}

/** Whether sessions between sites can run over relay nodes at all: two sites have nodes */
export function hasSiteToSite(sites: readonly Pick<Site, 'nodes'>[]): boolean {
	return sites.filter((s) => s.nodes.some((n) => !n.revoked)).length >= 2;
}
