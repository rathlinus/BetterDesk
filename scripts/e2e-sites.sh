#!/usr/bin/env bash
# End-to-end run of sites and relay nodes on one Docker host (a throwaway
# VM: it creates Docker networks and containers and needs root).
#
#   wan    198.51.100.0/24  central .10, nodes .11-.13, site gateways .21-.22,
#                           a peer at no site .50
#   siteA  10.1.0.0/24      node A .2, gateway .254 (NAT to wan), computers
#   siteB  10.2.0.0/24      node B .2, gateway .254, computers
#   siteC  10.3.0.0/24      internal: node C .2 (NODE_FORWARD=Y) and a
#                           computer that reaches nothing but node C
#   vpn    10.250.0.0/24    internal: nodes A and B (their VPN)
#
# The peers are fake RustDesk clients (cmd/sites-e2e-peer). Each check
# prints PASS or FAIL; the script exits 1 when any check failed.
#
#   bash scripts/e2e-sites.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/e2e-sites}
GO_IMAGE=${GO_IMAGE:-golang:1.26-alpine}
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/out" "$WORK/central" "$WORK/nodeA" "$WORK/nodeB" "$WORK/nodeC" "$WORK/logs"
FAILS=0

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }

cleanup() {
	docker rm -f central nodeA nodeB nodeC gwA gwB A1 B1 C1 NET1 >/dev/null 2>&1
	for n in wan siteA siteB siteC vpn; do docker network rm "$n" >/dev/null 2>&1; done
}
trap cleanup EXIT
cleanup

say "== build"
docker run --rm -v "$ROOT/neodesk-server:/src" -v "$WORK/bin:/out" -w /src -e CGO_ENABLED=0 "$GO_IMAGE" \
	sh -c 'go build -o /out/neodesk-server . && go build -o /out/peer ./cmd/sites-e2e-peer' || { say "build failed"; exit 1; }
docker build -q -t e2e-base - >/dev/null <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache iptables iproute2
EOF
say "built $(ls "$WORK/bin" | tr '\n' ' ')"

docker network create --subnet 198.51.100.0/24 wan >/dev/null
docker network create --subnet 10.1.0.0/24 siteA >/dev/null
docker network create --subnet 10.2.0.0/24 siteB >/dev/null
docker network create --internal --subnet 10.3.0.0/24 siteC >/dev/null
docker network create --internal --subnet 10.250.0.0/24 vpn >/dev/null

CENTRAL=198.51.100.10
KEYPUB=""

say "== setup: sites A (gateway 198.51.100.21), B (198.51.100.22), C (10.3.0.0/24, no internet)"
docker run --rm -v "$WORK/bin:/bin2:ro" -v "$WORK/central:/data" -v "$WORK/out:/out" e2e-base \
	/bin2/peer setup -db /data/neodesk.db -data /data -control "$CENTRAL:21123" -out /out \
	-site 'A|198.51.100.21/32:public,10.1.0.0/24:private|' \
	-site 'B|198.51.100.22/32:public,10.2.0.0/24:private|' \
	-site 'C|10.3.0.0/24:private|' || exit 1
KEYPUB=$(cat "$WORK/out/key.pub")

start_central() {
	docker rm -f central >/dev/null 2>&1
	docker run -d --name central --network wan --ip "$CENTRAL" \
		-v "$WORK/bin:/bin2:ro" -v "$WORK/central:/data" -w /data \
		-e CONSOLE_PORT=0 -e ENROLLMENT_MODE=open \
		e2e-base /bin2/neodesk-server -mode all -db /data/neodesk.db -key-file /data/id_ed25519 \
		-api-port 21121 -relay-servers "$CENTRAL:21117" -rendezvous-servers central.example.com >/dev/null
}

