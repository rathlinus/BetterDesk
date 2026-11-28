import { describe, expect, test } from 'vitest';
import type { Reachability, RelayNode, Site } from '../../../src/lib/api/sites.ts';
import {
	guessKind,
	hasSiteToSite,
	networkRows,
	networksChanged,
	networksToSave,
	nodeCounts,
	nodeStatus,
	openSite,
	placementKey,
	relayLabel,
	rowOfSentIndex,
	siteSummary,
	siteToSiteRows,
	sortNodes
} from '../../../src/lib/serverarea/sites.ts';

const node = (over: Partial<RelayNode> = {}): RelayNode => ({
	id: 'n-1',
	name: 'rack-1',
	site_id: 's-1',
	online: false,
	version: '',
	last_seen: '',
	created_at: '',
	lan_addr: '',
	public_addr: '',
	active_sessions: 0,
	bytes_up: 0,
	bytes_down: 0,
	revoked: false,
	revoked_at: '',
	...over
});

const site = (over: Partial<Site> = {}): Site => ({
	id: 's-1',
	name: 'Office',
	org_id: '',
	org_name: '',
	vpn_group: '',
	created_at: '',
	networks: [],
	nodes: [],
	devices: 0,
	...over
});

describe('relay nodes', () => {
	test('a revoked node reads revoked even while its connection is still open', () => {
		expect(nodeStatus({ online: true, revoked: true }).key).toBe('sites.node_revoked');
		expect(nodeStatus({ online: true, revoked: false })).toEqual({ tone: 'good', key: 'sites.node_online' });
		expect(nodeStatus({ online: false, revoked: false }).key).toBe('sites.node_offline');
	});

	test('the table lists online nodes first and revoked ones last, each by name', () => {
		const sorted = sortNodes([
			node({ id: 'a', name: 'aardvark', revoked: true, online: true }),
			node({ id: 'b', name: 'beta' }),
			node({ id: 'c', name: 'alpha' }),
			node({ id: 'd', name: 'Gamma', online: true })
		]);
		expect(sorted.map((n) => n.id)).toEqual(['d', 'c', 'b', 'a']);
	});

	test('counts and the summary leave revoked nodes out', () => {
		const s = site({
			devices: 7,
			nodes: [node({ online: true }), node({ id: 'n-2' }), node({ id: 'n-3', online: true, revoked: true })]
		});
		expect(nodeCounts(s)).toEqual({ online: 1, total: 2 });
		expect(siteSummary(s)).toEqual({ key: 'sites.summary', params: { online: 1, total: 2 } });
		expect(siteSummary(site({ nodes: [node({ revoked: true })] }))).toEqual({
			key: 'sites.summary_no_nodes'
		});
		expect(
			siteSummary(site({ nodes: [node({ online: true }), node({ id: 'n-2', revoked: true })] }))
		).toEqual({
			key: 'sites.summary_one_online'
		});
		expect(siteSummary(site({ nodes: [node()] }))).toEqual({ key: 'sites.summary_one_offline' });
	});
});

describe('networks editor', () => {
	test('a new address gets the kind of its range', () => {
		for (const cidr of [
			'10.1.0.0/16',
			'172.16.0.0/12',
			'172.31.9.0/24',
			'192.168.1.0/24',
			'100.64.0.0/10',
			'fd12:3456::/48'
		])
			expect(guessKind(cidr), cidr).toBe('private');
		for (const cidr of [
			'172.32.0.0/16',
			'192.169.0.0/16',
			'100.128.0.0/10',
			'203.0.113.0/24',
			'2001:db8::/32'
		])
			expect(guessKind(cidr), cidr).toBe('public');
	});

	test('blank rows are not sent, and a refused entry maps back to its row', () => {
		const rows = [
			{ cidr: ' 10.0.0.0/8 ', kind: 'private' as const },
			{ cidr: '', kind: 'private' as const },
			{ cidr: '198.51.100.0/24', kind: 'public' as const }
		];
		expect(networksToSave(rows)).toEqual([
			{ cidr: '10.0.0.0/8', kind: 'private' },
			{ cidr: '198.51.100.0/24', kind: 'public' }
		]);
		// The server counts the two rows it got: its entry 1 is the third row
		expect(rowOfSentIndex(rows, 1)).toBe(2);
		expect(rowOfSentIndex(rows, 0)).toBe(0);
		expect(rowOfSentIndex(rows, 5)).toBe(-1);
	});

	test('the list counts as changed only when what would be sent differs', () => {
		const s = site({ networks: [{ cidr: '10.0.0.0/8', kind: 'private' }] });
		expect(networksChanged(s, networkRows(s))).toBe(false);
		expect(networksChanged(s, [...networkRows(s), { cidr: '  ', kind: 'public' }])).toBe(false);
		expect(networksChanged(s, [{ cidr: '10.0.0.0/8', kind: 'public' }])).toBe(true);
		expect(networksChanged(s, [])).toBe(true);
	});
});

