#!/bin/sh
# PW2WD_VERSION: v0.4.0-dev
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
#
# v0.3.0 changes:
#   - rotate_all: rewritten as circular buffer (offset +1 per cycle, not +N)
#   - rotate_all: skip min_switch_interval suppression
#   - rotate_all: logged as separate action in history
#   - PassWall2 health check: detect dead PW2 process and optionally restart it
#   - state/status: LAST_PW2_RESTART timestamp

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

CONFIG_NAME="pw2watchdog"
STATE_DIR="/var/run/pw2watchdog"
ENV_FILE="$STATE_DIR/env.static"
STATE_FILE="$STATE_DIR/state"
STATUS_FILE="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.jsonl"
SCORES_FILE="$STATE_DIR/scores.jsonl"
DECISIONS_FILE="$STATE_DIR/decisions.jsonl"
SCORING_BIN="/usr/bin/pw2watchdog-scoring.sh"

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
# Stale-lock-aware. If the lock file exists but the PID inside is dead
# (process gone or never existed), remove the lock immediately instead of
# waiting the full timeout. This fixes the hang that happens when a previous
# daemon was killed (e.g. by init.d stop / killall -9) without releasing.
acquire_lock() {
	local timeout=30 waited=0 owner
	while [ -f "$LOCK_FILE" ]; do
		owner="$(cat "$LOCK_FILE" 2>/dev/null)"
		if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
			log "stale lock (pid=$owner not running) — removing"
			rm -f "$LOCK_FILE"
			break
		fi
		[ "$waited" -ge "$timeout" ] && { log "lock timeout (held by pid=$owner), forcing"; rm -f "$LOCK_FILE"; break; }
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
# Proxy-check history event (extended schema)
#
# Writes a JSON line with the same base fields as append_history
# (ts, action, node, label, reason) plus proxy-check specific fields:
#   state      — proxy_ok | direct | blackhole | no_response | bad_response
#   ip         — external IP returned by the check URL (may be empty)
#   node_label — PassWall2 node label whose .address matches ext_ip (may be empty)
#
# overview.js currently parses history via JSON.parse() and only reads the
# base fields, so the extra keys are forward-compatible.
# ---------------------------------------------------------------------------
append_proxy_check_history() {
	local ts="$1" current_node="$2" state="$3" ip="$4" node_label="$5" reason="$6"
	[ -n "$ts" ]     || ts="$(date +%s)"
	[ -n "$current_node" ] || current_node="-"
	[ -n "$reason" ] || reason="-"
	local label
	label="$(node_label "$current_node")"

	mkdir -p "$STATE_DIR"
	json_init
	json_add_int    ts         "$ts"
	json_add_string action     "proxy_check"
	json_add_string node       "$current_node"
	json_add_string label      "$label"
	json_add_string reason     "$reason"
	json_add_string state      "$state"
	json_add_string ip         "$ip"
	json_add_string node_label "$node_label"
	json_dump >> "$HISTORY_FILE"
	printf '\n' >> "$HISTORY_FILE"

	[ -f "$HISTORY_FILE" ] && \
		tail -n 200 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null && \
		mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

# ---------------------------------------------------------------------------
# Record a proxy-check event only when something meaningful changed.
#
# Trigger rules (anti-flood — proxy_check runs every PROXY_CHECK_INTERVAL):
#   1. First successful proxy_check after watchdog start
#      (LAST_PROXY_CHECK_STATE_REC is empty).
#   2. State changed against the previously recorded one.
#   3. State is the same but external IP changed (e.g. node-side rotation).
#
# Updates LAST_PROXY_CHECK_STATE_REC / LAST_PROXY_CHECK_IP_REC in memory;
# save_state() will persist them on the next normal save.
# ---------------------------------------------------------------------------
_record_proxy_check_event() {
	local state="$1" ip="$2" node_label="$3" reason="$4"
	[ -n "$state" ] || return 0

	if [ "$state" = "${LAST_PROXY_CHECK_STATE_REC:-}" ] \
		&& [ "$ip" = "${LAST_PROXY_CHECK_IP_REC:-}" ]; then
		return 0
	fi

	local current_node
	current_node="$(get_default_node 2>/dev/null)"
	[ -n "$current_node" ] || current_node="-"

	append_proxy_check_history "${LAST_PROXY_CHECK_TS:-$(date +%s)}" \
		"$current_node" "$state" "$ip" "$node_label" "$reason"

	# Update health counters on real transitions (Stage 2.A v0.4.0).
	# A "drop" is a transition from proxy_ok → any non-proxy_ok state.
	# A "leak" is any transition INTO direct state (regardless of prior).
	_update_health_counters "${LAST_PROXY_CHECK_STATE_REC:-}" "$state"

	LAST_PROXY_CHECK_STATE_REC="$state"
	LAST_PROXY_CHECK_IP_REC="$ip"
}

# ---------------------------------------------------------------------------
# _update_health_counters: persistent counters for Health UI (Commit 8).
#
# Three categories of proxy state transitions:
#
#   drops    — killswitch fired (proxy stopped, no leak to direct)
#              proxy_ok → blackhole / no_response / proxy_no_204
#
#   leaks    — real direct-leak (traffic went out through WAN)
#              proxy_ok → direct  AND outside rotation window
#              ("outside" = > 120s since LAST_SWITCH)
#              In `fallback_action=direct` mode this is BY DESIGN — still
#              count it; UI colors it yellow vs red based on the mode.
#
#   transits — PassWall2 internal rotation gap (xray restart window)
#              proxy_ok → direct  AND within ±120s of LAST_SWITCH
#              Normal operation: PW2 takes 30–60s to restart xray, traffic
#              briefly exits via WAN. Counted separately so leaks count
#              stays clean.
#
# Counters live in $STATE_DIR/health_counters.json:
#   { "drops":    N, "last_drop_ts":    TS,
#     "leaks":    N, "last_leak_ts":    TS,
#     "transits": N, "last_transit_ts": TS }
#
# Read-modify-write via json_init/json_load_file (atomic enough for a
# single-writer daemon; no locking needed).
# ---------------------------------------------------------------------------
_update_health_counters() {
	prev="$1"; curr="$2"
	is_drop=0; is_leak=0; is_transit=0

	# Drop: was proxy_ok, now broken (NOT direct — direct is leak/transit).
	if [ "$prev" = "proxy_ok" ] && [ "$curr" != "proxy_ok" ] && [ "$curr" != "direct" ]; then
		is_drop=1
	fi

	# Direct transition — split into leak vs transit by rotation-window proximity.
	if [ "$curr" = "direct" ] && [ "$prev" != "direct" ]; then
		now_ts="$(date +%s)"
		since_switch=$(( now_ts - ${LAST_SWITCH:-0} ))
		# Negative since_switch (LAST_SWITCH=0 — fresh boot, no switches yet)
		# behaves as "old" — count as leak.
		if [ "${LAST_SWITCH:-0}" -gt 0 ] && [ $since_switch -ge 0 ] && [ $since_switch -le 120 ]; then
			is_transit=1
		else
			is_leak=1
		fi
	fi

	[ $is_drop -eq 0 ] && [ $is_leak -eq 0 ] && [ $is_transit -eq 0 ] && return 0

	counters_file="$STATE_DIR/health_counters.json"
	drops=0; last_drop_ts=0; leaks=0; last_leak_ts=0; transits=0; last_transit_ts=0

	if [ -f "$counters_file" ]; then
		json_load_file "$counters_file" 2>/dev/null
		json_get_var drops drops 2>/dev/null
		json_get_var last_drop_ts last_drop_ts 2>/dev/null
		json_get_var leaks leaks 2>/dev/null
		json_get_var last_leak_ts last_leak_ts 2>/dev/null
		json_get_var transits transits 2>/dev/null
		json_get_var last_transit_ts last_transit_ts 2>/dev/null
		json_cleanup 2>/dev/null
	fi

	# Sanitize — anything non-numeric becomes 0.
	case "$drops"           in ''|*[!0-9]*) drops=0 ;; esac
	case "$last_drop_ts"    in ''|*[!0-9]*) last_drop_ts=0 ;; esac
	case "$leaks"           in ''|*[!0-9]*) leaks=0 ;; esac
	case "$last_leak_ts"    in ''|*[!0-9]*) last_leak_ts=0 ;; esac
	case "$transits"        in ''|*[!0-9]*) transits=0 ;; esac
	case "$last_transit_ts" in ''|*[!0-9]*) last_transit_ts=0 ;; esac

	now="$(date +%s)"
	if [ $is_drop -eq 1 ]; then
		drops=$((drops + 1))
		last_drop_ts="$now"
		log "health_counter: drop $prev→$curr (total=$drops)"
	fi
	if [ $is_leak -eq 1 ]; then
		leaks=$((leaks + 1))
		last_leak_ts="$now"
		log "health_counter: leak $prev→$curr (total=$leaks)"
	fi
	if [ $is_transit -eq 1 ]; then
		transits=$((transits + 1))
		last_transit_ts="$now"
		log "health_counter: transit $prev→$curr (rotation window, total=$transits)"
	fi

	json_init
	json_add_int drops             "$drops"
	json_add_int last_drop_ts      "$last_drop_ts"
	json_add_int leaks             "$leaks"
	json_add_int last_leak_ts      "$last_leak_ts"
	json_add_int transits          "$transits"
	json_add_int last_transit_ts   "$last_transit_ts"
	json_dump > "$counters_file"
}

