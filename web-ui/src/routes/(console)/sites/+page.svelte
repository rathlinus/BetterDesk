<!--
  Sites (/sites): the locations of an organization's devices that have
  their own relay nodes. The list of sites, and the open site below it
  (?site=<id>): its organization and VPN group, its networks (which
  addresses put a device there), its relay nodes with their state,
  addresses, sessions and traffic (and the devices a node forwards for a
  site without internet access), adding a node (an enrollment string with
  install commands), renaming and revoking nodes. Once two sites have
  relay nodes, "Site to site" lists whether their nodes reach each other,
  from the nodes' own probes.

  Reading needs device.view; adding, changing and deleting sites and nodes
  server.config or org.edit. The server keeps an account to its
  organizations' sites.
-->
<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import {
		deleteSite,
		listReachability,
		listSites,
		renameNode,
		revokeNode,
		type Reachability,
		type RelayNode,
		type Site,
		type SiteList
	} from '#lib/api/sites.ts';
	import { formatBytes, formatNumber } from '#lib/i18n/format.ts';
	import { t } from '#lib/i18n/i18n.svelte.ts';
	import {
		hasSiteToSite,
		nodeCounts,
		nodeStatus,
		openSite,
		showsForwarded,
		siteSummary,
		siteToSiteRows,
		sortNodes,
		type SiteToSiteRow
	} from '#lib/serverarea/sites.ts';
	import NoAccess from '#lib/shell/NoAccess.svelte';
	import { can, canWrite } from '#lib/state/session.svelte.ts';
	import Button from '#lib/ui/Button.svelte';
	import Facts, { type Fact } from '#lib/ui/Facts.svelte';
	import Notice from '#lib/ui/Notice.svelte';
	import ReadOnlyHint from '#lib/ui/ReadOnlyHint.svelte';
	import States from '#lib/ui/States.svelte';
	import Status from '#lib/ui/Status.svelte';
	import Table from '#lib/ui/Table.svelte';
	import Time from '#lib/ui/Time.svelte';
	import ValueCopy from '#lib/ui/ValueCopy.svelte';
	import { confirm, prompt } from '#lib/ui/dialogs.svelte.ts';
	import type { Column } from '#lib/ui/table.ts';
	import { toast } from '#lib/ui/toasts.svelte.ts';
	import { ICONS } from '#lib/util/display.ts';
	import NetworksEditor from './NetworksEditor.svelte';
	import NodeDialog from './NodeDialog.svelte';
	import SiteDialog from './SiteDialog.svelte';

	const allowed = $derived(can('device.view'));
	const canEdit = $derived(canWrite('server.config') || canWrite('org.edit'));

	/* ── Data ── */

	let data = $state.raw<SiteList | null>(null);
	let error = $state<string | null>(null);
	let reach = $state.raw<Reachability[]>([]);

	async function load() {
		try {
			data = await listSites();
			error = null;
		} catch (err) {
			error = err instanceof Error && err.message ? err.message : t('sites.load_failed');
		}
		listReachability().then(
			(r) => (reach = r),
			() => (reach = [])
		);
	}

	$effect(() => {
		if (!allowed) return;
		untrack(() => void load());
	});

	/* ── The open site ── */

	let wanted = $state<string | null>(page.url.searchParams.get('site'));
	const sites = $derived(data?.sites ?? []);
	const site = $derived(openSite(sites, wanted));
	let detailHeading = $state<HTMLElement | null>(null);

	async function show(s: Site) {
		wanted = s.id;
		const url = new URL(location.href);
		url.searchParams.set('site', s.id);
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- this page's own URL with ?site=
		replaceState(url, page.state);
		await tick();
		detailHeading?.focus();
	}

	/* ── Dialogs ── */

	let siteDialog = $state<{ site: Site | null } | null>(null);
	let nodeDialogFor = $state<string | null>(null);
	const nodeDialogSite = $derived(sites.find((s) => s.id === nodeDialogFor) ?? null);

	// While a node is being added the site reloads, so the dialog sees it join
	$effect(() => {
		if (!nodeDialogFor) return;
		const timer = setInterval(() => void load(), 4000);
		return () => clearInterval(timer);
	});

	const message = (err: unknown) => (err instanceof Error ? err.message : String(err));

	async function removeSite(s: Site) {
		const ok = await confirm({
			title: t('sites.delete_title', { name: s.name }),
			message: s.nodes.some((n) => !n.revoked) ? t('sites.delete_message_nodes') : t('sites.delete_message'),
			confirmLabel: t('sites.delete'),
			confirmIcon: ICONS.delete,
			danger: true
		});
		if (!ok) return;
		try {
			await deleteSite(s.id);
			toast.success(t('sites.site_deleted', { name: s.name }));
			wanted = null;
		} catch (err) {
			toast.error(t('sites.delete_failed', { error: message(err) }));
		}
		await load();
	}

	async function rename(n: RelayNode) {
		const name = await prompt({
			title: t('sites.rename_node_title', { name: n.name }),
			label: t('sites.name'),
			value: n.name,
			required: true,
			confirmLabel: t('actions.save')
		});
		if (name === null || name.trim() === n.name) return;
		try {
			await renameNode(n.id, name.trim());
			toast.success(t('sites.node_renamed', { name: name.trim() }));
		} catch (err) {
			toast.error(t('sites.node_rename_failed', { error: message(err) }));
		}
		await load();
	}

	async function revoke(n: RelayNode) {
		const ok = await confirm({
			title: t('sites.revoke_title', { name: n.name }),
			message: t('sites.revoke_message'),
			confirmLabel: t('sites.revoke'),
			danger: true
		});
		if (!ok) return;
		try {
			await revokeNode(n.id);
			toast.success(t('sites.node_revoked_named', { name: n.name }));
		} catch (err) {
			toast.error(t('sites.revoke_failed', { error: message(err) }));
		}
		await load();
	}

	/* ── Tables and facts ── */

	const siteColumns = $derived<Column<Site>[]>([
		{
			id: 'name',
			label: t('sites.col_site'),
			cell: siteNameCell,
			primary: true,
			sortValue: (s) => s.name.toLowerCase()
		},
		{ id: 'networks', label: t('sites.col_networks'), cell: siteNetworksCell },
		{ id: 'nodes', label: t('sites.col_nodes'), cell: siteNodesCell, sortValue: (s) => nodeCounts(s).online },
		{
			id: 'devices',
			label: t('sites.col_devices'),
			cell: siteDevicesCell,
			align: 'num',
			sortValue: (s) => s.devices
		}
	]);

	const nodes = $derived(site ? sortNodes(site.nodes) : []);
	/* The forwarded devices column, while a node of the open site forwards some */
	const forwarding = $derived(showsForwarded(nodes));

	const nodeColumns = $derived<Column<RelayNode>[]>([
		{ id: 'name', label: t('sites.col_node'), cell: nodeNameCell, primary: true },
		{ id: 'status', label: t('sites.col_status'), cell: nodeStatusCell },
		{ id: 'addresses', label: t('sites.col_addresses'), cell: nodeAddressCell },
		{ id: 'sessions', label: t('sites.col_sessions'), cell: nodeSessionsCell, align: 'num' },
		{ id: 'traffic', label: t('sites.col_traffic'), cell: nodeTrafficCell },
		...(forwarding
			? [{ id: 'forwarded', label: t('sites.col_forwarded'), cell: nodeForwardedCell, align: 'num' as const }]
			: []),
		...(canEdit
			? [
					{
						id: 'actions',
						label: t('sites.col_actions'),
						labelHidden: true,
						cell: nodeActionsCell,
						align: 'actions' as const
					}
				]
			: [])
	]);

	const siteFacts = $derived<Fact[]>(
		site
			? [
					...(site.org_id || data?.organizations.length
						? [{ label: t('sites.organization'), value: site.org_name || t('sites.no_organization') }]
						: []),
					{ label: t('sites.vpn_group'), value: site.vpn_group, empty: t('sites.no_vpn_group') },
					{ label: t('sites.created'), value: createdValue }
				]
			: []
	);

	const showSiteToSite = $derived(hasSiteToSite(sites) || reach.length > 0);
	const siteToSite = $derived(siteToSiteRows(sites, reach));
	const reachColumns = $derived<Column<SiteToSiteRow>[]>([
		{
			id: 'from',
			label: t('sites.col_from'),
			cell: reachFromCell,
			primary: true,
			sortValue: (r) => r.fromSite.toLowerCase()
		},
		{ id: 'to', label: t('sites.col_to'), cell: reachToCell, sortValue: (r) => r.toSite.toLowerCase() },
		{ id: 'via', label: t('sites.col_via'), cell: reachViaCell },
		{
			id: 'result',
			label: t('sites.col_result'),
			cell: reachResultCell,
			sortValue: (r) => (r.ok ? r.rttMs : 1e9)
		},
		{ id: 'checked', label: t('sites.col_checked'), cell: reachCheckedCell, sortValue: (r) => r.checkedAt }
	]);
