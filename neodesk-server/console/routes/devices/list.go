package devices

import (
	"math"
	"net/http"
	"time"

	"github.com/neodeskapp/neodesk/neodesk-server/console/access"
	"github.com/neodeskapp/neodesk/neodesk-server/console/goapi"
	"github.com/neodeskapp/neodesk/neodesk-server/console/jsbind"
	"github.com/neodeskapp/neodesk/neodesk-server/console/kit"
	"github.com/neodeskapp/neodesk/neodesk-server/console/routes/internal/jsreq"
	"github.com/neodeskapp/neodesk/neodesk-server/console/sitedata"
)

// sortFields are the fields the list may be ordered by.
var sortFields = map[string]bool{
	"last_online": true, "id": true, "hostname": true, "created_at": true,
	"os": true, "version": true, "username": true, "note": true,
}

// list answers GET /api/devices: the devices of the server and the remote
// targets, with their folder and their device groups, those the account
// may see, filtered and ordered as the query says (search, status,
// hasNotes, includeDeleted, sortBy, sortOrder; no pages). A parameter the
// query gives as a list or an object is ignored.
func (h *handlers) list(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	filters := goapi.DeviceFilters{SortBy: "last_online", SortOrder: "desc"}
	if s, ok := jsreq.Query(r, "sortBy").(string); ok && sortFields[s] {
		filters.SortBy = s
	}
	if order, ok := jsreq.Query(r, "sortOrder").(string); ok {
		if lower := jsbind.ToLower(order); lower == "asc" || lower == "desc" {
			filters.SortOrder = lower
		}
	}
	filters.IncludeDeleted = jsreq.Query(r, "includeDeleted") == "true"
	filters.Search, _ = jsreq.Query(r, "search").(string)
	filters.Status, _ = jsreq.Query(r, "status").(string)
	filters.HasNotes = jsreq.Query(r, "hasNotes") == "true"

	devices, err := h.visible(r, h.backend.GetAllDevices(ctx, filters))
	if err != nil {
		h.serverError(w, r, "Get devices error:", err)
		return
	}
	ids := make([]string, len(devices))
	for i, device := range devices {
		ids[i] = idText(device)
	}
	groups, err := h.groups.DeviceGroupsForPeers(ctx, ids)
	if err != nil {
		// The device list goes out with empty groups
		groups = nil
	}
	for i, device := range devices {
		device.Set("groups", rowsOf(groups[ids[i]]))
	}
	// The site each device is at, on a server that has sites
	if find := h.d.Sites.Finder(); find != nil {
		for i, device := range devices {
			device.Set("site", siteValue(find(ids[i], device.Str("ip"))))
		}
	}
	answer(w, r, http.StatusOK, devicesAnswer{Success: true, Data: deviceList{Devices: devices, Total: len(devices)}})
}

type devicesAnswer struct {
	Success bool       `json:"success"`
	Data    deviceList `json:"data"`
}

type deviceList struct {
	Devices []*goapi.Object `json:"devices"`
	Total   int             `json:"total"`
}

// rowsOf is a list of rows as a JSON list, never null.
func rowsOf(rows []*goapi.Object) []any {
	out := make([]any, len(rows))
	for i, row := range rows {
		out[i] = row
	}
	return out
}

// visible keeps the devices the account may see.
func (h *handlers) visible(r *http.Request, devices []*goapi.Object) ([]*goapi.Object, error) {
	scope, err := h.groups.DeviceScopeForUser(r.Context(), kit.User(r), devices)
	if err != nil {
		return nil, err
	}
	return access.FilterByScope(devices, scope, idText), nil
}

// visibleDevices is every device the account may see, unfiltered and in
// the default order (getVisibleDevicesForRequest).
func (h *handlers) visibleDevices(r *http.Request) ([]*goapi.Object, error) {
	return h.visible(r, h.backend.GetAllDevices(r.Context(), goapi.DeviceFilters{}))
}