# ---------------------------------------------------------------------------
# Scoring telemetry (observer mode — Stage 2.A v0.4.0)
#
# Two append-only JSONL streams in $STATE_DIR:
#   scores.jsonl    — per-cycle snapshot of all node scores
#   decisions.jsonl — per-cycle comparison: legacy_target vs scoring_target
#
# Both files are size-capped via _scoring_rotate (default 10 MiB, controlled
# by UCI pw2watchdog.scoring.telemetry_max_mb). When the cap is reached we
# keep the last 50% of the file by line count using tail+mv (atomic enough
# for our purposes — single-writer, append-only).
#
# Layered Robustness: if pw2watchdog-scoring.sh is missing or fails, all
# functions in this block degrade to no-op and never break run_once.
# ---------------------------------------------------------------------------

_scoring_rotate() {
	local file="$1" max_bytes="$2" cur_bytes keep_lines
	[ -f "$file" ] || return 0
	# wc -c is OpenWrt-stock; awk would also work but wc is faster
	cur_bytes="$(wc -c < "$file" 2>/dev/null)"
	[ -n "$cur_bytes" ] || return 0
	[ "$cur_bytes" -lt "$max_bytes" ] && return 0
	keep_lines="$(wc -l < "$file" 2>/dev/null)"
	keep_lines=$((keep_lines / 2))
	[ "$keep_lines" -lt 100 ] && keep_lines=100
	tail -n "$keep_lines" "$file" > "${file}.tmp" 2>/dev/null && \
		mv "${file}.tmp" "$file"
}

# Checks that scoring binary is available.
# We DO NOT source it — scoring.sh redefines global state (CONFIG_NAME,
# STATE_DIR, log(), etc.) that would corrupt pw2watchdog.sh runtime.
# Instead we call it as a subprocess. The 13-node fanout is cheap (one
# fork+exec per node, ~180s cycle) and gives perfect isolation.
_scoring_available() {
	[ -x "$SCORING_BIN" ] || return 1
	return 0
}

# Read a single scoring threshold/weight from UCI with fallback default.
# Avoids sourcing scoring.sh; uses uci directly (same data, no side effects).
_sc_uci() {
	local key="$1" default="$2" val
	val="$(uci -q get pw2watchdog.scoring."$key")"
	[ -n "$val" ] && echo "$val" || echo "$default"
}

# evaluate_decision <current_node> <legacy_target> <legacy_reason>
#   Computes scores for current + all candidates via SUBPROCESS calls to
#   $SCORING_BIN (isolated; no shell state pollution).
#   Sets globals:
#     SCORING_CURRENT_TOTAL   — total score for current node (0..1000) or empty
#     SCORING_BEST_NODE       — node with highest total (excluding current)
#     SCORING_BEST_TOTAL      — total of SCORING_BEST_NODE
#     SCORING_VERDICT         — stay | prefer_switch | force_switch | unavailable
#     SCORING_AGREES          — 1 if scoring would do same as legacy, 0 otherwise
#   Writes to scores.jsonl + decisions.jsonl when telemetry_enabled=1.
#   Never modifies TARGET_NODE / TARGET_REASON — pure observer.
evaluate_decision() {
	local current="$1" legacy_target="$2" legacy_reason="$3"
	local ts node total all_scores
	local sc_crit_thr sc_prev_gap sc_rel_imp sc_telemetry sc_tel_max_mb
	SCORING_CURRENT_TOTAL=""
	SCORING_BEST_NODE=""
	SCORING_BEST_TOTAL=0
	SCORING_VERDICT="unavailable"
	SCORING_AGREES=""

	# Layered Robustness: scoring feature disabled or missing → no-op
	[ "${SCORING_ENABLED:-0}" = "1" ] || return 0
	_scoring_available || { log "scoring: binary missing, observer disabled"; return 0; }

	ts="$(date +%s)"

	# Read thresholds locally (avoid sourcing scoring.sh — it pollutes shell state)
	sc_crit_thr="$(_sc_uci critical_threshold 30)"
	sc_prev_gap="$(_sc_uci preventive_gap 25)"
	sc_rel_imp="$(_sc_uci relative_improvement 30)"
	sc_telemetry="$(_sc_uci telemetry_enabled 1)"
	sc_tel_max_mb="$(_sc_uci telemetry_max_mb 10)"

	# Single call to score_all — cheaper than N calls.
	all_scores="$("$SCORING_BIN" score_all 2>/dev/null)"
	[ -n "$all_scores" ] || { log "scoring: score_all returned empty"; return 0; }

	# Extract current node's total from the all_scores JSON object
	if [ -n "$current" ]; then
		SCORING_CURRENT_TOTAL="$(printf '%s' "$all_scores" | \
			jsonfilter -e "@['$current'].total" 2>/dev/null)"
	fi

	# Find best candidate != current (iterate candidates, not all scored nodes)
	for node in $CANDIDATES; do
		[ "$node" = "$current" ] && continue
		is_excluded_node "$node" 2>/dev/null && continue
		total="$(printf '%s' "$all_scores" | \
			jsonfilter -e "@['$node'].total" 2>/dev/null)"
		[ -n "$total" ] || total=0
		if [ "$total" -gt "$SCORING_BEST_TOTAL" ]; then
			SCORING_BEST_TOTAL="$total"
			SCORING_BEST_NODE="$node"
		fi
	done

	# Verdict (thresholds are 0..100 percentages, scores are 0..1000)
	local cur_total crit_abs gap_abs rel_imp
	cur_total="${SCORING_CURRENT_TOTAL:-0}"
	crit_abs=$((sc_crit_thr * 10))            # e.g. 30% → 300
	gap_abs=$((sc_prev_gap * 10))             # e.g. 25% → 250 (gap in absolute score points)

	if [ -z "$SCORING_CURRENT_TOTAL" ]; then
		SCORING_VERDICT="unavailable"
	elif [ "$cur_total" -lt "$crit_abs" ]; then
		SCORING_VERDICT="force_switch"
	elif [ -n "$SCORING_BEST_NODE" ] \
		&& [ "$SCORING_BEST_TOTAL" -gt "$cur_total" ] \
		&& [ $((SCORING_BEST_TOTAL - cur_total)) -ge "$gap_abs" ]; then
		if [ "$cur_total" -gt 0 ]; then
			rel_imp=$(( (SCORING_BEST_TOTAL - cur_total) * 100 / cur_total ))
			if [ "$rel_imp" -ge "$sc_rel_imp" ]; then
				SCORING_VERDICT="prefer_switch"
			else
				SCORING_VERDICT="stay"
			fi
		else
			SCORING_VERDICT="prefer_switch"
		fi
	else
		SCORING_VERDICT="stay"
	fi

	# Compare with legacy decision
	local legacy_action="stay"
	if [ -n "$legacy_target" ] && [ "$legacy_target" != "$current" ]; then
		legacy_action="switch"
	fi
	case "$SCORING_VERDICT" in
		stay|unavailable) [ "$legacy_action" = "stay" ] && SCORING_AGREES=1 || SCORING_AGREES=0 ;;
		prefer_switch|force_switch) [ "$legacy_action" = "switch" ] && SCORING_AGREES=1 || SCORING_AGREES=0 ;;
	esac

	# Telemetry
	[ "$sc_telemetry" = "1" ] || return 0

	_append_scores_line "$ts" "$current" "$all_scores" "$sc_tel_max_mb"
	_append_decisions_line "$ts" "$current" "$legacy_target" "$legacy_reason" "$legacy_action" "$sc_tel_max_mb"
}

