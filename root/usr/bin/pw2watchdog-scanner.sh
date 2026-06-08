#!/bin/sh

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

CONFIG_NAME="pw2watchdog"
STATE_DIR="/var/run/pw2watchdog"
CACHE_FILE="$STATE_DIR/latency_cache.json"
LOCK_FILE="$STATE_DIR/scanner.lock"
SCANNER_PID_FILE="$STATE_DIR/scanner.pid"

mkdir -p "$STATE_DIR"

log() {
	logger -t pw2watchdog-scanner "$*"
}

acquire_lock() {
	local timeout=600
	local waited=0
	while [ -f "$LOCK_FILE" ]; do
		[ "$waited" -ge "$timeout" ] && { log "lock timeout, forcing"; break; }
		sleep 1
		waited=$((waited + 1))
	done
	echo $$ > "$LOCK_FILE"
}

release_lock() {
	rm -f "$LOCK_FILE"
}

EXCLUDE_NODES=""

append_exclude_node() {
	[ -n "$1" ] && EXCLUDE_NODES="$EXCLUDE_NODES $1"
}

is_excluded_node() {
	local node="$1"
	local item
	for item in $EXCLUDE_NODES; do
		[ "$item" = "$node" ] && return 0
	done
	return 1
}

load_cfg() {
	EXCLUDE_NODES=""
	ENV_FILE="/var/run/pw2watchdog/env.static"
	[ -f "$ENV_FILE" ] && . "$ENV_FILE"
	PASSWALL_TEST="${PW2_TEST_SCRIPT:-/usr/share/passwall2/test.sh}"
	PASSWALL_CONFIG="${PW2_PASSWALL_CONFIG:-passwall2}"
	config_load "$CONFIG_NAME"
	config_get SCAN_INTERVAL   main latency_scan_interval '600'
	config_get MAX_LATENCY     main max_latency            '1500'
	config_get NODE_SELECTION  main node_selection         'auto'
	config_get RECOMMENDED_CFG main recommended_candidates '0'
	config_list_foreach main exclude_node append_exclude_node
}

is_real_node() {
	local node="$1"
	local proto type

	[ -n "$node" ] || return 1

	case "$node" in
	examplenode|rulenode) return 1 ;;
	esac

	proto="$(uci -q get ${PASSWALL_CONFIG}.${node}.protocol)"
	case "$proto" in
	_shunt|_balancing|_iface) return 1 ;;
	esac

	type="$(uci -q get ${PASSWALL_CONFIG}.${node}.type)"
	[ -z "$type" ] && [ -z "$proto" ] && return 1

	return 0
}

get_all_nodes() {
	uci show "$PASSWALL_CONFIG" \
		| grep '=nodes' \
		| sed "s/${PASSWALL_CONFIG}\\.\\(.*\\)=nodes/\\1/"
}

measure_node() {
	local node="$1"
	local result code ms

	result="$("$PASSWALL_TEST" url_test_node "$node" 2>/dev/null)"
	[ -n "$result" ] || { echo 0; return 1; }

	code="$(echo "$result" | awk -F: '{print $1}')"
	[ "$code" = "200" ] || [ "$code" = "204" ] || { echo 0; return 1; }

	ms="$(echo "$result" | awk -F: '{
		t = $2 + 0
		if (t > 0) printf "%d", t * 1000
		else print 0
	}')"

	echo "${ms:-0}"
}

node_status() {
	local latency="$1"
	local max="${MAX_LATENCY:-1500}"

	if [ "$latency" -eq 0 ]; then
		echo "red"
	elif [ "$latency" -le 500 ]; then
		echo "green"
	elif [ "$latency" -le "$max" ]; then
		echo "yellow"
	else
		echo "red"
	fi
}