// inScope answers 403 and reports false when the account may not see the
// device (rejectIfDeviceOutOfScope). err is a failure of the check, which
// the caller answers as its own.
func (h *handlers) inScope(w http.ResponseWriter, r *http.Request, device *goapi.Object) (bool, error) {
	ok, err := h.groups.UserCanAccessDevice(r.Context(), kit.User(r), device)
	if err != nil {
		return false, err
	}
	if !ok {
		fail(w, r, http.StatusForbidden, "errors.forbidden")
	}
	return ok, nil
}

// allInScope reports whether the account may see every device of ids.
// Each is looked up with the deleted ones; a device the device layer does
// not know is checked by its id alone. The roles that see every device
// pass without a lookup.
func (h *handlers) allInScope(r *http.Request, ids []string) (bool, error) {
	ctx := r.Context()
	user := kit.User(r)
	if len(ids) == 0 || user == nil || access.IsAdminRole(user.Role) {
		return true, nil
	}
	devices := make([]*goapi.Object, len(ids))
	for i, id := range ids {
		if devices[i] = h.backend.GetDeviceByID(ctx, id, true); devices[i] == nil {
			devices[i] = goapi.NewObject("id", id)
		}
	}
	scope, err := h.groups.DeviceScopeForUser(ctx, user, devices)
	if err != nil {
		return false, err
	}
	for _, id := range ids {
		if !scope.Has(id) {
			return false, nil
		}
	}
	return true, nil
}

// found looks the device of the path up and answers 404 or 403 when it
// is none or one the account may not see. ok is false when it answered;
// what names the route in the log of a failure.
func (h *handlers) found(w http.ResponseWriter, r *http.Request, what string) (*goapi.Object, bool) {
	return h.foundOr(w, r, func(err error) { h.serverError(w, r, what, err) })
}

// foundOr is found for a route whose failures answer otherwise: onError
// answers a failure of the scope check.
func (h *handlers) foundOr(w http.ResponseWriter, r *http.Request, onError func(err error)) (*goapi.Object, bool) {
	device := h.backend.GetDeviceByID(r.Context(), r.PathValue("id"), false)
	if device == nil {
		fail(w, r, http.StatusNotFound, "devices.not_found")
		return nil, false
	}
	ok, err := h.inScope(w, r, device)
	if err != nil {
		onError(err)
		return nil, false
	}
	return device, ok
}

