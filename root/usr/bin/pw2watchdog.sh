#!/bin/sh
# pw2watchdog.sh — watchdog for PassWall2: latency monitoring and automatic node switching.
#
# Usage:
#   pw2watchdog.sh run     — single measurement cycle with switching if needed
#   pw2watchdog.sh daemon  — infinite loop with CHECK_INTERVAL pause between iterations
#
# Dependencies:
#   /usr/bin/pw2watchdog-env.sh  — service discovery (paths, PassWall2 parameters, HW)
#   /lib/functions.sh            — OpenWrt UCI helpers
#   /usr/share/libubox/jshn.sh   — JSON helpers

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

CONFIG_NAME="pw2watchdog"
STATE_DIR="/var/run/pw2watchdog"
ENV_FILE="$STATE_DIR/env.static"
STATE_FILE="$STATE_DIR/state"
STATUS_FILE="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.jsonl"

CURRENT_LATENCY=0
STATUS_RUNNING="false"

mkdir -p "$STATE_DIR"
LOCK_FILE="$STATE_DIR/pw2watchdog.lock"

# ---------------------------------------------------------------------------
# Environment: load env.static (result of pw2watchdog-env.sh resolve).
# If the file is stale or contains errors — force a recalculation.
# ---------------------------------------------------------------------------
load_env() {
	# Run resolve (idempotent, respects TTL)
	if [ -x "/usr/bin/pw2watchdog-env.sh" ]; then
		/usr/bin/pw2watchdog-env.sh resolve
	else
		log "pw2watchdog-env.sh not found — Transit Blackhole disabled"
	fi

	if [ -f "$ENV_FILE" ]; then
		. "$ENV_FILE"
		# Source the env script to get functions like pw2_wait_proxy_ready etc.
		# Entry point is protected against execution when sourced
		[ -f "/usr/bin/pw2watchdog-env.sh" ] && . /usr/bin/pw2watchdog-env.sh
		if [ "${PW2_ENV_ERRORS:-1}" -gt 0 ]; then
			log "env has errors — Transit Blackhole disabled, check Advanced Settings in LuCI"
			PW2_ENV_OK=0
		else
			PW2_ENV_OK=1
		fi
	else
		log "env.static not found — Transit Blackhole disabled"
		PW2_ENV_OK=0
	fi

	# Populate variables from env (with safe defaults)
	PASSWALL_INIT="${PW2_INIT_SCRIPT:-/etc/init.d/passwall2}"
	PASSWALL_TEST="${PW2_TEST_SCRIPT:-/usr/share/passwall2/test.sh}"

	# HW parameters from env (calc_hw_and_recommended is handled in pw2watchdog-env.sh)
	CPU_MODEL="${HW_CPU_MODEL:-unknown}"
	CPU_THREADS="${HW_CPU_THREADS:-1}"
	RAM_TOTAL_MB="${HW_RAM_TOTAL_MB:-0}"
	RECOMMENDED_CANDIDATES="${HW_RECOMMENDED_CANDIDATES:-3}"
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
acquire_lock() {
	local timeout=300 waited=0
	while [ -f "$LOCK_FILE" ]; do
		[ "$waited" -ge "$timeout" ] && { log "lock timeout, forcing"; break; }
		sleep 1
		waited=$((waited + 1))
	done
	echo $$ > "$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE"; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { logger -t pw2watchdog "$*"; }

# ---------------------------------------------------------------------------
# UCI helpers
# ---------------------------------------------------------------------------
append_candidate()    { [ -n "$1" ] && CANDIDATES="$CANDIDATES $1"; }
append_exclude_node() { [ -n "$1" ] && EXCLUDE_NODES="$EXCLUDE_NODES $1"; }

is_excluded_node() {
	local node="$1" item
	for item in $EXCLUDE_NODES; do
		[ "$item" = "$node" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Event history
# ---------------------------------------------------------------------------
append_history() {
	local ts="$1" action="$2" node="$3" reason="$4"
	[ -n "$ts" ]     || ts="$(date +%s)"
	[ -n "$action" ] || action="unknown"
	[ -n "$node" ]   || node="-"
	[ -n "$reason" ] || reason="-"
	local label
	label="$(node_label "$node")"

	mkdir -p "$STATE_DIR"
	json_init
	json_add_int    ts     "$ts"
	json_add_string action "$action"
	json_add_string node   "$node"
	json_add_string label  "$label"
	json_add_string reason "$reason"
	json_dump >> "$HISTORY_FILE"
	printf '\n' >> "$HISTORY_FILE"

	[ -f "$HISTORY_FILE" ] && \
		tail -n 200 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null && \
		mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

# ---------------------------------------------------------------------------
# Node label
# ---------------------------------------------------------------------------
node_label() {
	local node="$1" label
	[ -n "$node" ] || { echo ""; return 0; }
	label="$(uci -q get ${PASSWALL_CONFIG}.${node}.remarks)"
	[ -n "$label" ] || label="$node"
	echo "$label"
}

# ---------------------------------------------------------------------------
# UCI migration: fallback_mode → node_selection + fallback_action (idempotent)
# ---------------------------------------------------------------------------
migrate_uci() {
	local old_mode
	old_mode="$(uci -q get ${CONFIG_NAME}.main.fallback_mode)"
	[ -n "$old_mode" ] || return 0

	log "migrating fallback_mode='$old_mode' to node_selection + fallback_action"

	local new_action
	case "$old_mode" in
	direct)    new_action="direct"    ;;
	blackhole) new_action="blackhole" ;;
	*)         new_action="blackhole" ;;
	esac

	local new_selection
	new_selection="$(uci -q get ${CONFIG_NAME}.main.node_selection)"
	[ -n "$new_selection" ] || new_selection="auto"

	uci -q set    "${CONFIG_NAME}.main.node_selection=${new_selection}"
	uci -q set    "${CONFIG_NAME}.main.fallback_action=${new_action}"
	uci -q delete "${CONFIG_NAME}.main.fallback_mode"  2>/dev/null
	uci -q delete "${CONFIG_NAME}.main.max_candidates" 2>/dev/null
	uci commit "$CONFIG_NAME"

	log "migration done: node_selection=$new_selection fallback_action=$new_action"
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
load_cfg() {
	CANDIDATES=""
	EXCLUDE_NODES=""
	config_load "$CONFIG_NAME"
	config_get ENABLED                       main enabled                       '0'
	config_get PASSWALL_CONFIG               main passwall_config               'passwall2'
	config_get PASSWALL_SECTION              main passwall_section              ''
	config_get CHECK_INTERVAL                main check_interval                '180'
	config_get TIMEOUT                       main timeout                       '4'
	config_get MAX_LATENCY                   main max_latency                   '1500'
	config_get MIN_SWITCH_INTERVAL           main min_switch_interval           '600'
	config_get LATENCY_IMPROVEMENT_THRESHOLD main latency_improvement_threshold '80'
	config_get TEST_URL                      main test_url                      'https://cp.cloudflare.com/generate_204'
	config_get NODE_SELECTION                main node_selection                'auto'
	config_get FALLBACK_ACTION               main fallback_action               'blackhole'
	config_get ROTATE_MAX_ROUNDS             main rotate_max_rounds             '3'
	config_get ROTATE_FINAL_ACTION           main rotate_final_action           'blackhole'
	config_get INITIAL_DEFAULT_NODE          main initial_default_node          ''
	config_list_foreach main candidate_node append_candidate
	config_list_foreach main exclude_node   append_exclude_node
}

# ---------------------------------------------------------------------------
# State persistence across runs
# ---------------------------------------------------------------------------
load_state() {
	LAST_SWITCH=0
	LAST_TARGET=""
	LAST_REASON=""
	LAST_BEST_NODE=""
	LAST_BEST_LATENCY=""
	STATIC_BH_HANDLE=""   # handle of the static blackhole nft DROP rule
	ROTATE_ROUND=0        # current rotation round counter
	ROTATE_OFFSET=0       # current offset into sorted node list
	[ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

save_state() {
	cat > "$STATE_FILE" <<EOFSTATE
LAST_SWITCH=${LAST_SWITCH:-0}
LAST_TARGET='${LAST_TARGET:-}'
LAST_REASON='${LAST_REASON:-}'
LAST_BEST_NODE='${LAST_BEST_NODE:-}'
LAST_BEST_LATENCY='${LAST_BEST_LATENCY:-}'
STATIC_BH_HANDLE='${STATIC_BH_HANDLE:-}'
ROTATE_ROUND=${ROTATE_ROUND:-0}
ROTATE_OFFSET=${ROTATE_OFFSET:-0}
EOFSTATE
}

# ---------------------------------------------------------------------------
# Status for UI
# ---------------------------------------------------------------------------
write_status() {
	local current="$1" target="$2" best="$3" reason="$4" best_latency="$5"
	local candidate_count
	candidate_count="$(echo "$CANDIDATES" | wc -w | awk '{print $1}')"

	json_init
	json_add_string enabled               "${ENABLED:-0}"
	json_add_string passwall_config       "${PASSWALL_CONFIG:-}"
	json_add_string passwall_section      "${PASSWALL_SECTION:-}"
	json_add_string current_node          "${current:-}"
	json_add_string current_label         "$(node_label "$current")"
	json_add_int    current_latency       "${CURRENT_LATENCY:-0}"
	json_add_string initial_default_node  "${INITIAL_DEFAULT_NODE:-}"
	json_add_string initial_default_label "$(node_label "$INITIAL_DEFAULT_NODE")"
	json_add_string best_node             "${best:-}"
	json_add_string best_label            "$(node_label "$best")"
	json_add_int    best_latency          "${best_latency:-0}"
	json_add_string target_node           "${target:-}"
	json_add_string target_label          "$(node_label "$target")"
	json_add_string last_target           "${LAST_TARGET:-}"
	json_add_string last_target_label     "$(node_label "$LAST_TARGET")"
	json_add_string last_reason           "${reason:-}"
	json_add_int    last_switch           "${LAST_SWITCH:-0}"
	json_add_string node_selection        "${NODE_SELECTION:-auto}"
	json_add_string fallback_action       "${FALLBACK_ACTION:-blackhole}"
	json_add_string test_url              "${TEST_URL:-}"
	json_add_int    candidate_count       "${candidate_count:-0}"
	json_add_int    recommended_candidates "${RECOMMENDED_CANDIDATES:-0}"
	json_add_string cpu_model             "${CPU_MODEL:-}"
	json_add_int    cpu_threads           "${CPU_THREADS:-0}"
	json_add_int    ram_total_mb          "${RAM_TOTAL_MB:-0}"
	json_add_string running               "${STATUS_RUNNING:-false}"
	json_dump > "$STATUS_FILE"
}

# ---------------------------------------------------------------------------
# PassWall2: read and set the active node
# ---------------------------------------------------------------------------
get_default_node() {
	uci -q get "${PASSWALL_CONFIG}.${PASSWALL_SECTION}.default_node"
}

# ---------------------------------------------------------------------------
# Transit Blackhole: DROP traffic during sing-box restart.
# Activated only when FALLBACK_ACTION=blackhole AND PW2_ENV_OK=1.
#
# Algorithm:
#   1. Insert DROP rule into nft, save the handle
#   2. Restart PassWall2
#   3. Wait for proxy readiness (UDP port listening)
#   4. Remove the DROP rule
#   5. On any error — remove DROP and return error
# ---------------------------------------------------------------------------
set_default_node() {
	local node="$1"

	uci -q set "${PASSWALL_CONFIG}.${PASSWALL_SECTION}.default_node=$node" || return 1
	uci commit "$PASSWALL_CONFIG" || return 1

	# Determine whether Transit Blackhole is needed
	local use_blackhole=0
	if [ "${FALLBACK_ACTION:-blackhole}" = "blackhole" ] \
	&& [ "${PW2_ENV_OK:-0}" -eq 1 ] \
	&& [ -n "$PW2_NFTABLE_NAME" ] \
	&& [ -n "$PW2_NFTCHAIN_MANGLE" ]; then
		use_blackhole=1
	fi

	if [ "$use_blackhole" -eq 1 ]; then
		_restart_with_blackhole
	else
		_restart_plain
	fi
}

# Plain restart without protection (fallback=direct or env not ready)
_restart_plain() {
	"$PASSWALL_INIT" restart >/dev/null 2>&1
}

# Restart with Transit Blackhole
_restart_with_blackhole() {
	local handle nft_table nft_chain wait_timeout=60
	nft_table="$PW2_NFTABLE_NAME"
	nft_chain="$PW2_NFTCHAIN_MANGLE"

	# 1. Insert DROP as the first rule in the mangle chain
	#    counter — for diagnostics, position 0 — first
	nft insert rule "$nft_table" "$nft_chain" counter drop 2>/dev/null
	if [ $? -ne 0 ]; then
		log "transit blackhole: failed to insert drop rule, falling back to plain restart"
		_restart_plain
		return $?
	fi

	# 2. Get the handle of the inserted rule (first one without a comment — that's ours)
	handle="$(nft -a list chain $nft_table $nft_chain 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1; exit}')"

	if [ -z "$handle" ]; then
		log "transit blackhole: cannot get rule handle, removing drop attempt and falling back"
		# Try to remove by content in case the handle was not found
		nft delete rule "$nft_table" "$nft_chain" \
			handle "$(nft -a list chain $nft_table $nft_chain 2>/dev/null \
				| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1; exit}')" 2>/dev/null
		_restart_plain
		return $?
	fi

	log "transit blackhole: DROP inserted (handle=$handle table='$nft_table' chain='$nft_chain')"

	# 3. Restart PassWall2
	"$PASSWALL_INIT" restart >/dev/null 2>&1

	# 4. Wait for proxy readiness
	# pw2_wait_proxy_ready and pw2_is_proxy_ready are available via load_env
	if pw2_wait_proxy_ready "$wait_timeout"; then
		log "transit blackhole: proxy ready, removing DROP rule"
	else
		log "transit blackhole: timeout waiting for proxy (${wait_timeout}s), removing DROP anyway"
	fi

	# 5. Remove DROP — always, even on timeout
	# PassWall2 restart recreates the chain so the handle may have changed.
	# Re-read the current handle first; fall back to the saved one if not found.
	local cur_handle
	cur_handle="$(nft -a list chain $nft_table $nft_chain 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1; exit}')"
	[ -z "$cur_handle" ] && cur_handle="$handle"

	if [ -n "$cur_handle" ]; then
		nft delete rule "$nft_table" "$nft_chain" handle "$cur_handle" 2>/dev/null
		if [ $? -eq 0 ]; then
			log "transit blackhole: DROP rule removed (handle=$cur_handle)"
		else
			log "transit blackhole: WARNING — failed to remove DROP rule handle=$cur_handle"
			log "transit blackhole: manual fix: nft delete rule $nft_table $nft_chain handle $cur_handle"
		fi
	else
		log "transit blackhole: no DROP rule found in chain, already removed or chain was recreated cleanly"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Latency measurement via PassWall2 test.sh
# ---------------------------------------------------------------------------
measure_latency() {
	local node="$1"
	local result code ms

	[ -n "$node" ] || { echo 0; return 1; }
	[ -f "$PASSWALL_TEST" ] || { echo 0; return 1; }

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

# ---------------------------------------------------------------------------
# Read latency for a node from the scanner cache (do not remeasure live).
# Returns 0 if node not in cache or cache missing.
# ---------------------------------------------------------------------------
read_cache_latency() {
	local node="$1"
	local cache_file="$STATE_DIR/latency_cache.json"
	[ -f "$cache_file" ] || { echo 0; return 1; }
	[ -n "$node" ]       || { echo 0; return 1; }

	awk -v id="$node" 'index($0, "\"" id "\":") > 0 {found=1} found && match($0, /"latency":[[:space:]]*[0-9]+/) {s=substr($0,RSTART,RLENGTH); sub(/"latency":[[:space:]]*/,"",s); print s+0; exit}' "$cache_file"
}

# ---------------------------------------------------------------------------
# Trigger A: emergency candidate refresh from latency_cache.json.
# Called when NODE_SELECTION=auto and all current candidates have gone red.
# ---------------------------------------------------------------------------
emergency_rotate_candidates() {
	local cache_file="$STATE_DIR/latency_cache.json"
	[ -f "$cache_file" ] || { log "auto rotate: no cache file, skip"; return 1; }

	local recommended="${RECOMMENDED_CANDIDATES:-3}"
	[ "$recommended" -lt 1 ] && recommended=3

	local new_candidates
	new_candidates="$(awk -v max="$MAX_LATENCY" '
		{
			line = $0
			if (match(line, /\"[^\"]+\":/) == 0) next
			id = substr(line, RSTART+1, RLENGTH-3)
			if (match(line, /\"latency\": *[0-9]+/) == 0) next
			latstr = substr(line, RSTART, RLENGTH)
			sub(/\"latency\": */, "", latstr)
			lat = latstr + 0
			if (match(line, /\"status\": *\"[^\"]+\"/) == 0) next
			ststr = substr(line, RSTART, RLENGTH)
			sub(/\"status\": *\"/, "", ststr)
			sub(/\".*/, "", ststr)
			if (lat > 0 && lat <= max && ststr != "red")
				print lat "\t" id
		}
	' "$cache_file" | sort -n | head -n "$recommended" | awk '{print $2}')"

	[ -n "$new_candidates" ] || { log "auto rotate: no live nodes in cache"; return 1; }

	local filtered_candidates="" node
	for node in $new_candidates; do
		is_excluded_node "$node" && continue
		filtered_candidates="$filtered_candidates $node"
	done
	filtered_candidates="${filtered_candidates# }"

	[ -n "$filtered_candidates" ] || { log "auto rotate: all top nodes are excluded"; return 1; }

	local current_sorted new_sorted
	current_sorted="$(echo "$CANDIDATES" | tr ' ' '\n' | sort | tr '\n' ' ')"
	new_sorted="$(echo "$filtered_candidates" | tr ' ' '\n' | sort | tr '\n' ' ')"

	if [ "$current_sorted" = "$new_sorted" ]; then
		log "auto rotate: candidate list unchanged"
		return 0
	fi

	log "auto rotate (emergency): old=[$CANDIDATES] new=[$filtered_candidates]"

	uci -q delete "${CONFIG_NAME}.main.candidate_node"
	for node in $filtered_candidates; do
		uci -q add_list "${CONFIG_NAME}.main.candidate_node=$node"
	done
	uci commit "$CONFIG_NAME"

	CANDIDATES="$filtered_candidates"
	log "auto rotate (emergency): done, new candidates: $CANDIDATES"
	return 0
}

# ---------------------------------------------------------------------------
# Target node selection
# ---------------------------------------------------------------------------
choose_target() {
	local node latency
	local all_failed=1

	BEST_NODE=""
	BEST_LATENCY=999999
	CURRENT_NODE="$1"
	CURRENT_LATENCY=0

	# Read current node latency from cache (scanner keeps it fresh)
	if [ -n "$CURRENT_NODE" ]; then
		CURRENT_LATENCY="$(read_cache_latency "$CURRENT_NODE")"
		[ -n "$CURRENT_LATENCY" ] || CURRENT_LATENCY=0
		log "current_node=$CURRENT_NODE latency=${CURRENT_LATENCY}ms (cache)"
	fi

	for node in $CANDIDATES; do
		if is_excluded_node "$node"; then
			log "skip node=$node reason=exclude_node"
			continue
		fi

		latency="$(read_cache_latency "$node")"
		[ -n "$latency" ] || latency=0
		log "candidate=$node latency=${latency}ms (cache)"

		if [ "$latency" -gt 0 ] \
		&& [ "$latency" -le "$MAX_LATENCY" ] \
		&& [ "$latency" -lt "$BEST_LATENCY" ]; then
			BEST_LATENCY="$latency"
			BEST_NODE="$node"
			all_failed=0
		fi
	done

	LAST_BEST_NODE="$BEST_NODE"
	LAST_BEST_LATENCY="$BEST_LATENCY"

	# Trigger A: all candidates failed and mode is auto — emergency rotation from cache
	if [ "$all_failed" -eq 1 ] && [ "${NODE_SELECTION:-auto}" = "auto" ]; then
		log "all candidates failed, attempting emergency auto-rotate"
		if emergency_rotate_candidates; then
			for node in $CANDIDATES; do
				is_excluded_node "$node" && continue
				latency="$(read_cache_latency "$node")"
				[ -n "$latency" ] || latency=0
				log "candidate(after rotate)=$node latency=${latency}ms (cache)"
				if [ "$latency" -gt 0 ] \
				&& [ "$latency" -le "$MAX_LATENCY" ] \
				&& [ "$latency" -lt "$BEST_LATENCY" ]; then
					BEST_LATENCY="$latency"
					BEST_NODE="$node"
					all_failed=0
				fi
			done
		fi
	fi

	LAST_BEST_NODE="$BEST_NODE"
	LAST_BEST_LATENCY="$BEST_LATENCY"

	if [ -n "$BEST_NODE" ]; then
		TARGET_NODE="$BEST_NODE"
		TARGET_REASON="best_latency"
	else
		TARGET_NODE="$CURRENT_NODE"
		TARGET_REASON="all_failed"
	fi
}

# ---------------------------------------------------------------------------
# Static Blackhole: persistent nft DROP without restarting PassWall2.
# Used when all_failed + blackhole.
# Handle is saved in STATE_FILE and removed before switching nodes.
# ---------------------------------------------------------------------------
_static_blackhole_insert() {
	# Already active — do not duplicate
	[ -n "$STATIC_BH_HANDLE" ] && return 0

	[ "${PW2_ENV_OK:-0}" -eq 1 ]  || { log "static blackhole: env not ready, skip"; return 1; }
	[ -n "$PW2_NFTABLE_NAME" ]    || { log "static blackhole: NFT table unknown, skip"; return 1; }
	[ -n "$PW2_NFTCHAIN_MANGLE" ] || { log "static blackhole: NFT chain unknown, skip"; return 1; }

	nft insert rule "$PW2_NFTABLE_NAME" "$PW2_NFTCHAIN_MANGLE" counter drop 2>/dev/null || {
		log "static blackhole: failed to insert DROP rule"
		return 1
	}

	local handle
	handle="$(nft -a list chain "$PW2_NFTABLE_NAME" "$PW2_NFTCHAIN_MANGLE" 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1; exit}')"

	if [ -z "$handle" ]; then
		STATIC_BH_HANDLE="unknown"
		log "static blackhole: DROP inserted but handle not found"
	else
		STATIC_BH_HANDLE="$handle"
		log "static blackhole: DROP inserted (handle=$handle table='$PW2_NFTABLE_NAME' chain='$PW2_NFTCHAIN_MANGLE')"
	fi

	save_state
	return 0
}

_static_blackhole_remove() {
	# Remove ALL drop rules from the mangle chain (not just by saved handle).
	# This handles cases where handle was lost (restart, manual removal, race).
	local h handles removed=0

	handles="$(nft -a list chain "$PW2_NFTABLE_NAME" "$PW2_NFTCHAIN_MANGLE" 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1}')"

	for h in $handles; do
		nft delete rule "$PW2_NFTABLE_NAME" "$PW2_NFTCHAIN_MANGLE" handle "$h" 2>/dev/null
		if [ $? -eq 0 ]; then
			log "static blackhole: DROP removed (handle=$h)"
			removed=$((removed + 1))
		else
			log "static blackhole: WARNING — failed to remove DROP (handle=$h)"
		fi
	done

	[ "$removed" -eq 0 ] && [ -n "$STATIC_BH_HANDLE" ] && \
		log "static blackhole: DROP rule not found (may have been removed already)"

	STATIC_BH_HANDLE=""
	save_state
}

# ---------------------------------------------------------------------------
# Rotate-all fallback: cycle through all non-excluded nodes from cache
# ---------------------------------------------------------------------------
_rotate_all_next_group() {
	local cache_file="$STATE_DIR/latency_cache.json"
	[ -f "$cache_file" ] || { log "rotate_all: no cache file"; return 1; }

	local recommended="${RECOMMENDED_CANDIDATES:-3}"
	[ "$recommended" -lt 1 ] && recommended=3

	# Get all live nodes sorted by latency (excluding excluded)
	local all_sorted
	all_sorted="$(awk -v max="$MAX_LATENCY" '
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
	' "$cache_file" | sort -n | awk '{print $2}')"

	[ -n "$all_sorted" ] || { log "rotate_all: no live nodes in cache"; return 1; }

	# Filter excluded nodes
	local filtered="" node
	for node in $all_sorted; do
		is_excluded_node "$node" && continue
		filtered="$filtered $node"
	done
	filtered="${filtered# }"
	[ -n "$filtered" ] || { log "rotate_all: all nodes excluded"; return 1; }

	local total
	total="$(echo "$filtered" | wc -w)"

	# Pick group starting at ROTATE_OFFSET
	local offset="${ROTATE_OFFSET:-0}"
	[ "$offset" -ge "$total" ] && offset=0

	# Extract next N nodes from offset position
	local group
	group="$(echo "$filtered" | tr ' ' '\n' | tail -n +"$((offset + 1))" | head -n "$recommended" | tr '\n' ' ')"
	group="${group% }"

	# If group is empty (offset at end), wrap around
	if [ -z "$group" ]; then
		offset=0
		group="$(echo "$filtered" | tr ' ' '\n' | head -n "$recommended" | tr '\n' ' ')"
		group="${group% }"
		ROTATE_ROUND=$((ROTATE_ROUND + 1))
		log "rotate_all: wrapped to round $ROTATE_ROUND offset=0"
	else
		# Check if we've advanced past recommended boundary → new round
		local next_offset=$((offset + recommended))
		if [ "$next_offset" -ge "$total" ]; then
			ROTATE_ROUND=$((ROTATE_ROUND + 1))
			ROTATE_OFFSET=0
			log "rotate_all: completed round $ROTATE_ROUND (total=$total)"
		else
			ROTATE_OFFSET=$next_offset
			log "rotate_all: round=$ROTATE_ROUND offset=$ROTATE_OFFSET/$total group=[$group]"
		fi
	fi

	# Best node = first in group (already sorted by latency)
	local best_in_group
	best_in_group="$(echo "$group" | awk '{print $1}')"

	[ -n "$best_in_group" ] || return 1

	log "rotate_all: switching to best_in_group=$best_in_group (candidates: $group)"

	# Update candidates in UCI + memory
	uci -q delete "${CONFIG_NAME}.main.candidate_node"
	for node in $group; do
		uci -q add_list "${CONFIG_NAME}.main.candidate_node=$node"
	done
	uci commit "$CONFIG_NAME"
	CANDIDATES="$group"

	# Override target
	TARGET_NODE="$best_in_group"
	BEST_NODE="$best_in_group"
	return 0
}

# ---------------------------------------------------------------------------
# Fallback policy when all_failed
#
# We do NOT use PassWall2 _blackhole/_direct as target nodes.
# default_node is not changed. should_switch will return false — no restart.
#
# blackhole: insert static nft DROP (without restarting PassWall2)
# direct:    do nothing — traffic flows directly
# ---------------------------------------------------------------------------
apply_fallback_policy() {
	[ "$TARGET_REASON" = "all_failed" ] || return 0

	case "${FALLBACK_ACTION:-blackhole}" in
	rotate_all)
		# Remove static blackhole if it was active
		[ -n "$STATIC_BH_HANDLE" ] && _static_blackhole_remove

		local max_rounds="${ROTATE_MAX_ROUNDS:-3}"
		local final="${ROTATE_FINAL_ACTION:-blackhole}"

		# Check if we've exhausted all rotation rounds
		if [ "${ROTATE_ROUND:-0}" -ge "$max_rounds" ]; then
			log "rotate_all: exhausted $max_rounds rounds, applying final action=$final"
			ROTATE_ROUND=0
			ROTATE_OFFSET=0
			case "$final" in
			direct)
				TARGET_REASON="fallback_direct_all_failed"
				;;
			blackhole|*)
				_static_blackhole_insert
				TARGET_REASON="fallback_blackhole_all_failed"
				;;
			esac
		else
			if _rotate_all_next_group; then
				TARGET_REASON="rotate_all"
			else
				# No live nodes anywhere — apply final action
				log "rotate_all: no live nodes, applying final action=$final"
				ROTATE_ROUND=0
				ROTATE_OFFSET=0
				case "$final" in
				direct)
					TARGET_REASON="fallback_direct_all_failed"
					;;
				blackhole|*)
					_static_blackhole_insert
					TARGET_REASON="fallback_blackhole_all_failed"
					;;
				esac
			fi
		fi
		;;
	direct)
		# If static blackhole was previously active — remove it
		[ -n "$STATIC_BH_HANDLE" ] && {
			log "fallback: switching from blackhole to direct, removing static DROP"
			_static_blackhole_remove
		}
		ROTATE_ROUND=0; ROTATE_OFFSET=0
		TARGET_REASON="fallback_direct_all_failed"
		;;
	blackhole|*)
		# Insert static DROP if not already active
		ROTATE_ROUND=0; ROTATE_OFFSET=0
		_static_blackhole_insert
		TARGET_REASON="fallback_blackhole_all_failed"
		;;
	esac
}

# ---------------------------------------------------------------------------
# Check whether a node switch is needed
# ---------------------------------------------------------------------------
should_switch() {
	local current="$1" target="$2" now="$3" improvement

	[ -n "$target" ]            || return 1
	[ "$target" != "$current" ] || return 1

	# fallback_*_all_failed: target is intentionally = current, do not switch
	case "$TARGET_REASON" in
	fallback_direct_all_failed|fallback_blackhole_all_failed)
		return 1
		;;
	esac

	# If current node is dead (latency=0) — skip suppression, switch immediately
	if [ "$LAST_SWITCH" -gt 0 ] \
	&& [ $((now - LAST_SWITCH)) -lt "$MIN_SWITCH_INTERVAL" ] \
	&& [ "${CURRENT_LATENCY:-0}" -gt 0 ]; then
		LAST_REASON="suppressed_min_switch_interval"
		return 1
	fi

	case "$TARGET_REASON" in
	best_latency)
		if [ -n "$BEST_NODE" ] \
		&& [ "$target" = "$BEST_NODE" ] \
		&& [ -n "$current" ] \
		&& [ "$CURRENT_LATENCY" -gt 0 ] \
		&& [ "$BEST_LATENCY" -gt 0 ]; then
			improvement=$((CURRENT_LATENCY - BEST_LATENCY))
			if [ "$improvement" -lt "$LATENCY_IMPROVEMENT_THRESHOLD" ]; then
				LAST_REASON="suppressed_small_improvement"
				log "suppress switch current=${CURRENT_LATENCY}ms best=${BEST_LATENCY}ms improvement=${improvement}ms threshold=${LATENCY_IMPROVEMENT_THRESHOLD}ms"
				return 1
			fi
		fi
		;;
	esac

	return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
run_once() {
	local now current action status_current history_node

	acquire_lock
	trap "[ -n \"\$STATIC_BH_HANDLE\" ] && _static_blackhole_remove; release_lock" EXIT INT TERM

	# Signal the UI immediately — before any loading
	mkdir -p "$STATE_DIR"
	STATUS_RUNNING="true"
	printf '{"running":"true"}\n' > "$STATUS_FILE"

	# UCI migration (idempotent)
	migrate_uci

	# Load environment (paths, HW) from pw2watchdog-env.sh
	load_env

	load_cfg

	# Full status now that cfg is loaded
	write_status "" "" "" "running" ""

	[ "$ENABLED" = "1" ] || {
		STATUS_RUNNING="false"
		write_status "" "" "" "disabled" ""
		return 0
	}

	[ -n "$PASSWALL_SECTION" ] || {
		log "passwall_section is empty"
		STATUS_RUNNING="false"
		write_status "" "" "" "empty_passwall_section" ""
		return 1
	}

	load_state

	current="$(get_default_node)"
	[ -n "$current" ] || {
		log "current default_node is empty"
		STATUS_RUNNING="false"
		write_status "" "" "" "empty_current_default" ""
		return 1
	}

	now="$(date +%s)"
	action="stay"
	status_current="$current"
	history_node="$current"

	if [ -z "$CANDIDATES" ]; then
		LAST_REASON="no_candidates"
		LAST_TARGET=""
		save_state
		STATUS_RUNNING="false"
		write_status "$current" "" "" "$LAST_REASON" ""
		append_history "$now" "stay" "$current" "$LAST_REASON"
		log "no candidate nodes configured"
		return 1
	fi

	choose_target "$current"

	# If static blackhole is active but nodes are now reachable — remove DROP immediately.
	# This handles the case where the watchdog was restarted while blackhole was active,
	# or nodes recovered before the next all_failed cycle.
	if [ -n "$STATIC_BH_HANDLE" ] && [ "${TARGET_REASON}" != "all_failed" ]; then
		log "static blackhole: nodes recovered, removing stale DROP (handle=$STATIC_BH_HANDLE)"
		_static_blackhole_remove
	fi

	apply_fallback_policy "$current"

	if should_switch "$current" "$TARGET_NODE" "$now"; then
		log "switch current=$current target=$TARGET_NODE reason=$TARGET_REASON best=${BEST_NODE:-none} current_latency=${CURRENT_LATENCY:-0}ms best_latency=${BEST_LATENCY:-0}ms"

		# Before switching, remove the static blackhole if active.
		# Transit Blackhole in set_default_node will insert its own DROP immediately.
		[ -n "$STATIC_BH_HANDLE" ] && _static_blackhole_remove

		if set_default_node "$TARGET_NODE"; then
			LAST_SWITCH="$now"
			LAST_TARGET="$TARGET_NODE"
			LAST_REASON="$TARGET_REASON"
			status_current="$TARGET_NODE"
			history_node="$TARGET_NODE"
			action="switch"

			save_state
			STATUS_RUNNING="false"
			write_status "$status_current" "$TARGET_NODE" "$BEST_NODE" "$LAST_REASON" "$BEST_LATENCY"
			append_history "$now" "$action" "$history_node" "$LAST_REASON"
			return 0
		else
			LAST_REASON="switch_failed"
			LAST_TARGET="$TARGET_NODE"
			save_state
			STATUS_RUNNING="false"
			write_status "$current" "$TARGET_NODE" "$BEST_NODE" "$LAST_REASON" "$BEST_LATENCY"
			append_history "$now" "stay" "$current" "$LAST_REASON"
			log "switch failed target=$TARGET_NODE"
			return 1
		fi
	fi

	LAST_TARGET="$TARGET_NODE"
	# Always use current TARGET_REASON for fallback actions; preserve LAST_REASON only for stay
	case "$TARGET_REASON" in
	fallback_blackhole_all_failed) LAST_REASON="$TARGET_REASON"; action="fallback_blackhole"; history_node="$current" ;;
	fallback_direct_all_failed)    LAST_REASON="$TARGET_REASON"; action="fallback_direct";    history_node="$current" ;;
	*)                             LAST_REASON="${LAST_REASON:-$TARGET_REASON}"; action="stay"; history_node="$current" ;;
	esac

	save_state
	STATUS_RUNNING="false"
	write_status "$current" "$TARGET_NODE" "$BEST_NODE" "$LAST_REASON" "$BEST_LATENCY"
	append_history "$now" "$action" "$history_node" "$LAST_REASON"
	log "hold current=$current target=$TARGET_NODE reason=$LAST_REASON current_latency=${CURRENT_LATENCY:-0}ms best=${BEST_NODE:-none} best_latency=${BEST_LATENCY:-0}ms"
	return 0
}

# Remove any leftover DROP rules from previous process (restart, crash, etc.)
# In blackhole/rotate_all mode: keep PassWall2 on last node, only clean DROP.
# In direct mode: remove DROP so traffic flows through WAN immediately.
_cleanup_stale_drops() {
	[ -n "$PW2_NFTABLE_NAME" ]    || return 0
	[ -n "$PW2_NFTCHAIN_MANGLE" ] || return 0
	local h handles
	handles="$(nft -a list chain "$PW2_NFTABLE_NAME" "$PW2_NFTCHAIN_MANGLE" 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1}')"
	for h in $handles; do
		nft delete rule "$PW2_NFTABLE_NAME" "$PW2_NFTCHAIN_MANGLE" handle "$h" 2>/dev/null \
			&& log "startup: removed stale DROP rule (handle=$h)"
	done
	STATIC_BH_HANDLE=""
	# In blackhole/rotate_all mode — keep current PassWall2 node as-is.
	# The existing node may still be alive; scanner will verify on first cycle.
	case "${FALLBACK_ACTION:-blackhole}" in
	direct)
		log "startup: fallback=direct, traffic flows via WAN until first scan"
		;;
	blackhole|rotate_all|*)
		log "startup: fallback=${FALLBACK_ACTION:-blackhole}, keeping last active node until first scan"
		;;
	esac
}

daemon_loop() {
	# On first start — load env and cfg, then clean up stale DROP rules
	load_env
	load_cfg
	_cleanup_stale_drops
	while true; do
		run_once
		load_cfg
		sleep "$CHECK_INTERVAL"
	done
}

case "$1" in
run)    run_once    ;;
daemon) daemon_loop ;;
*)
	echo "Usage: $0 {run|daemon}"
	exit 1
	;;
esac