# Internal: dumps one line with current + all candidates' scores.
_append_scores_line() {
	local ts="$1" current="$2" all_scores="$3" max_mb="$4"
	mkdir -p "$STATE_DIR"
	[ -n "$all_scores" ] || return 0
	printf '{"ts":%d,"current":"%s","scores":%s}\n' \
		"$ts" "$current" "$all_scores" >> "$SCORES_FILE"
	_scoring_rotate "$SCORES_FILE" $((max_mb * 1024 * 1024))
}

_append_decisions_line() {
	local ts="$1" current="$2" legacy_target="$3" legacy_reason="$4"
	local legacy_action="$5" max_mb="$6"
	mkdir -p "$STATE_DIR"
	json_init
	json_add_int    ts                  "$ts"
	json_add_string current             "$current"
	json_add_string legacy_target       "$legacy_target"
	json_add_string legacy_reason       "$legacy_reason"
	json_add_string legacy_action       "$legacy_action"
	json_add_int    current_total       "${SCORING_CURRENT_TOTAL:-0}"
	json_add_string scoring_best_node   "${SCORING_BEST_NODE:-}"
	json_add_int    scoring_best_total  "${SCORING_BEST_TOTAL:-0}"
	json_add_string scoring_verdict     "$SCORING_VERDICT"
	json_add_int    agrees              "${SCORING_AGREES:-0}"
	json_add_string advisory_mode       "${SCORING_ADVISORY:-1}"
	# json_dump returns a single line with trailing newline — do NOT add extra \n.
	# But the produced JSON has spaces around keys (pretty-ish); that's fine
	# for jsonfilter consumers and for human inspection.
	json_dump >> "$DECISIONS_FILE"
	_scoring_rotate "$DECISIONS_FILE" $((max_mb * 1024 * 1024))
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
	config_get PW2_RESTART_ON_FAILURE        advanced pw2_restart_on_failure    '0'
	config_get INITIAL_DEFAULT_NODE          main initial_default_node          ''
	# Default '1': proxy_check is the primary Health signal. Section may pre-exist
	# from older installs without this option — explicit default keeps it ON.
	# Belt-and-suspenders: config_get default arg is unreliable under busybox ash
	# when section type ≠ 'config' — so we also apply ${VAR:=default} guard.
	config_get PROXY_CHECK_ENABLED           advanced proxy_check_enabled       '1'
	: ${PROXY_CHECK_ENABLED:=1}
	config_get PROXY_CHECK_INTERVAL          advanced proxy_check_interval      '120'
	: ${PROXY_CHECK_INTERVAL:=120}
	config_get PROXY_CHECK_URL               advanced proxy_check_url           'https://api.ipify.org'
	: ${PROXY_CHECK_URL:=https://api.ipify.org}
	config_get DIRECT_IP_RANGES              advanced direct_ip_ranges          ''
	config_list_foreach main candidate_node append_candidate
	config_list_foreach main exclude_node   append_exclude_node

	# Scoring config (Stage 2.A v0.4.0) — observer mode by default.
	# If scoring section doesn't exist (old install), all flags default to safe values.
	config_get SCORING_ENABLED       scoring enabled            '0'
	config_get SCORING_ADVISORY      scoring advisory_mode      '1'

	# Real connectivity check (Stage 2.A v0.4.0) — curl 204 probe through SOCKS.
	# Detects "tunnel alive but real traffic not flowing" — the TojlU605 edge case.
	# Layered Robustness: connectivity check is now ON by default; user can disable in UI.
	# Default '1' for fresh installs; if 'connectivity' section is missing entirely,
	# config_get still returns this default. Disable explicitly via UI if not needed.
	config_get CONN_CHECK_ENABLED      connectivity enabled             '1'
	: ${CONN_CHECK_ENABLED:=1}
	config_get CONN_CHECK_SOCKS_AUTO   connectivity socks_port_auto     '1'
	: ${CONN_CHECK_SOCKS_AUTO:=1}
	config_get CONN_CHECK_SOCKS_MANUAL connectivity socks_port_manual   ''
	config_get CONN_CHECK_URL          connectivity test_url            'https://www.google.com/generate_204'
	: ${CONN_CHECK_URL:=https://www.google.com/generate_204}
	config_get CONN_CHECK_TIMEOUT      connectivity timeout             '5'
	: ${CONN_CHECK_TIMEOUT:=5}
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
	ROTATE_ROUND=0        # current rotation round (circular buffer full-cycle counter)
	ROTATE_OFFSET=0       # current position in the circular node buffer (advances by 1 per cycle)
	LAST_PW2_RESTART=0   # unix timestamp of last PassWall2 restart triggered by watchdog
	LAST_PROXY_CHECK_TS=0  # unix timestamp of last proxy connection check
	LAST_PROXY_CHECK_STATE_REC=""   # last proxy_check state actually written to history
	LAST_PROXY_CHECK_IP_REC=""      # last proxy_check ext_ip actually written to history
	[ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

save_state() {
	# LAST_SCAN_TS is written by pw2watchdog-scanner.sh (a separate process).
	# We must NOT overwrite it with our stale in-memory value.
	# Re-read the freshest value from the state file right before writing.
	local fresh_scan_ts
	fresh_scan_ts="$(grep -m1 '^LAST_SCAN_TS=' "$STATE_FILE" 2>/dev/null \
		| cut -d= -f2)"
	# Keep whichever is larger: in-memory (from previous load) or on-disk (scanner-written)
	if [ -n "$fresh_scan_ts" ] && [ "$fresh_scan_ts" -gt "${LAST_SCAN_TS:-0}" ] 2>/dev/null; then
		LAST_SCAN_TS="$fresh_scan_ts"
	fi

	cat > "$STATE_FILE" <<EOFSTATE
LAST_SWITCH=${LAST_SWITCH:-0}
LAST_TARGET='${LAST_TARGET:-}'
LAST_REASON='${LAST_REASON:-}'
LAST_BEST_NODE='${LAST_BEST_NODE:-}'
LAST_BEST_LATENCY='${LAST_BEST_LATENCY:-}'
STATIC_BH_HANDLE='${STATIC_BH_HANDLE:-}'
ROTATE_ROUND=${ROTATE_ROUND:-0}
ROTATE_OFFSET=${ROTATE_OFFSET:-0}
LAST_SCAN_TS=${LAST_SCAN_TS:-0}
LAST_PW2_RESTART=${LAST_PW2_RESTART:-0}
LAST_PROXY_CHECK_TS=${LAST_PROXY_CHECK_TS:-0}
LAST_PROXY_CHECK_STATE_REC='${LAST_PROXY_CHECK_STATE_REC:-}'
LAST_PROXY_CHECK_IP_REC='${LAST_PROXY_CHECK_IP_REC:-}'
EOFSTATE
}

# ---------------------------------------------------------------------------
# Status for UI
# ---------------------------------------------------------------------------
write_status() {
	# ----- C8 hardening: ALL subshells/UCI lookups BEFORE json_init -----
	# Background: busybox ash silently aborts the rest of the function when
	# certain subshell patterns interact with the json_init/json_add_* state.
	# Symptom: status.json contained ONLY the tail block (health_counters and
	# proxy_check) because write_status died early and json_init implicitly
	# restarted later in the health-counter block.
	# Fix: compute everything that needs $(...) or uci first, into plain vars,
	# then call ONLY pure json_add_* between json_init and json_dump.

	local current="$1" target="$2" best="$3" reason="$4" best_latency="$5"
	local candidate_count
	candidate_count="$(echo "$CANDIDATES" | wc -w | awk '{print $1}')"

	# Pre-compute all labels (no subshells inside json_init block).
	_PW2WD_LBL_CURRENT="$(node_label "$current")"
	_PW2WD_LBL_BEST="$(node_label "$best")"
	_PW2WD_LBL_BEST_ALT="$(node_label "$BEST_ALT_NODE")"
	_PW2WD_LBL_TARGET="$(node_label "$target")"
	_PW2WD_LBL_LAST_TARGET="$(node_label "$LAST_TARGET")"
	_PW2WD_LBL_INITIAL="$(node_label "$INITIAL_DEFAULT_NODE")"

	# Pre-compute UCI-derived values.
	_PW2WD_PW_DEFAULT="$(uci -q get "${PASSWALL_CONFIG:-passwall2}.${PASSWALL_SECTION:-rulenode}.default_node" 2>/dev/null)"
	_PW2WD_LBL_PW_DEFAULT="$(node_label "$_PW2WD_PW_DEFAULT")"

	# passwall_running: PassWall2 enabled in UCI (intent).
	_PW2WD_PW_RUNNING="false"
	_PW2WD_PW_ENABLED="$(uci -q get "${PASSWALL_CONFIG:-passwall2}.@global[0].enabled" 2>/dev/null)"
	[ "$_PW2WD_PW_ENABLED" = "1" ] && _PW2WD_PW_RUNNING="true"

	# passwall_alive: xray process actually running.
	_PW2WD_XRAY_ALIVE="false"
	pgrep -f '/xray' >/dev/null 2>&1 && _PW2WD_XRAY_ALIVE="true"

	# Health counters: read BEFORE json_init (json_load_file conflicts with init).
	_PW2WD_HC_DROPS=0
	_PW2WD_HC_DROP_TS=0
	_PW2WD_HC_LEAKS=0
	_PW2WD_HC_LEAK_TS=0
	_PW2WD_HC_TRANSITS=0
	_PW2WD_HC_TRANSIT_TS=0
	if [ -f "$STATE_DIR/health_counters.json" ]; then
		json_load_file "$STATE_DIR/health_counters.json" 2>/dev/null
		json_get_var _PW2WD_HC_DROPS drops 2>/dev/null
		json_get_var _PW2WD_HC_DROP_TS last_drop_ts 2>/dev/null
		json_get_var _PW2WD_HC_LEAKS leaks 2>/dev/null
		json_get_var _PW2WD_HC_LEAK_TS last_leak_ts 2>/dev/null
		json_get_var _PW2WD_HC_TRANSITS transits 2>/dev/null
		json_get_var _PW2WD_HC_TRANSIT_TS last_transit_ts 2>/dev/null
		json_cleanup 2>/dev/null
	fi
	case "$_PW2WD_HC_DROPS"       in ''|*[!0-9]*) _PW2WD_HC_DROPS=0 ;; esac
	case "$_PW2WD_HC_DROP_TS"     in ''|*[!0-9]*) _PW2WD_HC_DROP_TS=0 ;; esac
	case "$_PW2WD_HC_LEAKS"       in ''|*[!0-9]*) _PW2WD_HC_LEAKS=0 ;; esac
	case "$_PW2WD_HC_LEAK_TS"     in ''|*[!0-9]*) _PW2WD_HC_LEAK_TS=0 ;; esac
	case "$_PW2WD_HC_TRANSITS"    in ''|*[!0-9]*) _PW2WD_HC_TRANSITS=0 ;; esac
	case "$_PW2WD_HC_TRANSIT_TS"  in ''|*[!0-9]*) _PW2WD_HC_TRANSIT_TS=0 ;; esac

	# ----- Now the pure json block: only ${vars}, no $(...) calls -----
	json_init
	json_add_string enabled               "${ENABLED:-0}"
	json_add_string passwall_config       "${PASSWALL_CONFIG:-}"
	json_add_string passwall_section      "${PASSWALL_SECTION:-}"
	json_add_string current_node          "${current:-}"
	json_add_string current_label         "${_PW2WD_LBL_CURRENT:-}"
	json_add_string passwall_default_node  "${_PW2WD_PW_DEFAULT:-}"
	json_add_string passwall_default_label "${_PW2WD_LBL_PW_DEFAULT:-}"
	json_add_int    current_latency       "${CURRENT_LATENCY:-0}"
	json_add_string initial_default_node  "${INITIAL_DEFAULT_NODE:-}"
	json_add_string initial_default_label "${_PW2WD_LBL_INITIAL:-}"
	json_add_string best_node             "${best:-}"
	json_add_string best_label            "${_PW2WD_LBL_BEST:-}"
	json_add_int    best_latency          "${best_latency:-0}"
	json_add_string best_alt_node         "${BEST_ALT_NODE:-}"
	json_add_string best_alt_label        "${_PW2WD_LBL_BEST_ALT:-}"
	json_add_int    best_alt_latency      "${BEST_ALT_LATENCY:-0}"
	json_add_string target_node           "${target:-}"
	json_add_string target_label          "${_PW2WD_LBL_TARGET:-}"
	json_add_string last_target           "${LAST_TARGET:-}"
	json_add_string last_target_label     "${_PW2WD_LBL_LAST_TARGET:-}"
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
	json_add_string passwall_running      "${_PW2WD_PW_RUNNING:-false}"
	json_add_string passwall_alive        "${_PW2WD_XRAY_ALIVE:-false}"
	json_add_int health_drops             "$_PW2WD_HC_DROPS"
	json_add_int health_last_drop_ts      "$_PW2WD_HC_DROP_TS"
	json_add_int health_leaks             "$_PW2WD_HC_LEAKS"
	json_add_int health_last_leak_ts      "$_PW2WD_HC_LEAK_TS"
	json_add_int health_transits          "$_PW2WD_HC_TRANSITS"
	json_add_int health_last_transit_ts   "$_PW2WD_HC_TRANSIT_TS"
	json_add_int    last_scan_ts          "${LAST_SCAN_TS:-0}"
	json_add_int    last_pw2_restart      "${LAST_PW2_RESTART:-0}"
	json_add_string proxy_check_enabled   "${PROXY_CHECK_ENABLED:-0}"
	json_add_string proxy_check_state      "${PROXY_CHECK_STATE:-}"
	json_add_string proxy_check_ip         "${PROXY_CHECK_IP:-}"
	json_add_string proxy_check_node_label "${PROXY_CHECK_NODE_LABEL:-}"
	json_add_int    proxy_check_ts         "${LAST_PROXY_CHECK_TS:-0}"
	json_add_string conn_check_enabled     "${CONN_CHECK_ENABLED:-0}"
	json_add_string conn_check_port        "${CONN_CHECK_PORT:-}"
	json_add_string conn_check_http        "${CONN_CHECK_HTTP:-}"
	json_add_string conn_check_reason      "${CONN_CHECK_REASON:-}"
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
	local nft_err insert_rc attempt
	nft_table="$PW2_NFTABLE_NAME"
	nft_chain="$PW2_NFTCHAIN_MANGLE"

	# C9.1: pre-check that the table/chain actually exist before inserting.
	# If PassWall2 already went down (after subscription update / node change),
	# the nft table may be missing — there is no point in retrying then, the
	# chain is gone and we must fall back to plain restart so PW2 recreates it.
	if ! nft list chain $nft_table "$nft_chain" >/dev/null 2>&1; then
		log "transit blackhole: chain '$nft_chain' missing in table '$nft_table' \
(PassWall2 already down?) — falling back to plain restart"
		_restart_plain
		return $?
	fi

	# 1. Insert DROP as the first rule in the mangle chain.
	#    counter — for diagnostics, position 0 — first.
	#    Retry up to 3 times with 200ms backoff to ride out micro-windows
	#    when PW2 is rebuilding the chain in parallel.
	insert_rc=1
	attempt=0
	while [ $attempt -lt 3 ]; do
		nft_err="$(nft insert rule $nft_table "$nft_chain" counter drop 2>&1)"
		insert_rc=$?
		[ $insert_rc -eq 0 ] && break
		attempt=$(( attempt + 1 ))
		log "transit blackhole: insert attempt $attempt failed rc=$insert_rc nft=\"$nft_err\""
		# No backoff sleep — every ms here is leaked traffic. busybox `usleep`
		# is not guaranteed; we trust the pre-check above + just retry fast.
	done
	if [ $insert_rc -ne 0 ]; then
		log "transit blackhole: failed to insert drop rule after 3 attempts (nft: \"$nft_err\"), falling back to plain restart"
		_restart_plain
		return $?
	fi

	# 2. Get the handle of the inserted rule (first one without a comment — that's ours)
	handle="$(nft -a list chain $nft_table $nft_chain 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1; exit}')"

	if [ -z "$handle" ]; then
		log "transit blackhole: cannot get rule handle, removing drop attempt and falling back"
		# Try to remove by content in case the handle was not found
		nft delete rule $nft_table "$nft_chain" \
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
	# Re-read DROP handle from the chain — PassWall2 restart recreates the chain
	# so the original handle may be gone. If no DROP found, it was already removed.
	local cur_handle
	cur_handle="$(nft -a list chain $nft_table $nft_chain 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1; exit}')"

	if [ -z "$cur_handle" ]; then
		# No DROP rule in chain — PW2 restart already cleaned it up, nothing to do
		log "transit blackhole: DROP rule gone (chain recreated by PW2 restart), nothing to remove"
	elif nft delete rule $nft_table "$nft_chain" handle "$cur_handle" 2>/dev/null; then
		log "transit blackhole: DROP rule removed (handle=$cur_handle)"
	else
		# Rule disappeared between read and delete — also fine
		log "transit blackhole: DROP rule already gone (handle=$cur_handle)"
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
	BEST_ALT_NODE=""       # best candidate != current node (for UI display only)
	BEST_ALT_LATENCY=999999
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

		# Track best alternative: best candidate that is not the current active node
		if [ "$node" != "$CURRENT_NODE" ] \
		&& [ "$latency" -gt 0 ] \
		&& [ "$latency" -le "$MAX_LATENCY" ] \
		&& [ "$latency" -lt "$BEST_ALT_LATENCY" ]; then
			BEST_ALT_LATENCY="$latency"
			BEST_ALT_NODE="$node"
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

	# If BEST_ALT_NODE was not found in regular loop (e.g. single candidate = current),
	# try to find it from the updated CANDIDATES after emergency rotate
	if [ -z "$BEST_ALT_NODE" ]; then
		for node in $CANDIDATES; do
			is_excluded_node "$node" && continue
			[ "$node" = "$CURRENT_NODE" ] && continue
			latency="$(read_cache_latency "$node")"
			[ -n "$latency" ] || latency=0
			if [ "$latency" -gt 0 ] \
			&& [ "$latency" -le "$MAX_LATENCY" ] \
			&& [ "$latency" -lt "$BEST_ALT_LATENCY" ]; then
				BEST_ALT_LATENCY="$latency"
				BEST_ALT_NODE="$node"
			fi
		done
	fi

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

	nft insert rule $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" counter drop 2>/dev/null || {
		log "static blackhole: failed to insert DROP rule"
		return 1
	}

	local handle
	handle="$(nft -a list chain $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" 2>/dev/null \
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

	handles="$(nft -a list chain $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1}')"

	for h in $handles; do
		nft delete rule $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" handle "$h" 2>/dev/null
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
# rotate_all fallback: circular buffer over all live non-excluded nodes.
#
# Algorithm (v0.3):
#   - Build list of all live nodes from latency_cache.json, sorted by latency.
#   - ROTATE_OFFSET is a cursor (0..total-1) into that list.
#   - Each call advances the cursor by exactly 1 step (not by recommended_candidates).
#   - Active pool = window of recommended_candidates nodes starting at cursor,
#     wrapping around the end of the list (circular via doubled list trick).
#   - When cursor wraps past total → ROTATE_ROUND++.
#   - After max_rounds full rotations → apply final action.
#
# Granularity: if 1 proxy died we try 1 new candidate each cycle;
# if N died we naturally fill the pool with fresh nodes over N cycles.
# ---------------------------------------------------------------------------
_rotate_all_step() {
	local cache_file="$STATE_DIR/latency_cache.json"
	[ -f "$cache_file" ] || { log "rotate_all: no cache file"; return 1; }

	local recommended="${RECOMMENDED_CANDIDATES:-3}"
	[ "$recommended" -lt 1 ] && recommended=3

	# --- Build sorted live-node list from cache ---
	# Live = latency > 0, latency <= MAX_LATENCY, status != red
	local all_live
	all_live="$(awk -v max="$MAX_LATENCY" '
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

	[ -n "$all_live" ] || { log "rotate_all: no live nodes in cache"; return 1; }

	# --- Filter excluded nodes ---
	local live="" node
	for node in $all_live; do
		is_excluded_node "$node" && continue
		live="$live $node"
	done
	live="${live# }"
	[ -n "$live" ] || { log "rotate_all: all nodes excluded"; return 1; }

	local total
	total="$(echo "$live" | wc -w)"

	# --- Circular cursor: detect full-round wrap ---
	# If cursor is at or past the end, we just completed a full loop.
	local offset="${ROTATE_OFFSET:-0}"
	if [ "$offset" -ge "$total" ]; then
		offset=0
		ROTATE_ROUND=$((ROTATE_ROUND + 1))
		log "rotate_all: full round completed → round=$ROTATE_ROUND total=$total"
	fi

	# --- Build active pool via circular window ---
	# Double the list so we can extract a contiguous window even when it wraps.
	local pool best_node
	pool="$(printf '%s\n%s\n' "$live" "$live" \
		| tr ' ' '\n' \
		| grep -v '^$' \
		| tail -n +"$((offset + 1))" \
		| head -n "$recommended" \
		| tr '\n' ' ')"
	pool="${pool% }"

	# Best node = first in pool (lowest latency at cursor position)
	best_node="$(echo "$pool" | awk '{print $1}')"
	[ -n "$best_node" ] || { log "rotate_all: empty pool (offset=$offset total=$total)"; return 1; }

	# Advance cursor by 1 for the next call
	ROTATE_OFFSET=$((offset + 1))

	log "rotate_all: round=$ROTATE_ROUND offset=$offset/$total best=$best_node pool=[$pool]"

	# --- Update UCI candidates + in-memory CANDIDATES ---
	uci -q delete "${CONFIG_NAME}.main.candidate_node"
	for node in $pool; do
		uci -q add_list "${CONFIG_NAME}.main.candidate_node=$node"
	done
	uci commit "$CONFIG_NAME"
	CANDIDATES="$pool"

	# Set target for this cycle
	TARGET_NODE="$best_node"
	BEST_NODE="$best_node"
	return 0
}