describe('the open site and placement', () => {
	test('the address picks the site, else the first one', () => {
		const list = [site({ id: 'a' }), site({ id: 'b' })];
		expect(openSite(list, 'b')?.id).toBe('b');
		expect(openSite(list, 'gone')?.id).toBe('a');
		expect(openSite([], 'a')).toBeNull();
	});

	test('where a device site comes from', () => {
		expect(placementKey('pin')).toBe('sites.source_pin');
		expect(placementKey('folder')).toBe('sites.source_folder');
		expect(placementKey('network')).toBe('sites.source_network');
		expect(placementKey('')).toBeNull();
	});
});

describe('session relay', () => {
	test('each kind reads as its own text, nodes by name', () => {
		expect(relayLabel({ kind: 'direct' })?.key).toBe('sites.relay_direct');
		expect(relayLabel({ kind: 'central' })?.key).toBe('sites.relay_central');
		expect(relayLabel({ kind: 'lan' })?.key).toBe('sites.relay_lan');
		expect(relayLabel({ kind: 'node', nodes: [{ id: 'n-1', name: 'rack-1' }] })).toEqual({
			key: 'sites.relay_node',
			params: { name: 'rack-1' }
		});
		expect(
			relayLabel({
				kind: 'nodes',
				nodes: [
					{ id: 'n-1', name: 'Berlin' },
					{ id: 'n-2', name: '' }
				]
			})
		).toEqual({ key: 'sites.relay_nodes', params: { from: 'Berlin', to: 'n-2' } });
	});

	test('nothing recorded, an unknown kind or a node without a name gives no text', () => {
		expect(relayLabel(null)).toBeNull();
		expect(relayLabel({})).toBeNull();
		expect(relayLabel({ kind: 'odd' })).toBeNull();
		expect(relayLabel({ kind: 'node', nodes: [] })).toBeNull();
	});
});

describe('site to site', () => {
	const sites = [
		site({ id: 's-b', name: 'Hamburg', nodes: [node({ id: 'n-b', name: 'hh-1', site_id: 's-b' })] }),
		site({
			id: 's-a',
			name: 'Berlin',
			nodes: [
				node({ id: 'n-a', name: 'ber-1', site_id: 's-a' }),
				node({ id: 'n-a2', name: '', site_id: 's-a' })
			]
		})
	];
	const probe = (from: string, to: string, over: Partial<Reachability> = {}): Reachability => ({
		from,
		to,
		via: 'public',
		ok: true,
		rtt_ms: 4,
		checked_at: '2026-11-28T10:00:00Z',
		...over
	});

	test('names both ends by site and node, sorted by site', () => {
		const rows = siteToSiteRows(sites, [
			probe('n-b', 'n-a', { ok: false, via: 'private' }),
			probe('n-a', 'n-b', { rtt_ms: 12 })
		]);
		expect(rows.map((r) => [r.fromSite, r.fromNode, r.toSite, r.toNode, r.via, r.ok, r.rttMs])).toEqual([
			['Berlin', 'ber-1', 'Hamburg', 'hh-1', 'public', true, 12],
			['Hamburg', 'hh-1', 'Berlin', 'ber-1', 'private', false, 4]
		]);
	});

	test('leaves out probes inside one site and of unknown nodes; a nameless node shows its id', () => {
		const rows = siteToSiteRows(sites, [probe('n-a', 'n-a2'), probe('n-a', 'n-gone'), probe('n-a2', 'n-b')]);
		expect(rows.map((r) => r.key)).toEqual(['n-a2|n-b|public']);
		expect(rows[0]?.fromNode).toBe('n-a2');
	});

	test('shows only when two sites have nodes that are not revoked', () => {
		expect(hasSiteToSite(sites)).toBe(true);
		expect(hasSiteToSite([sites[0]!, site({ id: 's-c', nodes: [node({ revoked: true })] })])).toBe(false);
	});
});