# ---------------------------------------------------------------------------
# Trigger B: scheduled auto-rotation of candidates after scan completion.
# Called only if NODE_SELECTION=auto.
# Takes top RECOMMENDED_CANDIDATES live nodes from the fresh cache,
# compares with current UCI candidate_node, updates on mismatch.
# ---------------------------------------------------------------------------
rotate_candidates_if_auto() {
	[ "${NODE_SELECTION:-auto}" = "auto" ] || return 0
	[ -f "$CACHE_FILE" ] || { log "rotate: no cache file"; return 1; }

	# Get recommended candidate count from env.static (computed by pw2watchdog-env.sh).
	# Fall back to formula if env is not available yet.
	local recommended
	recommended="${HW_RECOMMENDED_CANDIDATES:-}"
	if [ -z "$recommended" ] || [ "$recommended" -lt 1 ]; then
		local timeout check_interval t real_per_node
		timeout="$(uci -q get ${CONFIG_NAME}.main.timeout 2>/dev/null)"
		check_interval="$(uci -q get ${CONFIG_NAME}.main.check_interval 2>/dev/null)"
		t="${timeout:-4}"
		check_interval="${check_interval:-180}"
		real_per_node=$(( t * 9 ))
		[ "$real_per_node" -lt 1 ] && real_per_node=36
		recommended=$(( (check_interval * 6) / (real_per_node * 10) ))
		[ "$recommended" -lt 2  ] && recommended=2
		[ "$recommended" -gt 10 ] && recommended=10
	fi

	# Parse cache: live nodes, sort by latency, take top N.
	# POSIX awk (busybox): match + substr instead of match with array (gawk).
	local new_candidates
	new_candidates="$(awk -v max="$MAX_LATENCY" '
		{
			line = $0
			if (match(line, /"[^"]+":/) == 0) next
			id = substr(line, RSTART+1, RLENGTH-3)
			if (match(line, /"latency": *[0-9]+/) == 0) next
			latstr = substr(line, RSTART, RLENGTH)
			sub(/"latency": */, "", latstr)
			lat = latstr + 0
			if (match(line, /"status": *"[^"]+"/) == 0) next
			ststr = substr(line, RSTART, RLENGTH)
			sub(/"status": *"/, "", ststr)
			sub(/".*/, "", ststr)
			if (lat > 0 && lat <= max && ststr != "red")
				print lat "\t" id
		}
	' "$CACHE_FILE" | sort -n | head -n "$recommended" | awk '{print $2}')"

	[ -n "$new_candidates" ] || { log "rotate: no live nodes found in cache"; return 1; }

	# Exclude excluded nodes
	local filtered=""
	local node
	for node in $new_candidates; do
		is_excluded_node "$node" && { log "rotate: skip excluded node=$node"; continue; }
		filtered="$filtered $node"
	done
	filtered="${filtered# }"

	[ -n "$filtered" ] || { log "rotate: all top nodes are excluded"; return 1; }

	# Read current UCI candidate_node list via uci show
	local current_candidates
	current_candidates="$(uci -q get ${CONFIG_NAME}.main.candidate_node 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"
	# uci get for list returns elements separated by space or newline — normalize
	current_candidates="$(echo "$current_candidates" | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"

	# Compare sorted lists
	local current_sorted new_sorted
	current_sorted="$(echo "$current_candidates" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
	new_sorted="$(echo "$filtered" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

	if [ "$current_sorted" = "$new_sorted" ]; then
		log "rotate: candidate list unchanged ($recommended nodes)"
		return 0
	fi

	log "rotate (planned): old=[$current_candidates] new=[$filtered]"

	# Update UCI
	uci -q delete "${CONFIG_NAME}.main.candidate_node"
	for node in $filtered; do
		uci -q add_list "${CONFIG_NAME}.main.candidate_node=$node"
	done
	uci commit "$CONFIG_NAME"

	log "rotate (planned): done, new candidates: $filtered"
	return 0
}

run_scan() {
	load_cfg
	acquire_lock
	trap "release_lock" EXIT INT TERM

	local ts_start
	ts_start="$(date +%s)"
	log "scan started (node_selection=${NODE_SELECTION:-auto})"

	local tmp_cache="${CACHE_FILE}.tmp"
	printf '{\n' > "$tmp_cache"

	local first=1
	local node latency status label ts_node

	for node in $(get_all_nodes); do
		is_real_node "$node" || continue

		# Excluded nodes are skipped entirely — not measured, not written to cache
		if is_excluded_node "$node"; then
			log "skip excluded node=$node"
			continue
		fi

		ts_node="$(date +%s)"
		latency="$(measure_node "$node")"
		status="$(node_status "$latency")"
		label="$(uci -q get ${PASSWALL_CONFIG}.${node}.remarks)"
		[ -n "$label" ] || label="$node"

		log "node=$node label=$label latency=${latency}ms status=$status"

		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ',\n' >> "$tmp_cache"
		fi

		label="$(echo "$label" | sed 's/\\/\\\\/g; s/"/\\"/g')"

		printf '  "%s": {"latency": %d, "status": "%s", "label": "%s", "ts": %d}' \
			"$node" "$latency" "$status" "$label" "$ts_node" >> "$tmp_cache"
	done

	printf '\n}\n' >> "$tmp_cache"
	mv "$tmp_cache" "$CACHE_FILE"

	local ts_end elapsed
	ts_end="$(date +%s)"
	elapsed=$((ts_end - ts_start))
	log "scan completed in ${elapsed}s"

	# Persist last scan timestamp for Overview page
	if [ -f "$STATE_FILE" ]; then
		if grep -q 'LAST_SCAN_TS' "$STATE_FILE" 2>/dev/null; then
			sed -i "s/LAST_SCAN_TS=[0-9]*/LAST_SCAN_TS=$ts_end/" "$STATE_FILE" 2>/dev/null
		else
			echo "LAST_SCAN_TS=$ts_end" >> "$STATE_FILE"
		fi
	fi

	# Trigger B: scheduled candidate rotation (auto mode only)
	rotate_candidates_if_auto

	release_lock
}

daemon_loop() {
	# Clean exit on SIGTERM/SIGINT
	trap 'rm -f "$SCANNER_PID_FILE"; release_lock; exit 0' TERM INT
	# USR1 — immediate rescan (e.g. after subscription update)
	trap 'log "USR1: immediate rescan requested"; kill_sleep=1' USR1
	echo $$ > "$SCANNER_PID_FILE"
	load_cfg
	run_scan
	while true; do
		load_cfg
		kill_sleep=0
		# Use background sleep + wait so signals interrupt the sleep cleanly
		sleep "$SCAN_INTERVAL" &
		SLEEP_PID=$!
		wait $SLEEP_PID
		rc=$?
		# SIGTERM/SIGINT — exit gracefully
		[ $rc -eq 0 ] || [ "$kill_sleep" -eq 1 ] || { rm -f "$SCANNER_PID_FILE"; release_lock; exit 0; }
		run_scan
	done
}

case "$1" in
scan)   run_scan    ;;
daemon) daemon_loop ;;
*)
	echo "Usage: $0 {scan|daemon}"
	exit 1
	;;
esac