# node NAME SITE_NET LAN_IP WAN_IP [VPN_IP] [extra -e ...]
node() {
	local name=$1 net=$2 lan=$3 wan=$4 vpnip=$5
	shift 5
	docker rm -f "$name" >/dev/null 2>&1
	local site=${name#node}
	local env=(-e MODE=node -e NODE_DATA_DIR=/data -e "NODE_JOIN=$(cat "$WORK/out/$site.join")"
		-e "NODE_LAN_ADDR=$lan:21117" -e "NODE_PUBLIC_ADDR=$wan:21117")
	if [ -n "$vpnip" ]; then
		env+=(-e "NODE_LEG_LAN_ADDR=$vpnip:21125" -e "NODE_LEG_PUBLIC_ADDR=$wan:21125")
	fi
	docker create --name "$name" --network "$net" --ip "$lan" -v "$WORK/bin:/bin2:ro" -v "$WORK/$name:/data" \
		"${env[@]}" "$@" e2e-base /bin2/neodesk-server node >/dev/null
	docker network connect --ip "$wan" wan "$name"
	if [ -n "$vpnip" ]; then docker network connect --ip "$vpnip" vpn "$name"; fi
	docker start "$name" >/dev/null
}

gateway() { # NAME SITE_NET LAN_IP WAN_IP SUBNET
	docker create --name "$1" --network "$2" --ip "$3" --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
		e2e-base sh -c "iptables -t nat -A POSTROUTING -s $5 ! -d $5 -j MASQUERADE && sleep infinity" >/dev/null
	docker network connect --ip "$4" wan "$1"
	docker start "$1" >/dev/null
}

# A computer at site A or B reaches central through its site's gateway
siteprefix() { case $1 in siteA) echo 10.1.0 ;; siteB) echo 10.2.0 ;; esac; }
on_site() { # NET CMD... (one-shot)
	local net=$1
	shift
	if [ "$net" = siteC ] || [ "$net" = wan ]; then
		docker run --rm --network "$net" -v "$WORK/bin:/bin2:ro" e2e-base "$@"
	else
		docker run --rm --network "$net" --cap-add NET_ADMIN -v "$WORK/bin:/bin2:ro" e2e-base \
			sh -c "ip route replace default via $(siteprefix "$net").254 && exec \"\$@\"" _ "$@"
	fi
}
# Peer ids must have 6 to 16 characters: computer NAME has id PC<NAME>000
pcid() { echo "PC${1}000"; }
computer() { # NAME NET IP ID_SERVER
	local name=$1 net=$2 ip=$3 server=$4
	if [ "$net" = siteC ]; then
		docker run -d --name "$name" --network "$net" --ip "$ip" -v "$WORK/bin:/bin2:ro" e2e-base \
			/bin2/peer target -server "$server" -id "$(pcid "$name")" -key "$KEYPUB" >/dev/null
	else
		docker run -d --name "$name" --network "$net" --ip "$ip" --cap-add NET_ADMIN -v "$WORK/bin:/bin2:ro" e2e-base \
			sh -c "ip route replace default via $(siteprefix "$net").254 && exec /bin2/peer target -server $server -id $(pcid "$name") -key $KEYPUB" >/dev/null
	fi
}

say "== start central, gateways, nodes A, B, C"
start_central
gateway gwA siteA 10.1.0.254 198.51.100.21 10.1.0.0/24
gateway gwB siteB 10.2.0.254 198.51.100.22 10.2.0.0/24
sleep 2
node nodeA siteA 10.1.0.2 198.51.100.11 10.250.0.11
node nodeB siteB 10.2.0.2 198.51.100.12 10.250.0.12
node nodeC siteC 10.3.0.2 198.51.100.13 "" -e NODE_FORWARD=Y
for i in $(seq 1 30); do
	n=$(docker logs central 2>&1 | grep -c "connected from")
	[ "$n" -ge 3 ] && break
	sleep 1
done
docker logs central 2>&1 | grep "\[nodes\] Node .* connected from" | sed 's/^/    /'
nodeid() { docker logs "$1" 2>&1 | grep -o "as node [0-9a-f-]*" | tail -1 | cut -d' ' -f3; }
NA=$(nodeid nodeA)
NB=$(nodeid nodeB)
NC=$(nodeid nodeC)
say "node A $NA, node B $NB, node C $NC"
[ -n "$NA" ] && [ -n "$NB" ] && [ -n "$NC" ] && pass "three nodes enrolled and online" || fail "nodes did not come online"

say "== computers: A1 at site A, B1 at site B, C1 at site C (ID server = node C), NET1 at no site"
computer A1 siteA 10.1.0.10 "$CENTRAL:21116"
computer B1 siteB 10.2.0.10 "$CENTRAL:21116"
computer C1 siteC 10.3.0.10 "10.3.0.2:21116"
docker run -d --name NET1 --network wan --ip 198.51.100.50 -v "$WORK/bin:/bin2:ro" e2e-base \
	/bin2/peer target -server "$CENTRAL:21116" -id "$(pcid NET1)" -key "$KEYPUB" >/dev/null