// device answers GET /api/devices/{id}: the device, also a deleted one,
// with its system information, the latest metrics and a day of them, its
// telemetry and connection mode, who banned it, and its device groups.
func (h *handlers) device(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")
	device := h.backend.GetDeviceByID(ctx, id, false)
	if device == nil {
		device = h.backend.GetDeviceByID(ctx, id, true)
	}
	if device == nil {
		fail(w, r, http.StatusNotFound, "devices.not_found")
		return
	}
	if ok, err := h.inScope(w, r, device); err != nil || !ok {
		if err != nil {
			h.serverError(w, r, "Get device error:", err)
		}
		return
	}

	// The server keeps the device's basics; they stand in for system
	// information the console has no row of
	basics := func() {
		if !device.Bool("hostname") && !device.Bool("platform") && !device.Bool("version") {
			return
		}
		device.Set("sysinfo", goapi.NewObject(
			"hostname", or(device.Get("hostname"), ""),
			"platform", or(device.Get("platform"), or(device.Get("os"), "")),
			"os_full", or(device.Get("os"), or(device.Get("platform"), "")),
			"version", or(device.Get("version"), ""),
		))
	}
	if row, err := sysinfo(ctx, h.d.Store, id); err != nil || row == nil {
		basics()
	} else {
		device.Set("sysinfo", row)
	}

	if latest, err := metrics(ctx, h.d.Store, id, 1); err == nil && len(latest) > 0 {
		m := latest[0]
		device.Set("metrics", goapi.NewObject(
			"cpu_usage", m.CPU, "memory_usage", m.Memory, "disk_usage", m.Disk, "updated_at", m.CreatedAt,
		))
	}
	// 48 samples: a day of console heartbeats at one every 30 minutes, or
	// about an hour of a NeoDesk client's telemetry
	if history, err := metrics(ctx, h.d.Store, id, 48); err == nil && len(history) > 0 {
		list := make([]any, len(history))
		for i, m := range history {
			sample := goapi.NewObject("cpu", m.CPU, "memory", m.Memory, "disk", m.Disk, "time", m.CreatedAt)
			if m.NetRx.Valid || m.NetTx.Valid {
				sample.Set("net_rx", m.NetRx).Set("net_tx", m.NetTx)
			}
			list[i] = sample
		}
		device.Set("metrics_history", list)
	}

	if telemetry := h.api.GetPeerTelemetry(ctx, id); telemetry.Bool("success") && telemetry.Bool("data") {
		device.Set("telemetry", telemetry.Get("data"))
	}
	if mode := h.api.GetConnectionMode(ctx, id); mode.Bool("success") && mode.Bool("data") {
		device.Set("connection_mode", spread(mode.Get("data")).Set("can_change", kit.HasPermission(r, "device.connection_mode")))
	}

	// Who banned it: the console's own audit entry of the ban, if it fits
	// the time the server reports (a ban made elsewhere has no one here)
	if device.Bool("banned") {
		entry, err := latestAuditEntry(ctx, h.d.Store, "device_banned", "Device "+idText(device)+" banned")
		if err == nil && entry != nil && entry.Username.Valid && entry.Username.String != "" && auditEntryMatchesBan(entryTime(entry), device.Get("banned_at")) {
			device.Set("banned_by", entry.Username.String)
			if !device.Bool("banned_at") {
				device.Set("banned_at", entryTime(entry))
			}
		}
	}

	if groups, err := h.groups.DeviceGroupsForPeer(ctx, id); err == nil && len(groups) > 0 {
		device.Set("groups", rowsOf(groups))
	}
	// Its site and site pin, on a server that has sites
	if h.d.Sites.Finder() != nil {
		folder := int64(0)
		if n := jsreq.Number(device.Get("folder_id")); n > 0 && n <= math.MaxInt32 {
			folder = int64(n)
		}
		p := h.d.Sites.PlacementOf(id, device.Str("ip"), folder)
		device.Set("site", siteValue(p.Site))
		device.Set("site_pin", siteValue(p.Pin))
		device.Set("site_source", p.Source)
		// The relay node it comes through, at a site without internet access
		device.Set("via_node", siteValue(p.ViaNode))
	}
	answer(w, r, http.StatusOK, withData{Success: true, Data: device})
}

// entryTime is the created_at of an audit entry as a value: null, or the
// time as the database's driver handed it over.
func entryTime(e *auditEntry) any {
	if e.CreatedAt.IsNull() {
		return nil
	}
	return e.CreatedAt
}

// viaAPI answers a call into the API server the way the availability
// and session routes do: 502 with its error when it failed, else its data
// (or the whole result when the data is empty).
func viaAPI(w http.ResponseWriter, r *http.Request, result *goapi.Object) {
	if result.Get("success") == false {
		answer(w, r, http.StatusBadGateway, failure{Error: or(result.Get("error"), kit.T(r, "errors.server_error", nil))})
		return
	}
	answer(w, r, http.StatusOK, withData{Success: true, Data: or(result.Get("data"), result)})
}

// availability answers GET /api/devices/{id}/availability?day=&tz_offset=:
// the online and offline changes the server saw on one day. Without
// tz_offset the server's own offset from UTC is sent, as
// Date.getTimezoneOffset gives it.
func (h *handlers) availability(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.found(w, r, "Get device availability error:"); !ok {
		return
	}
	var day any
	if s, ok := jsreq.Query(r, "day").(string); ok && s != "" {
		day = s
	}
	tzOffset := jsreq.Query(r, "tz_offset")
	if tzOffset == nil {
		_, seconds := time.Now().Zone()
		tzOffset = float64(-seconds / 60)
	}
	viaAPI(w, r, h.api.GetPeerAvailability(r.Context(), r.PathValue("id"), day, tzOffset))
}