# ---------------------------------------------------------------------------
# Fallback policy — called when all current candidates are dead (all_failed).
#
# rotate_all: step the circular buffer, switch to the next best node.
#             After max_rounds full rotations through the pool → final action.
# blackhole:  insert static nft DROP rule (no PW2 restart, traffic blocked).
# direct:     do nothing — traffic flows directly via WAN.
# ---------------------------------------------------------------------------
apply_fallback_policy() {
	[ "$TARGET_REASON" = "all_failed" ] || return 0

	local final="${ROTATE_FINAL_ACTION:-blackhole}"

	case "${FALLBACK_ACTION:-blackhole}" in
	rotate_all)
		# Remove any stale static blackhole before attempting a live switch
		[ -n "$STATIC_BH_HANDLE" ] && _static_blackhole_remove

		local max_rounds="${ROTATE_MAX_ROUNDS:-3}"

		# Guard: if previous cycle completed max_rounds — apply final action now.
		# ROTATE_ROUND is incremented inside _rotate_all_step on wrap, so we check
		# here before stepping to avoid one extra rotation after the limit.
		if [ "${ROTATE_ROUND:-0}" -ge "$max_rounds" ]; then
			log "rotate_all: exhausted $max_rounds rounds → applying final action=$final"
			ROTATE_ROUND=0
			ROTATE_OFFSET=0
			_apply_final_action "$final"
			return 0
		fi

		# Step the circular buffer
		if _rotate_all_step; then
			TARGET_REASON="rotate_all"
		else
			# No live nodes at all in the cache — apply final immediately
			log "rotate_all: no live nodes anywhere → applying final action=$final"
			ROTATE_ROUND=0
			ROTATE_OFFSET=0
			_apply_final_action "$final"
		fi
		;;
	direct)
		# Remove stale static blackhole if present, then let traffic flow via WAN
		[ -n "$STATIC_BH_HANDLE" ] && {
			log "fallback: removing stale blackhole, switching to direct"
			_static_blackhole_remove
		}
		ROTATE_ROUND=0; ROTATE_OFFSET=0
		TARGET_REASON="fallback_direct_all_failed"
		;;
	blackhole|*)
		# Insert static DROP if not already active; reset rotation counters
		ROTATE_ROUND=0; ROTATE_OFFSET=0
		_static_blackhole_insert
		TARGET_REASON="fallback_blackhole_all_failed"
		;;
	esac
}