sleep 5

# connect NAME NET ID_SERVER TARGET: one session; sets OUT, UUID, RELAY
N=0
connect() {
	N=$((N + 1))
	local id net=$2 server=$3 target
	id=$(printf 'INIT%s%04d' "$1" "$N")
	target=$(pcid "$4")
	OUT=$(on_site "$net" /bin2/peer connect -server "$server" -id "$id" -target "$target" -key "$KEYPUB")
	say "    $OUT"
	UUID=$(printf '%s' "$OUT" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
	RELAY=$(printf '%s' "$OUT" | sed -n 's/.*"relay":"\([^"]*\)".*/\1/p')
}
target_relay() { docker logs "$1" 2>&1 | grep "uuid=$UUID" | sed -n 's/.*relay=//p' | tail -1; }
paired_on() { docker logs "$1" 2>&1 | grep "Pair established" | grep -c "${UUID:0:8}"; }
ok() { printf '%s' "$OUT" | grep -q '"ok":true'; }

check_session() { # NAME WANT_INI_RELAY TARGET WANT_TGT_RELAY WANT_NODES...(paired on) ; central must not pair
	local name=$1 want_i=$2 tgt=$3 want_t=$4
	shift 4
	sleep 1
	local tr
	tr=$(target_relay "$tgt")
	local good=1
	ok || good=0
	[ "$RELAY" = "$want_i" ] || good=0
	[ "$tr" = "$want_t" ] || good=0
	local where=""
	for n in "$@"; do
		local c
		c=$(paired_on "$n")
		where="$where $n=$c"
		[ "$c" -ge 1 ] || good=0
	done
	local cc
	cc=$(paired_on central)
	where="$where central=$cc"
	[ "$cc" -eq 0 ] || good=0
	if [ $good = 1 ]; then
		pass "$name: initiator $RELAY, target $tr, paired on$where"
	else
		fail "$name: initiator $RELAY (want $want_i), target $tr (want $want_t), paired on$where"
	fi
}

say "== 1. same site A, through node A only"
connect A siteA "$CENTRAL:21116" A1
check_session "same site A" 198.51.100.11:21117 A1 198.51.100.11:21117 nodeA

say "== 2. site A to site B, over node A and node B (A dials B's public leg)"
connect A siteA "$CENTRAL:21116" B1
check_session "sites A and B" 198.51.100.11:21117 B1 198.51.100.12:21117 nodeA nodeB
docker logs nodeA 2>&1 | grep -q "Leg of UUID ${UUID:0:8} to 198.51.100.12:21125 open" && pass "node A dialed node B's public leg" || fail "node A did not dial node B's public leg"

say "== 3. site C: C1 is cut off from central and registers through node C"
r=$(on_site siteC /bin2/peer reach -addr "$CENTRAL:21116")
say "    from site C: $r"
case $r in unreachable*) pass "site C cannot reach central" ;; *) fail "site C reaches central directly" ;; esac
docker logs C1 2>&1 | grep -q "registered at 10.3.0.2:21116" && pass "C1 registered through node C" || fail "C1 did not register"
o=$(docker run --rm --network wan -v "$WORK/bin:/bin2:ro" e2e-base /bin2/peer online -server "$CENTRAL:21115" -id "$(pcid C1)")
[ "$o" = true ] && pass "C1 shows online at central" || fail "C1 not online at central ($o)"
nt=$(on_site siteC /bin2/peer nattest -server 10.3.0.2:21115)
say "    $nt"
lp=$(echo "$nt" | sed -n 's/.*local port \([0-9]*\),.*/\1/p')
sp=$(echo "$nt" | sed -n 's/.*server saw port \([0-9]*\),.*/\1/p')
[ -n "$lp" ] && [ "$lp" = "$sp" ] && echo "$nt" | grep -q "config update false" && pass "NAT test through node C: same port, no server list" || fail "NAT test through node C"
docker logs central 2>&1 | grep "10.3.0.10" | grep -i "regist" | head -2 | sed 's/^/    central: /'