// connectionSessions answers GET /api/devices/{id}/connection-sessions?limit=:
// the remote sessions the server saw. limit is parseInt of the query, held
// to 1 to 200, and 50 when it is no number.
func (h *handlers) connectionSessions(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.found(w, r, "Get device connection sessions error:"); !ok {
		return
	}
	limit := float64(50)
	if n, ok := jsreq.ParseInt(jsreq.Query(r, "limit"), 10); ok && !math.IsInf(n, 0) {
		limit = math.Min(math.Max(n, 1), 200)
	}
	result := h.api.GetPeerConnectionSessions(r.Context(), r.PathValue("id"), limit)
	withRelays(result, h.d.Sites)
	viaAPI(w, r, result)
}

// siteValue is a site in a device answer: {id, name}, or null.
func siteValue(site *sitedata.SiteRef) any {
	if site == nil {
		return nil
	}
	return goapi.NewObject("id", site.ID, "name", site.Name)
}

// withRelays gives each session of a connection session answer "relay":
// how it was relayed, {kind, nodes?}, read from its relay_via ("direct",
// "central", "lan", or the relay nodes by name). A session the server
// recorded no relay for gets none.
func withRelays(result *goapi.Object, data *sitedata.Service) {
	if result == nil || result.Get("success") == false {
		return
	}
	holder := result
	if inner, ok := result.Get("data").(*goapi.Object); ok {
		holder = inner
	}
	list, _ := holder.Get("sessions").([]any)
	var names sitedata.NodeNames
	for _, item := range list {
		session, ok := item.(*goapi.Object)
		if !ok {
			continue
		}
		via := session.Str("relay_via")
		if via == "" {
			continue
		}
		if names == nil {
			names = data.NodeNames()
		}
		relay := sitedata.RelayOf(via, names)
		if relay.Kind == "" {
			continue
		}
		value := goapi.NewObject("kind", relay.Kind)
		if len(relay.Nodes) > 0 {
			nodes := make([]any, len(relay.Nodes))
			for i, n := range relay.Nodes {
				nodes[i] = goapi.NewObject("id", n.ID, "name", n.Name)
			}
			value.Set("nodes", nodes)
		}
		session.Set("relay", value)
	}
}

// refreshTelemetry answers POST /api/devices/{id}/telemetry/refresh: the
// server queues a hardware inventory on the device. 202 with what it
// said, 502 when it refused.
func (h *handlers) refreshTelemetry(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.found(w, r, "Queue hardware refresh error:"); !ok {
		return
	}
	result := h.api.RefreshPeerHardware(r.Context(), r.PathValue("id"))
	status := http.StatusAccepted
	if result.Get("success") == false {
		status = http.StatusBadGateway
	}
	answer(w, r, status, result)
}

// telemetryCommand answers POST /api/devices/{id}/telemetry/command with
// {command, args}: the server queues an allowed command for the device's
// next heartbeat. 202, or 400 when the server refused.
func (h *handlers) telemetryCommand(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.found(w, r, "Queue telemetry command error:"); !ok {
		return
	}
	command, _ := value(r, "command").(string)
	// A command is one of the agent's tools: it needs that tool's
	// permission and client feature, and one the console does not know is
	// not sent (telemetryTools)
	tool, known := telemetryTools[command]
	if !known {
		answer(w, r, http.StatusBadRequest, goapi.NewObject("success", false, "error", "command_not_allowed"))
		return
	}
	if !h.mayUse(w, r, tool) {
		return
	}
	var args any = goapi.NewObject()
	switch a := value(r, "args").(type) {
	case *goapi.Object, []any:
		if a != nil {
			args = a
		}
	}
	result := h.api.QueuePeerTelemetryCommand(r.Context(), r.PathValue("id"), command, args)
	status := http.StatusAccepted
	if result.Get("success") == false {
		status = http.StatusBadRequest
	}
	answer(w, r, status, result)
}