</script>

{#snippet siteNameCell(s: Site)}
	<span class="strong">{s.name}</span>{#if s.org_name}<span class="cell-sub">{s.org_name}</span>{/if}
{/snippet}

{#snippet siteNetworksCell(s: Site)}
	{#if s.networks.length}
		<span class="mono">{s.networks.map((n) => n.cidr).join(', ')}</span>
	{:else}
		<span class="muted">{t('sites.no_networks')}</span>
	{/if}
{/snippet}

{#snippet siteNodesCell(s: Site)}
	{@const c = nodeCounts(s)}
	{#if c.total === 0}
		<span class="muted">{t('sites.no_nodes_short')}</span>
	{:else}
		<Status
			tone={c.online === c.total ? 'good' : c.online ? 'warning' : 'offline'}
			label={t('sites.nodes_online', c)}
		/>
	{/if}
{/snippet}

{#snippet siteDevicesCell(s: Site)}{formatNumber(s.devices)}{/snippet}

{#snippet createdValue()}{#if site}<Time value={site.created_at} relative={false} />{/if}{/snippet}

{#snippet nodeNameCell(n: RelayNode)}
	<span class="strong">{n.name}</span>{#if n.version}<span class="cell-sub"
			>{t('sites.node_version', { version: n.version })}</span
		>{/if}
{/snippet}

{#snippet nodeStatusCell(n: RelayNode)}
	{@const st = nodeStatus(n)}
	<Status tone={st.tone} label={t(st.key)} />
	{#if n.revoked && n.revoked_at}
		<span class="cell-sub">{t('sites.revoked_on')} <Time value={n.revoked_at} relative={false} /></span>
	{:else if !n.online}
		<span class="cell-sub">{t('sites.last_seen')} <Time value={n.last_seen} empty={t('time.never')} /></span>
	{/if}
{/snippet}

{#snippet nodeAddressCell(n: RelayNode)}
	{#if n.lan_addr || n.public_addr}
		<span class="addr-list">
			{#if n.lan_addr}<span class="addr"
					><span class="addr-kind">{t('sites.addr_lan')}</span>
					<ValueCopy value={n.lan_addr} label={t('sites.addr_lan_named', { name: n.name })} /></span
				>{/if}
			{#if n.public_addr}<span class="addr"
					><span class="addr-kind">{t('sites.addr_public')}</span>
					<ValueCopy value={n.public_addr} label={t('sites.addr_public_named', { name: n.name })} /></span
				>{/if}
		</span>
	{:else}
		<span class="muted">{t('sites.no_addresses')}</span>
	{/if}
{/snippet}

{#snippet nodeSessionsCell(n: RelayNode)}{n.online ? formatNumber(n.active_sessions) : '–'}{/snippet}

{#snippet nodeTrafficCell(n: RelayNode)}
	{#if n.online}
		{t('sites.traffic', { up: formatBytes(n.bytes_up) || '0 B', down: formatBytes(n.bytes_down) || '0 B' })}
	{:else}
		<span class="muted">–</span>
	{/if}
{/snippet}

{#snippet nodeForwardedCell(n: RelayNode)}{n.online && !n.revoked
		? formatNumber(n.forwarded_devices)
		: '–'}{/snippet}

{#snippet nodeActionsCell(n: RelayNode)}
	{#if !n.revoked}
		<Button size="sm" aria-label={t('sites.rename_named', { name: n.name })} onclick={() => void rename(n)}
			>{t('sites.rename')}…</Button
		>
		<Button
			size="sm"
			variant="danger-quiet"
			aria-label={t('sites.revoke_named', { name: n.name })}
			onclick={() => void revoke(n)}>{t('sites.revoke')}…</Button
		>
	{/if}
{/snippet}

{#snippet reachFromCell(r: SiteToSiteRow)}
	<span class="strong">{r.fromSite}</span><span class="cell-sub">{r.fromNode}</span>
{/snippet}
{#snippet reachToCell(r: SiteToSiteRow)}
	<span class="strong">{r.toSite}</span><span class="cell-sub">{r.toNode}</span>
{/snippet}
{#snippet reachViaCell(r: SiteToSiteRow)}{r.via === 'private'
		? t('sites.via_private')
		: t('sites.via_public')}{/snippet}
{#snippet reachResultCell(r: SiteToSiteRow)}
	<Status
		tone={r.ok ? 'good' : 'danger'}
		label={r.ok ? t('sites.reach_ok', { ms: formatNumber(r.rttMs) }) : t('sites.reach_failed')}
	/>
{/snippet}
{#snippet reachCheckedCell(r: SiteToSiteRow)}<Time value={r.checkedAt} />{/snippet}

{#if !allowed}
	<NoAccess />
{:else}
	<div class="page page-wide sites-page">
		<div class="page-head">
			<h1>{t('nav.sites')}</h1>
			<p class="page-description">{t('sites.page_description')}</p>
			{#if canEdit}
				<div class="page-actions">
					<Button
						class="site-add"
						variant="primary"
						icon={ICONS.add}
						onclick={() => (siteDialog = { site: null })}>{t('sites.add_site')}</Button
					>
				</div>
			{/if}
		</div>
		<ReadOnlyHint writes={['server.config', 'org.edit']} />

		{#if data && !data.nodes_enabled}
			<Notice tone="warning" message={t('sites.nodes_off_notice')} />
		{/if}

		{#if !data && !error}
			<States kind="loading" message={t('sites.loading')} />
		{:else if !data}
			<States kind="error" message={error ?? ''} onretry={() => void load()} />
		{:else}
			<section class="section" aria-labelledby="sites-title">
				<div class="section-head"><h2 id="sites-title">{t('sites.list_title')}</h2></div>
				<Table
					rows={sites}
					columns={siteColumns}
					key={(s) => s.id}
					label={t('sites.list_title')}
					onrowclick={(s) => void show(s)}
					rowClass={(s) => s.id === site?.id && 'is-selected'}
					emptyText={canEdit ? t('sites.empty_edit') : t('sites.empty')}
				/>
			</section>

			{#if site}
				{@const summary = siteSummary(site)}
				<section class="section site-detail" aria-labelledby="site-title">
					<div class="section-head">
						<h2 id="site-title" tabindex="-1" bind:this={detailHeading}>{site.name}</h2>
						{#if canEdit}
							<span class="head-actions">
								<Button size="sm" onclick={() => (siteDialog = { site })}>{t('sites.rename')}…</Button>
								<Button size="sm" variant="danger-quiet" onclick={() => void removeSite(site)}
									>{t('sites.delete')}…</Button
								>
							</span>
						{/if}
					</div>
					<p class="section-note">{t(summary.key, summary.params)}</p>
					<Facts items={siteFacts} label={t('sites.site_facts', { name: site.name })} />

					<div class="sub">
						<h3 id="networks-title">{t('sites.networks')}</h3>
						<p class="section-note">{t('sites.networks_note')}</p>
						<NetworksEditor {site} editable={canEdit} onsaved={() => void load()} />
					</div>

					<div class="sub">
						<div class="sub-head">
							<h3 id="nodes-title">{t('sites.nodes')}</h3>
							{#if canEdit && data.nodes_enabled}
								<Button size="sm" icon={ICONS.add} class="node-add" onclick={() => (nodeDialogFor = site.id)}
									>{t('sites.add_node')}</Button
								>
							{/if}
						</div>
						<p class="section-note">{t('sites.nodes_note')}</p>
						{#if forwarding}<p class="section-note">{t('sites.forwarded_note')}</p>{/if}
						<Table
							rows={nodes}
							columns={nodeColumns}
							key={(n) => n.id}
							label={t('sites.nodes_of', { name: site.name })}
							rowClass={(n) => n.revoked && 'is-revoked'}
							emptyText={canEdit && data.nodes_enabled ? t('sites.no_nodes_edit') : t('sites.no_nodes')}
						/>
					</div>
				</section>
			{/if}

			{#if showSiteToSite}
				<section class="section" aria-labelledby="site-to-site-title">
					<div class="section-head"><h2 id="site-to-site-title">{t('sites.site_to_site')}</h2></div>
					<p class="section-note">{t('sites.site_to_site_note')}</p>
					<Table
						rows={siteToSite}
						columns={reachColumns}
						key={(r) => r.key}
						label={t('sites.site_to_site')}
						emptyText={t('sites.site_to_site_empty')}
					/>
				</section>
			{/if}
		{/if}
	</div>
{/if}

{#if siteDialog && data}
	<SiteDialog
		site={siteDialog.site}
		organizations={data.organizations}
		unassigned={data.unassigned}
		onclose={() => (siteDialog = null)}
		onsaved={(s) => {
			siteDialog = null;
			wanted = s.id;
			void load();
		}}
	/>
{/if}

{#if nodeDialogSite}
	<NodeDialog site={nodeDialogSite} onclose={() => (nodeDialogFor = null)} />
{/if}

<style>
	.strong {
		font-weight: 600;
	}
	.cell-sub {
		display: block;
		color: var(--text-muted);
		font-size: var(--text-sm);
	}
	.muted {
		color: var(--text-muted);
	}
	.head-actions {
		display: inline-flex;
		flex-wrap: wrap;
		gap: var(--space-2);
	}
	.site-detail h2:focus {
		outline: none;
	}
	.site-detail h2:focus-visible {
		outline: var(--focus-ring);
		outline-offset: 2px;
	}
	.sub {
		margin-top: var(--space-5);
	}
	.sub h3 {
		margin: 0 0 var(--space-1);
		font-size: var(--text-md, 1rem);
	}
	.sub-head {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-2);
	}
	.addr-list {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.addr {
		display: inline-flex;
		align-items: center;
		gap: var(--space-2);
	}
	.addr-kind {
		min-width: 4.5em;
		color: var(--text-muted);
		font-size: var(--text-sm);
	}
	.sites-page :global(tr.is-selected) {
		background: var(--accent-tint);
	}
	.sites-page :global(tr.is-revoked) {
		color: var(--text-muted);
	}
</style>