# Helper: apply final action (direct or blackhole) and set TARGET_REASON.
_apply_final_action() {
	local action="$1"
	case "$action" in
	direct)
		TARGET_REASON="fallback_direct_all_failed"
		;;
	blackhole|*)
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

	# rotate_all is a failover action — never suppress it by min_switch_interval.
	# When all candidates are dead, we must switch immediately to restore connectivity.
	# (Normal best_latency switches are still subject to suppression below.)
	case "$TARGET_REASON" in
	rotate_all) : ;;
	*)
		# If current node is dead (latency=0) — also skip suppression, switch immediately
		if [ "$LAST_SWITCH" -gt 0 ] \
		&& [ $((now - LAST_SWITCH)) -lt "$MIN_SWITCH_INTERVAL" ] \
		&& [ "${CURRENT_LATENCY:-0}" -gt 0 ]; then
			LAST_REASON="suppressed_min_switch_interval"
			return 1
		fi
		;;
	esac

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
# PassWall2 health check.
#
# Checks whether the PassWall2 daemon is alive by asking its init script for
# status.  If it is not running and pw2_restart_on_failure=1 in UCI advanced
# settings, the watchdog restarts PW2 once and records the timestamp.
#
# This is called at the top of every run_once cycle so that latency failures
# caused by a dead PassWall2 are correctly attributed rather than blamed on
# individual proxy nodes.
# ---------------------------------------------------------------------------
_check_passwall_health() {
	# Guard: init script must be known and executable
	[ -n "$PASSWALL_INIT" ] || return 0
	[ -x "$PASSWALL_INIT" ]  || return 0

	# Ask the init script if the service is running (exit 0 = running)
	if "$PASSWALL_INIT" status >/dev/null 2>&1; then
		return 0  # PW2 is alive, nothing to do
	fi

	# PW2 is not running
	log "passwall2 health check: service not running (init=$PASSWALL_INIT)"

	if [ "${PW2_RESTART_ON_FAILURE:-0}" != "1" ]; then
		log "passwall2 health check: auto-restart disabled, skipping"
		return 0
	fi

	# Restart PW2 and record the timestamp
	log "passwall2 health check: restarting PassWall2 ..."
	"$PASSWALL_INIT" restart >/dev/null 2>&1
	local rc=$?
	LAST_PW2_RESTART="$(date +%s)"
	save_state

	if [ $rc -eq 0 ]; then
		log "passwall2 health check: restart OK (ts=$LAST_PW2_RESTART)"
	else
		log "passwall2 health check: restart FAILED (rc=$rc ts=$LAST_PW2_RESTART)"
	fi
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
		write_status "" "" "" "disabled" ""
		return 0
	}

	[ -n "$PASSWALL_SECTION" ] || {
		log "passwall_section is empty"
		write_status "" "" "" "empty_passwall_section" ""
		return 1
	}

	load_state

	# ---------------------------------------------------------------------------
	# PassWall2 health check.
	# Verify that PassWall2 init script is running before we do any latency work.
	# If PW2 is dead and pw2_restart_on_failure=1 — restart it once and record the
	# timestamp. This prevents the watchdog from blaming proxies for a dead PW2.
	# ---------------------------------------------------------------------------
	_check_passwall_health

	current="$(get_default_node)"
	[ -n "$current" ] || {
		log "current default_node is empty"
		write_status "" "" "" "empty_current_default" ""
		return 1
	}

	now="$(date +%s)"
	action="stay"
	status_current="$current"
	history_node="$current"

	# Proxy connection check (interval-gated, reads PROXY_CHECK_* from cfg)
	_check_proxy_connection

	if [ -z "$CANDIDATES" ]; then
		LAST_REASON="no_candidates"
		LAST_TARGET=""
		save_state
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

	# Probabilistic scoring — observer mode (Stage 2.A v0.4.0).
	# Writes scores.jsonl + decisions.jsonl, never modifies TARGET_NODE.
	# When advisory_mode=0 in a future stage, scoring may override should_switch().
	evaluate_decision "$current" "$TARGET_NODE" "$TARGET_REASON"

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
			write_status "$status_current" "$TARGET_NODE" "$BEST_NODE" "$LAST_REASON" "$BEST_LATENCY"
			append_history "$now" "$action" "$history_node" "$LAST_REASON"
			return 0
		else
			LAST_REASON="switch_failed"
			LAST_TARGET="$TARGET_NODE"
			save_state
			write_status "$current" "$TARGET_NODE" "$BEST_NODE" "$LAST_REASON" "$BEST_LATENCY"
			append_history "$now" "stay" "$current" "$LAST_REASON"
			log "switch failed target=$TARGET_NODE"
			return 1
		fi
	fi

	LAST_TARGET="$TARGET_NODE"
	# Map TARGET_REASON to history action.
	# rotate_all: node was switched in UCI/CANDIDATES but should_switch=false
	# means PassWall2 is already on that node — record as rotate_all, not stay.
	case "$TARGET_REASON" in
	fallback_blackhole_all_failed) LAST_REASON="$TARGET_REASON"; action="fallback_blackhole"; history_node="$current" ;;
	fallback_direct_all_failed)    LAST_REASON="$TARGET_REASON"; action="fallback_direct";    history_node="$current" ;;
	rotate_all)                    LAST_REASON="$TARGET_REASON"; action="rotate_all";         history_node="$TARGET_NODE" ;;
	*)                             LAST_REASON="${LAST_REASON:-$TARGET_REASON}"; action="stay"; history_node="$current" ;;
	esac

	save_state
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
	handles="$(nft -a list chain $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" 2>/dev/null \
		| awk '/drop.*handle/{gsub(/.*handle[[:space:]]*/,""); print $1}')"
	for h in $handles; do
		nft delete rule $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" handle "$h" 2>/dev/null \
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

