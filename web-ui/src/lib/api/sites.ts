/**
 * Sites and relay nodes (console/routes/sites): sites with their networks
 * and nodes, enrollment strings for new nodes, revoking and renaming nodes,
 * the probe results between nodes, and pinning a device or a folder to a
 * site. Reading needs device.view, changing sites server.config or
 * org.edit, pinning device.edit. Answers are `{ success, data }`.
 */

import * as v from 'valibot';
import { api, Ok, wrapped } from './client.ts';
import { Bool, Str } from './lists.ts';

/* Every member is there in the output, whatever the server leaves out */
const Text = Str;
const BoolLike = Bool;

const Num = v.optional(
	v.pipe(
		v.nullable(v.union([v.number(), v.string()])),
		v.transform((n) => {
			const x = Number(n ?? 0);
			return Number.isFinite(x) ? x : 0;
		})
	),
	0
);

export const RelayNode = v.looseObject({
	id: Text,
	name: Text,
	site_id: Text,
	online: BoolLike,
	version: Text,
	last_seen: Text,
	created_at: Text,
	lan_addr: Text,
	public_addr: Text,
	active_sessions: Num,
	bytes_up: Num,
	bytes_down: Num,
	/** How many devices reach the server through the node now (a site without internet access) */
	forwarded_devices: Num,
	revoked: BoolLike,
	revoked_at: Text
});
export type RelayNode = v.InferOutput<typeof RelayNode>;

export const SiteNetwork = v.looseObject({ cidr: Text, kind: Text });
export type SiteNetwork = v.InferOutput<typeof SiteNetwork>;

const listOf = <S extends v.GenericSchema>(item: S) =>
	v.optional(
		v.pipe(
			v.nullable(v.array(item)),
			v.transform((x) => (x ?? []) as v.InferOutput<S>[])
		),
		[]
	);

export const Site = v.looseObject({
	id: Text,
	name: Text,
	org_id: Text,
	org_name: Text,
	vpn_group: Text,
	created_at: Text,
	networks: listOf(SiteNetwork),
	nodes: listOf(RelayNode),
	devices: Num
});
export type Site = v.InferOutput<typeof Site>;

export const SiteOrg = v.looseObject({ id: Text, name: Text });
export type SiteOrg = v.InferOutput<typeof SiteOrg>;

export const SiteList = v.looseObject({
	sites: listOf(Site),
	nodes_enabled: BoolLike,
	organizations: listOf(SiteOrg),
	unassigned: BoolLike
});
export type SiteList = v.InferOutput<typeof SiteList>;

export const EnrollmentToken = v.looseObject({
	token: Text,
	join: Text,
	server: Text,
	command: Text,
	expires_at: Text,
	commands: v.looseObject({ linux: Text, docker: Text, windows: Text })
});
export type EnrollmentToken = v.InferOutput<typeof EnrollmentToken>;

export const Reachability = v.looseObject({
	from: Text,
	to: Text,
	via: Text,
	ok: BoolLike,
	rtt_ms: Num,
	checked_at: Text
});
export type Reachability = v.InferOutput<typeof Reachability>;

/** A site named in a device or folder answer */
export const SiteRef = v.looseObject({ id: Text, name: Text });
export type SiteRef = v.InferOutput<typeof SiteRef>;

const enc = encodeURIComponent;

export function listSites(signal?: AbortSignal): Promise<SiteList> {
	return api(wrapped(SiteList), '/api/sites', { signal });
}

export interface SiteInput {
	name?: string;
	vpn_group?: string;
	/** Only when creating; "" is no organization */
	org_id?: string;
}

export function createSite(body: SiteInput): Promise<Site> {
	return api(wrapped(Site), '/api/sites', { method: 'POST', body });
}

export function updateSite(id: string, body: SiteInput): Promise<Site> {
	return api(wrapped(Site), `/api/sites/${enc(id)}`, { method: 'PATCH', body });
}

export function deleteSite(id: string) {
	return api(Ok, `/api/sites/${enc(id)}`, { method: 'DELETE' });
}

/** Replaces the site's networks; a refused entry comes back as an ApiError whose data.index names it */
export async function saveNetworks(
	id: string,
	networks: { cidr: string; kind: string }[]
): Promise<SiteNetwork[]> {
	const out = await api(
		wrapped(v.looseObject({ networks: listOf(SiteNetwork) })),
		`/api/sites/${enc(id)}/networks`,
		{ method: 'PUT', body: { networks } }
	);
	return out.networks;
}

export function createEnrollmentToken(siteId: string): Promise<EnrollmentToken> {
	return api(wrapped(EnrollmentToken), `/api/sites/${enc(siteId)}/enrollment-tokens`, {
		method: 'POST',
		body: {}
	});
}

export function revokeNode(id: string) {
	return api(Ok, `/api/relay-nodes/${enc(id)}/revoke`, { method: 'POST', body: {} });
}

export function renameNode(id: string, name: string): Promise<RelayNode> {
	return api(wrapped(RelayNode), `/api/relay-nodes/${enc(id)}`, { method: 'PATCH', body: { name } });
}

export async function listReachability(signal?: AbortSignal): Promise<Reachability[]> {
	const out = await api(
		wrapped(v.looseObject({ results: listOf(Reachability) })),
		'/api/sites/reachability',
		{
			signal
		}
	);
	return out.results;
}

/** Pins a device to a site; "" takes the pin away */
export function setDeviceSite(deviceId: string, siteId: string) {
	return api(Ok, `/api/devices/${enc(deviceId)}/site`, { method: 'PATCH', body: { site_id: siteId } });
}

/** Pins a folder's devices to a site; "" takes the pin away */
export function setFolderSite(folderId: number, siteId: string) {
	return api(Ok, `/api/folders/${folderId}/site`, { method: 'PATCH', body: { site_id: siteId } });
}