say "== 4. site A reaches C1: node A and node C"
connect A siteA "$CENTRAL:21116" C1
check_session "site A to site C" 198.51.100.11:21117 C1 10.3.0.2:21117 nodeA nodeC
printf '%s' "$OUT" | grep -q '"signed_by_central":true' && pass "C1's key signed by central's key" || fail "C1's key not signed by central"

say "== 5. C1's site reaches B1: node C and node B"
connect C siteC "10.3.0.2:21116" B1
check_session "site C to site B" 10.3.0.2:21117 B1 198.51.100.12:21117 nodeC nodeB
printf '%s' "$OUT" | grep -q '"signed_by_central":true' && pass "B1's key reaches site C signed by central" || fail "B1's key not signed by central"

say "== 6. same site C: node C only"
connect C siteC "10.3.0.2:21116" C1
check_session "same site C" 10.3.0.2:21117 C1 10.3.0.2:21117 nodeC

say "== 7. a peer at no site reaches C1: node C's public address"
connect N wan "$CENTRAL:21116" C1
check_session "no site to site C" 198.51.100.13:21117 C1 10.3.0.2:21117 nodeC

say "== 8. node B without a public leg address: node B dials node A"
node nodeB siteB 10.2.0.2 198.51.100.12 10.250.0.12 -e NODE_LEG_PUBLIC_ADDR=none
sleep 8
connect A siteA "$CENTRAL:21116" B1
check_session "sites A and B, B without public leg" 198.51.100.11:21117 B1 198.51.100.12:21117 nodeA nodeB
docker logs nodeB 2>&1 | grep -q "Leg of UUID ${UUID:0:8} to 198.51.100.11:21125 open" && pass "node B dialed node A" || fail "node B did not dial node A"

say "== 9. sites A and B in VPN group corp: node A dials node B over the VPN"
docker stop central >/dev/null
docker run --rm -v "$WORK/bin:/bin2:ro" -v "$WORK/central:/data" e2e-base /bin2/peer vpn -db /data/neodesk.db -site A=corp -site B=corp
docker start central >/dev/null
for i in $(seq 1 60); do
	n=$(docker logs --since 90s central 2>&1 | grep -c "connected from")
	[ "$n" -ge 3 ] && break
	sleep 1
done
sleep 5
connect A siteA "$CENTRAL:21116" B1
check_session "sites A and B over the VPN" 198.51.100.11:21117 B1 198.51.100.12:21117 nodeA nodeB
docker logs nodeA 2>&1 | grep -q "Leg of UUID ${UUID:0:8} to 10.250.0.12:21125 open" && pass "node A dialed node B's VPN address" || fail "node A did not dial node B's VPN address"

say "== 10. node A stopped: site A falls back to the central relay"
docker stop nodeA >/dev/null
sleep 3
connect A siteA "$CENTRAL:21116" A1
sleep 1
if ok && [ "$RELAY" = "$CENTRAL:21117" ] && [ "$(paired_on central)" -ge 1 ]; then
	pass "node A down: central relay $RELAY paired the session"
else
	fail "node A down: relay $RELAY, central paired $(paired_on central)"
fi

say "== 11. node C stopped: C1 is not handed the central relay"
docker stop nodeC >/dev/null
sleep 3
connect N wan "$CENTRAL:21116" C1
if printf '%s' "$OUT" | grep -q '"refuse":"Relay temporarily unavailable"' && [ "$(paired_on central)" -eq 0 ]; then
	pass "node C down: session to C1 refused, nothing on the central relay"
else
	fail "node C down: $OUT"
fi

say "== forward and leg audit lines at central"
docker logs central 2>&1 | grep -E "Refused forward|forwarded [0-9]+ streams|opened its UDP forwarding|now comes through" | head -10 | sed 's/^/    /'

for c in central nodeA nodeB nodeC A1 B1 C1 NET1; do docker logs "$c" >"$WORK/logs/$c.log" 2>&1; done
say "== result: $FAILS failed"
if [ "${E2E_DUMP_LOGS:-}" = 1 ]; then
	for c in central nodeA nodeB nodeC C1; do
		echo "----- $c log (filtered) -----"
		grep -E "\[nodes\]|\[node\]|Pair established|relay node|RequestRelay|registered|forward" "$WORK/logs/$c.log" | tail -150
	done
fi
[ "$FAILS" -eq 0 ]