# ---------------------------------------------------------------------------
# CIDR membership test (pure shell, no ipcalc required).
# Usage: _ip_in_cidr <ip> <cidr>   e.g. _ip_in_cidr 198.51.100.5 198.51.100.0/24
# Returns 0 (true) if ip is within the CIDR block, 1 otherwise.
# ---------------------------------------------------------------------------
# Convert dotted-decimal IP to integer (top-level, not nested)
_ip2int() {
	local IFS='.'
	set -- $1
	echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

_ip_in_cidr() {
	local ip="$1" cidr="$2"
	local net prefix
	net="${cidr%/*}"
	prefix="${cidr#*/}"
	# Default prefix 32 if not specified
	[ "$prefix" = "$cidr" ] && prefix=32
	local ip_int net_int mask shift full
	ip_int="$(_ip2int "$ip")"
	net_int="$(_ip2int "$net")"
	full=4294967295
	shift=$(( 32 - prefix ))
	if [ "$shift" -eq 0 ]; then
		mask=$full
	else
		mask=$(( full - ( (1 << shift) - 1 ) ))
	fi
	[ $(( ip_int & mask )) -eq $(( net_int & mask )) ]
}

# ---------------------------------------------------------------------------
# Proxy connection check: detect whether traffic is going through the proxy.
# Reads all config from UCI (PROXY_CHECK_URL, DIRECT_IP_RANGES).
# Writes PROXY_CHECK_STATE / PROXY_CHECK_IP / LAST_PROXY_CHECK_TS.
#
# States:
#   proxy_ok  — external IP matches a known proxy node, or is not in direct ranges
#   direct    — external IP matches DIRECT_IP_RANGES (user-configured)
#   blackhole — STATIC_BH_HANDLE is set (nft DROP rule active)
#   disabled  — PROXY_CHECK_ENABLED=0
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _autodetect_socks_port: find PassWall2's local SOCKS inbound port.
#
# Layered Robustness:
#   1) socks_port_manual (UCI override) — if set, use as-is.
#   2) passwall2.@global[0].node_socks_port — canonical source of truth.
#   3) netstat fallback: pick the lowest 127.0.0.1 TCP LISTEN port held by
#      xray/sing-box/v2ray (filters out 1041/15353 service ports).
#
# Outputs the port number to stdout, or empty string if nothing found.
# ---------------------------------------------------------------------------
_autodetect_socks_port() {
	local port=""

	# 1) Manual override always wins
	if [ -n "${CONN_CHECK_SOCKS_MANUAL:-}" ]; then
		printf '%s' "$CONN_CHECK_SOCKS_MANUAL"
		return 0
	fi

	# 2) PassWall2 UCI — canonical, what the daemon actually uses
	port="$(uci -q get "${PASSWALL_CONFIG:-passwall2}.@global[0].node_socks_port" 2>/dev/null)"
	if [ -n "$port" ] && [ "$port" -gt 0 ] 2>/dev/null; then
		printf '%s' "$port"
		return 0
	fi

	# 3) netstat fallback — lowest 127.0.0.1 LISTEN owned by proxy engine
	port="$(netstat -tlnp 2>/dev/null \
		| awk '/127\.0\.0\.1:/ && /(xray|sing-box|v2ray)/ {
			split($4, a, ":"); print a[length(a)]
		}' \
		| sort -n \
		| awk 'NR==1 && $1!=15353 && $1!=1041 {print; exit}')"

	printf '%s' "${port:-}"
}

# ---------------------------------------------------------------------------
# _check_real_connectivity: probe via SOCKS that real HTTP traffic flows.
#
# Returns 0 on success (HTTP 204), 1 on any failure.
# Sets globals:
#   CONN_CHECK_PORT — detected SOCKS port
#   CONN_CHECK_HTTP — received HTTP code (or 000 on transport error)
#   CONN_CHECK_REASON — short human reason
#
# Detects the TojlU605-style edge case: ipify returns proxy IP (tunnel up),
# but real traffic doesn't flow (e.g., IPv4-in/IPv6-out split, broken routing).
# ---------------------------------------------------------------------------
_check_real_connectivity() {
	CONN_CHECK_PORT="$(_autodetect_socks_port)"
	CONN_CHECK_HTTP=""
	CONN_CHECK_REASON=""

	if [ -z "$CONN_CHECK_PORT" ]; then
		CONN_CHECK_REASON="no_socks_port"
		return 1
	fi

	local url="${CONN_CHECK_URL:-https://www.google.com/generate_204}"
	local tmo="${CONN_CHECK_TIMEOUT:-5}"
	local code

	code="$(curl --proxy "socks5h://127.0.0.1:${CONN_CHECK_PORT}" \
		-m "$tmo" -s -o /dev/null \
		-w '%{http_code}' "$url" 2>/dev/null)"

	CONN_CHECK_HTTP="${code:-000}"

	if [ "$CONN_CHECK_HTTP" = "204" ]; then
		CONN_CHECK_REASON="http_204"
		return 0
	fi

	CONN_CHECK_REASON="http_${CONN_CHECK_HTTP}"
	return 1
}

_check_proxy_connection() {
	if [ "${PROXY_CHECK_ENABLED:-0}" != "1" ]; then
		PROXY_CHECK_STATE=""
		return 0
	fi

	# Reason string carries enough context for the history record; the log line
	# uses the same text after "proxy_check: ".
	local pc_reason=""

	# Blackhole active — no HTTP check needed
	if [ -n "${STATIC_BH_HANDLE:-}" ]; then
		PROXY_CHECK_STATE="blackhole"
		PROXY_CHECK_IP=""
		PROXY_CHECK_NODE_LABEL=""
		LAST_PROXY_CHECK_TS="$(date +%s)"
		pc_reason="blackhole active (nft DROP handle=${STATIC_BH_HANDLE})"
		log "proxy_check: ${pc_reason}"
		_record_proxy_check_event "$PROXY_CHECK_STATE" "" "" "$pc_reason"
		return 0
	fi

	# Interval guard
	local now interval
	now="$(date +%s)"
	interval="${PROXY_CHECK_INTERVAL:-120}"
	[ "$interval" -lt 60 ] && interval=60
	if [ -n "${LAST_PROXY_CHECK_TS:-}" ] && [ "${LAST_PROXY_CHECK_TS:-0}" -gt 0 ]; then
		local age=$(( now - LAST_PROXY_CHECK_TS ))
		if [ "$age" -lt "$interval" ]; then
			log "proxy_check: skipping (last check ${age}s ago, interval=${interval}s)"
			# Not a state event — don't record to history.
			return 0
		fi
	fi

	# WAN IP detection via ip route is unreliable when router is behind NAT/CGN.
	# Direct detection is done via DIRECT_IP_RANGES (user-configured CIDR list).
	local wan_ip=""

	# Fetch external IP from check URL
	local check_url="${PROXY_CHECK_URL:-https://api.ipify.org}"
	local ext_ip=""
	ext_ip="$(curl -s --max-time 5 --retry 0 "$check_url" 2>/dev/null | tr -d '[:space:]')"

	LAST_PROXY_CHECK_TS="$now"

	# Validate: must look like an IP address
	case "$ext_ip" in
	*[!0-9.:]*)
		# Non-IP response or empty — treat as bad response (not a real direct).
		# Keep STATE=direct for backward-compat with status.json consumers,
		# but record a distinct reason so history is unambiguous.
		PROXY_CHECK_STATE="direct"
		PROXY_CHECK_IP=""
		PROXY_CHECK_NODE_LABEL=""
		pc_reason="bad_response from ${check_url}: '${ext_ip}'"
		log "proxy_check: unexpected response from $check_url: '$ext_ip'"
		_record_proxy_check_event "$PROXY_CHECK_STATE" "" "" "$pc_reason"
		return 0
		;;
	esac

	if [ -z "$ext_ip" ]; then
		PROXY_CHECK_STATE="direct"
		PROXY_CHECK_IP=""
		PROXY_CHECK_NODE_LABEL=""
		pc_reason="no_response from ${check_url} (curl failed or timed out)"
		log "proxy_check: no response from $check_url (curl failed or timed out)"
		_record_proxy_check_event "$PROXY_CHECK_STATE" "" "" "$pc_reason"
		return 0
	fi

	PROXY_CHECK_IP="$ext_ip"

	# Try to find a PassWall2 node whose server/address matches the external IP.
	# Iterate all sections that have an 'address' field containing a valid IP
	# (dot-decimal). This avoids dependency on 'type' field value (Xray/V2ray/etc).
	PROXY_CHECK_NODE_LABEL=""
	if [ -n "$ext_ip" ]; then
		local node_id node_server node_remarks
		for node_id in $(uci show "${PASSWALL_CONFIG:-passwall2}" 2>/dev/null \
			| awk -F= '/\.address=/{gsub(/\.address$/,"",$1); split($1,a,"."); print a[2]}'); do
			node_server="$(uci -q get "${PASSWALL_CONFIG:-passwall2}.${node_id}.address" 2>/dev/null)"
			# Skip non-IP values (hostnames, example entries, etc.)
			case "$node_server" in
				*[!0-9.]*) continue ;;
				"") continue ;;
			esac
			if [ "$node_server" = "$ext_ip" ]; then
				node_remarks="$(uci -q get "${PASSWALL_CONFIG:-passwall2}.${node_id}.remarks" 2>/dev/null)"
				[ -z "$node_remarks" ] && node_remarks="$node_id"
				PROXY_CHECK_NODE_LABEL="$node_remarks"
				log "proxy_check: matched node id=$node_id label='$node_remarks' ip=$ext_ip"
				break
			fi
		done
	fi

	# Determine direct vs proxy:
	# 1. If node label found — definitely proxy_ok
	# 2. Else check DIRECT_IP_RANGES (user-configured CIDR list)
	# 3. Else proxy_ok (unknown node — still proxied, just unrecognised)
	if [ -n "$PROXY_CHECK_NODE_LABEL" ]; then
		PROXY_CHECK_STATE="proxy_ok"
		pc_reason="proxy_ok ext_ip=${ext_ip} node='${PROXY_CHECK_NODE_LABEL}'"
		log "proxy_check: ${pc_reason}"
	elif [ -n "${DIRECT_IP_RANGES:-}" ]; then
		local cidr matched=""
		for cidr in $DIRECT_IP_RANGES; do
			if _ip_in_cidr "$ext_ip" "$cidr"; then
				matched="$cidr"
				break
			fi
		done
		if [ -n "$matched" ]; then
			PROXY_CHECK_STATE="direct"
			pc_reason="direct ext_ip=${ext_ip} matches direct range ${matched}"
			log "proxy_check: ${pc_reason}"
		else
			PROXY_CHECK_STATE="proxy_ok"
			pc_reason="proxy_ok ext_ip=${ext_ip} (no node match, not in direct ranges)"
			log "proxy_check: ${pc_reason}"
		fi
	else
		PROXY_CHECK_STATE="proxy_ok"
		pc_reason="proxy_ok ext_ip=${ext_ip} (no node match, no direct ranges configured)"
		log "proxy_check: ${pc_reason}"
	fi

	# Real connectivity probe (Stage 2.A v0.4.0).
	# Detects TojlU605-style edge case: ipify says proxy_ok but real HTTP
	# traffic doesn't flow (broken routing / IPv4-in IPv6-out / silent drop).
	# Only meaningful when the IP check already said proxy_ok — if ipify saw
	# direct/no_response, no point bothering the SOCKS port.
	if [ "${CONN_CHECK_ENABLED:-0}" = "1" ] && [ "$PROXY_CHECK_STATE" = "proxy_ok" ]; then
		if _check_real_connectivity; then
			pc_reason="${pc_reason} + 204_ok via :${CONN_CHECK_PORT}"
			log "proxy_check: real_connectivity OK (port=${CONN_CHECK_PORT} url=${CONN_CHECK_URL})"
		else
			PROXY_CHECK_STATE="proxy_no_204"
			pc_reason="proxy_no_204 ext_ip=${PROXY_CHECK_IP} ${CONN_CHECK_REASON} (port=${CONN_CHECK_PORT:-?})"
			log "proxy_check: real_connectivity FAIL (${CONN_CHECK_REASON} port=${CONN_CHECK_PORT:-?}) -- tunnel up but traffic not flowing"
		fi
	fi

	_record_proxy_check_event "$PROXY_CHECK_STATE" "$PROXY_CHECK_IP" \
		"$PROXY_CHECK_NODE_LABEL" "$pc_reason"
}

daemon_loop() {
	# On first start — load env and cfg, then clean up stale DROP rules
	load_env
	load_cfg
	_cleanup_stale_drops

	# C8e: immediate proxy check at boot so UI shows real status from second 1
	# instead of "Pending check" until the first run_once iteration completes.
	# We force LAST_PROXY_CHECK_TS=0 once to bypass the interval guard for
	# the very first probe; save_state right after persists the new TS.
	load_state
	STATUS_RUNNING="true"
	LAST_PROXY_CHECK_TS=0
	if [ "${PROXY_CHECK_ENABLED:-0}" = "1" ]; then
		_check_proxy_connection
		save_state
		# Write a status snapshot so the UI/widget sees proxy_check_*
		# fields without waiting for the first full run_once cycle.
		local _boot_current
		_boot_current="$(get_default_node 2>/dev/null || echo '')"
		write_status "$_boot_current" "" "" "running" ""
		log "daemon_loop: boot proxy_check done state=${PROXY_CHECK_STATE} ip=${PROXY_CHECK_IP}"
	fi

	while true; do
		run_once
		load_cfg
		sleep "$CHECK_INTERVAL"
	done
}

# ---------------------------------------------------------------------------
# Scoring stats CLI — analyzes scores.jsonl / decisions.jsonl
# ---------------------------------------------------------------------------
cmd_stats() {
	local limit="${1:-50}"
	echo "=== scoring telemetry stats ==="
	echo

	if [ ! -f "$DECISIONS_FILE" ] || [ ! -s "$DECISIONS_FILE" ]; then
		echo "no decisions.jsonl yet (need scoring.enabled=1 and at least one run)"
		return 0
	fi

	# Count only non-empty lines (legacy data may contain blank separators)
	local total agreed disagreed
	total="$(grep -c '^[[:space:]]*{' "$DECISIONS_FILE" 2>/dev/null)"
	agreed="$(grep -c '"agrees": *1' "$DECISIONS_FILE" 2>/dev/null)"
	disagreed=$((total - agreed))
	echo "decisions.jsonl: $total cycles total, agreed=$agreed disagreed=$disagreed"
	if [ "$total" -gt 0 ]; then
		echo "  agreement rate: $((agreed * 100 / total))%"
	fi
	echo

	echo "=== verdict distribution ==="
	for v in stay prefer_switch force_switch unavailable; do
		local n
		n="$(grep -c "\"scoring_verdict\": *\"$v\"" "$DECISIONS_FILE" 2>/dev/null)"
		printf '  %-15s %d\n' "$v" "$n"
	done
	echo

	echo "=== last $limit decisions (oldest → newest) ==="
	printf '%-11s %-9s %-9s %-9s %-9s %-15s %-7s %s\n' \
		ts current cur_tot best_node best_tot verdict legacy agrees

	# Read only non-empty lines, parse with jsonfilter (robust against
	# pretty-printed JSON, key spacing, blank lines).
	grep '^[[:space:]]*{' "$DECISIONS_FILE" | tail -n "$limit" | while IFS= read -r line; do
		[ -n "$line" ] || continue
		local ts cur ct bn bt v la ag
		ts="$(printf '%s' "$line"  | jsonfilter -e '@.ts'                 2>/dev/null)"
		cur="$(printf '%s' "$line" | jsonfilter -e '@.current'            2>/dev/null)"
		ct="$(printf '%s' "$line"  | jsonfilter -e '@.current_total'      2>/dev/null)"
		bn="$(printf '%s' "$line"  | jsonfilter -e '@.scoring_best_node'  2>/dev/null)"
		bt="$(printf '%s' "$line"  | jsonfilter -e '@.scoring_best_total' 2>/dev/null)"
		v="$(printf '%s' "$line"   | jsonfilter -e '@.scoring_verdict'    2>/dev/null)"
		la="$(printf '%s' "$line"  | jsonfilter -e '@.legacy_action'      2>/dev/null)"
		ag="$(printf '%s' "$line"  | jsonfilter -e '@.agrees'             2>/dev/null)"
		printf '%-11s %-9s %-9s %-9s %-9s %-15s %-7s %s\n' \
			"${ts:--}" "${cur:--}" "${ct:-0}" "${bn:--}" "${bt:-0}" \
			"${v:--}" "${la:--}" "${ag:--}"
	done
	echo

	if [ -f "$SCORES_FILE" ]; then
		local scores_lines scores_size
		scores_lines="$(grep -c '^[[:space:]]*{' "$SCORES_FILE" 2>/dev/null)"
		scores_size="$(wc -c < "$SCORES_FILE" 2>/dev/null)"
		echo "scores.jsonl: $scores_lines records, $scores_size bytes"
	fi
}

case "$1" in
run)    run_once    ;;
daemon) daemon_loop ;;
stats)
	load_env
	load_cfg
	shift
	cmd_stats "$@"
	;;
*)
	echo "Usage: $0 {run|daemon|stats [N]}"
	exit 1
	;;
esac
