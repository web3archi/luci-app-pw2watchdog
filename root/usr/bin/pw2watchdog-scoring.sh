#!/bin/sh
# PW2WD_VERSION: v0.4.0-dev
# pw2watchdog-scoring.sh — probabilistic health scoring for PassWall2 nodes
#
# Computes a 0..1 score per node from independent signals (latency, proxy
# liveness, stability, freshness). Designed for Layered Robustness:
#   - core signals work on any OpenWrt + PassWall2 (latency_cache + history)
#   - backend-specific signals (iface_anomaly) are opt-in modules (separate file)
#   - if a signal cannot be computed → neutral 0.5, never crashes
#
# CLI:
#   pw2watchdog-scoring.sh score <node_id>   — JSON with components + total
#   pw2watchdog-scoring.sh score_all         — JSON object {node_id: {...}, ...}
#   pw2watchdog-scoring.sh dump_uci          — show effective weights/thresholds
#   pw2watchdog-scoring.sh selftest          — smoke test on sample inputs
#
# Can also be sourced; in that case only functions are exposed.

PW2WD_VERSION="v0.4.0-dev"

CONFIG_NAME="pw2watchdog"
STATE_DIR="/var/run/pw2watchdog"
ENV_FILE="$STATE_DIR/env.static"
LATENCY_CACHE="$STATE_DIR/latency_cache.json"
STATUS_FILE="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.jsonl"

# Fixed-point arithmetic: scale everything by 1000 (3 decimal places)
# Avoids bc/awk floats — pure POSIX integer math.
PW2_SCORE_SCALE=1000

log() { logger -t pw2watchdog-scoring "$*"; }

# ---------------------------------------------------------------------------
# UCI loader — single source of truth for weights/thresholds.
# Reads pw2watchdog.scoring.* with hard-coded fallbacks (Layered Robustness:
# scoring works even if section doesn't exist yet — e.g. fresh install).
# Exports: SC_W_LAT, SC_W_PROXY, SC_W_STAB, SC_W_AGE, SC_W_IFACE,
#          SC_MAX_LAT, SC_STAB_WIN, SC_AGE_FRESH, SC_AGE_MEDIUM, SC_AGE_STALE,
#          SC_CRIT_THR, SC_PREV_GAP, SC_REL_IMP, SC_MIN_SWITCH,
#          SC_RECENT_EXTRA, SC_TELEMETRY, SC_TEL_MAX_MB
# ---------------------------------------------------------------------------
pw2_scoring_load_uci() {
	# Hard-coded fallback defaults (no .config file required)
	SC_W_LAT=45
	SC_W_PROXY=40
	SC_W_STAB=10
	SC_W_AGE=5
	SC_W_IFACE=0
	SC_STAB_WIN=20
	SC_AGE_FRESH=60
	SC_AGE_MEDIUM=180
	SC_AGE_STALE=600
	SC_CRIT_THR=30
	SC_PREV_GAP=25
	SC_REL_IMP=30
	SC_MIN_SWITCH=60
	SC_RECENT_EXTRA=35
	SC_TELEMETRY=1
	SC_TEL_MAX_MB=10
	SC_MAX_LAT=1500   # re-used from main.max_latency

	# Override from UCI if available
	if [ -f /lib/functions.sh ]; then
		# shellcheck disable=SC1091
		. /lib/functions.sh
		config_load "$CONFIG_NAME" 2>/dev/null || return 0

		local v
		config_get v main max_latency ''
		[ -n "$v" ] && SC_MAX_LAT="$v"

		config_get v scoring weight_latency ''
		[ -n "$v" ] && SC_W_LAT="$v"
		config_get v scoring weight_proxy ''
		[ -n "$v" ] && SC_W_PROXY="$v"
		config_get v scoring weight_stability ''
		[ -n "$v" ] && SC_W_STAB="$v"
		config_get v scoring weight_age ''
		[ -n "$v" ] && SC_W_AGE="$v"
		config_get v scoring weight_iface ''
		[ -n "$v" ] && SC_W_IFACE="$v"
		config_get v scoring stability_window ''
		[ -n "$v" ] && SC_STAB_WIN="$v"
		config_get v scoring critical_threshold ''
		[ -n "$v" ] && SC_CRIT_THR="$v"
		config_get v scoring preventive_gap ''
		[ -n "$v" ] && SC_PREV_GAP="$v"
		config_get v scoring relative_improvement ''
		[ -n "$v" ] && SC_REL_IMP="$v"
		config_get v scoring min_switch_interval ''
		[ -n "$v" ] && SC_MIN_SWITCH="$v"
		config_get v scoring recent_switch_extra ''
		[ -n "$v" ] && SC_RECENT_EXTRA="$v"
		config_get v scoring telemetry_enabled ''
		[ -n "$v" ] && SC_TELEMETRY="$v"
		config_get v scoring telemetry_max_mb ''
		[ -n "$v" ] && SC_TEL_MAX_MB="$v"
	fi
}

# ---------------------------------------------------------------------------
# JSON readers — all use jsonfilter (guaranteed in OpenWrt 22.03+)
# All return empty string on failure (never crash).
# ---------------------------------------------------------------------------

# Strip leading/trailing whitespace and CR (defensive: some jsonfilter builds
# emit trailing CR on certain platforms; comparisons would silently fail).
_pw2_trim() {
	# shellcheck disable=SC3060   # POSIX ${var##/%%} suffices, no bash subst
	printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Get a field for a node from latency_cache.json
# Usage: pw2_lc_get <node_id> <field>     # field: latency|status|label|ts
pw2_lc_get() {
	local node="$1" field="$2" raw
	[ -f "$LATENCY_CACHE" ] || return 0
	raw="$(jsonfilter -i "$LATENCY_CACHE" -e "@['$node'].$field" 2>/dev/null)"
	_pw2_trim "$raw"
}

# List all node IDs in latency_cache.json.
# jsonfilter on OpenWrt 23.05 does not support key extraction (@.*~ errors).
# Use awk over the canonical formatting written by pw2watchdog-scanner.sh:
#   '  "<node_id>": { ...'
pw2_lc_list_nodes() {
	[ -f "$LATENCY_CACHE" ] || return 0
	awk -F'"' '/^  "[A-Za-z0-9_-]+":[[:space:]]*\{/ { print $2 }' "$LATENCY_CACHE"
}

# Get a top-level field from status.json
pw2_st_get() {
	local field="$1" raw
	[ -f "$STATUS_FILE" ] || return 0
	raw="$(jsonfilter -i "$STATUS_FILE" -e "@.$field" 2>/dev/null)"
	_pw2_trim "$raw"
}

# ---------------------------------------------------------------------------
# Component scoring functions — each returns 0..1000 (fixed-point, scale=1000)
# ---------------------------------------------------------------------------

# Latency: 1.0 at 0ms, 0.0 at SC_MAX_LAT, linear between.
# latency==0 means "unreachable" (PassWall2 convention) → score 0.
pw2_score_latency() {
	local node="$1" lat
	lat="$(pw2_lc_get "$node" latency)"
	# Empty or non-numeric → neutral
	case "$lat" in
		''|*[!0-9]*) echo 500; return 0 ;;
	esac
	if [ "$lat" -eq 0 ]; then
		echo 0
	elif [ "$lat" -ge "$SC_MAX_LAT" ]; then
		echo 0
	else
		# score = (1 - lat/max) * 1000 = (max - lat) * 1000 / max
		echo $(( (SC_MAX_LAT - lat) * PW2_SCORE_SCALE / SC_MAX_LAT ))
	fi
}

# Proxy: only meaningful for current_node. For others → neutral 500.
# Reads status.json.proxy_check_state (proxy_ok/direct/no_response/...).
pw2_score_proxy() {
	local node="$1"
	local current state ts now age
	current="$(pw2_st_get current_node)"
	if [ "$node" != "$current" ]; then
		# We can't probe non-current nodes without switching → neutral.
		echo 500
		return 0
	fi
	state="$(pw2_st_get proxy_check_state)"
	ts="$(pw2_st_get proxy_check_ts)"
	now="$(date +%s)"
	# Stale data (>5 min) → neutral
	if [ -n "$ts" ]; then
		age=$((now - ts))
		[ "$age" -gt 300 ] && { echo 500; return 0; }
	fi
	case "$state" in
		proxy_ok)    echo 1000 ;;
		direct)      echo 0    ;;   # catastrophic: traffic bypassing proxy
		no_response) echo 200  ;;
		'')          echo 500  ;;   # no data
		*)           echo 400  ;;   # any other unknown state — slight penalty
	esac
}

# Stability: success rate of last SC_STAB_WIN proxy_check entries for this node.
# If <5 samples → neutral 500 (insufficient data).
pw2_score_stability() {
	local node="$1"
	[ -f "$HISTORY_FILE" ] || { echo 500; return 0; }

	# Pull last N proxy_check entries for this node, regardless of state.
	# Format example:
	#   { "ts": ..., "action": "proxy_check", "node": "TojlU605", ..., "state": "proxy_ok", ... }
	# We grep by node, take last SC_STAB_WIN, count state=="proxy_ok" vs total.
	local total ok
	# shellcheck disable=SC2046
	set -- $(grep -F '"action": "proxy_check"' "$HISTORY_FILE" \
		| grep -F "\"node\": \"$node\"" \
		| tail -n "$SC_STAB_WIN" \
		| awk '
			BEGIN { tot=0; ok=0 }
			/"state": "proxy_ok"/ { ok++ }
			{ tot++ }
			END { print tot, ok }
		')
	total="${1:-0}"
	ok="${2:-0}"

	if [ "$total" -lt 5 ]; then
		echo 500
	else
		echo $(( ok * PW2_SCORE_SCALE / total ))
	fi
}

# Age: how fresh is the latency_cache entry?
pw2_score_age() {
	local node="$1" ts now age
	ts="$(pw2_lc_get "$node" ts)"
	case "$ts" in
		''|*[!0-9]*) echo 500; return 0 ;;
	esac
	now="$(date +%s)"
	age=$((now - ts))
	if   [ "$age" -lt "$SC_AGE_FRESH" ]; then echo 1000
	elif [ "$age" -lt "$SC_AGE_MEDIUM" ]; then echo 700
	elif [ "$age" -lt "$SC_AGE_STALE" ];  then echo 400
	else                                       echo 100
	fi
}

# ---------------------------------------------------------------------------
# Aggregate: compute total score for one node + emit a JSON object.
# Weights are normalised so sum(weights) → 100. If iface weight=0 (off),
# its share is redistributed proportionally to other weights.
# ---------------------------------------------------------------------------
pw2_compute_score_json() {
	local node="$1"
	local s_lat s_proxy s_stab s_age s_iface
	s_lat="$(pw2_score_latency "$node")"
	s_proxy="$(pw2_score_proxy "$node")"
	s_stab="$(pw2_score_stability "$node")"
	s_age="$(pw2_score_age "$node")"
	s_iface=500   # placeholder until iface module is added (commit 4)

	local w_lat="$SC_W_LAT" w_proxy="$SC_W_PROXY" w_stab="$SC_W_STAB"
	local w_age="$SC_W_AGE" w_iface="$SC_W_IFACE"

	# Normalise weights to sum=100 (integer math)
	local w_sum=$((w_lat + w_proxy + w_stab + w_age + w_iface))
	[ "$w_sum" -lt 1 ] && w_sum=1   # safety

	# total = sum(score_i * weight_i) / w_sum   (all in 0..1000 scale)
	local total=$((
		(s_lat   * w_lat   +
		 s_proxy * w_proxy +
		 s_stab  * w_stab  +
		 s_age   * w_age   +
		 s_iface * w_iface) / w_sum
	))

	# label (best-effort; '' if missing)
	local label
	label="$(pw2_lc_get "$node" label)"

	# Emit JSON. Score values printed as 0..1000 (callers can divide by 10 for %).
	printf '{"node":"%s","label":"%s","total":%d,"components":{"latency":%d,"proxy":%d,"stability":%d,"age":%d,"iface":%d},"weights":{"latency":%d,"proxy":%d,"stability":%d,"age":%d,"iface":%d}}\n' \
		"$node" "$label" "$total" \
		"$s_lat" "$s_proxy" "$s_stab" "$s_age" "$s_iface" \
		"$w_lat" "$w_proxy" "$w_stab" "$w_age" "$w_iface"
}

# Compute scores for all nodes in latency_cache → JSON object
pw2_compute_score_all_json() {
	local nodes node first=1
	nodes="$(pw2_lc_list_nodes)"
	printf '{'
	for node in $nodes; do
		[ "$first" = "1" ] || printf ','
		first=0
		printf '"%s":' "$node"
		pw2_compute_score_json "$node" | tr -d '\n'
	done
	printf '}\n'
}

# ---------------------------------------------------------------------------
# CLI dispatcher (skipped when sourced)
# ---------------------------------------------------------------------------
pw2_scoring_main() {
	pw2_scoring_load_uci

	case "${1:-}" in
		score)
			[ -n "${2:-}" ] || { echo "usage: $0 score <node_id>" >&2; return 2; }
			pw2_compute_score_json "$2"
			;;
		score_all)
			pw2_compute_score_all_json
			;;
		list_nodes)
			pw2_lc_list_nodes
			;;
		dump_uci)
			printf 'weights:    latency=%d proxy=%d stability=%d age=%d iface=%d\n' \
				"$SC_W_LAT" "$SC_W_PROXY" "$SC_W_STAB" "$SC_W_AGE" "$SC_W_IFACE"
			printf 'max_latency: %d ms\n' "$SC_MAX_LAT"
			printf 'stability:   window=%d\n' "$SC_STAB_WIN"
			printf 'age tiers:   fresh<%ds medium<%ds stale<%ds\n' \
				"$SC_AGE_FRESH" "$SC_AGE_MEDIUM" "$SC_AGE_STALE"
			printf 'decision:    crit=%d%% prev_gap=%d%% rel_imp=%d%% min_switch=%ds recent_extra=%d%%\n' \
				"$SC_CRIT_THR" "$SC_PREV_GAP" "$SC_REL_IMP" \
				"$SC_MIN_SWITCH" "$SC_RECENT_EXTRA"
			printf 'telemetry:   enabled=%d max_mb=%d\n' \
				"$SC_TELEMETRY" "$SC_TEL_MAX_MB"
			;;
		selftest)
			# Synthetic test against the live state files. Verifies wiring; if
			# files are missing, neutral 500 fallbacks should kick in everywhere.
			echo "[selftest] dump_uci:"
			"$0" dump_uci
			echo
			echo "[selftest] current_node from status.json:"
			pw2_st_get current_node
			echo
			echo "[selftest] nodes in latency_cache:"
			pw2_lc_list_nodes | tr '\n' ' '
			echo
			echo "[selftest] score for current_node:"
			local cur
			cur="$(pw2_st_get current_node)"
			[ -n "$cur" ] && pw2_compute_score_json "$cur"
			echo
			echo "[selftest] OK"
			;;
		'' )
			cat <<EOF
pw2watchdog-scoring.sh — health scoring engine

Usage:
  $0 score <node_id>     compute score for one node (JSON)
  $0 score_all           compute scores for all nodes (JSON)
  $0 list_nodes          list node IDs from latency_cache
  $0 dump_uci            print effective weights / thresholds
  $0 selftest            wiring smoke test against live state files

Version: $PW2WD_VERSION
EOF
			;;
		*)
			echo "unknown command: $1" >&2
			return 2
			;;
	esac
}

# Run main only when executed directly, not when sourced.
case "${0##*/}" in
	pw2watchdog-scoring.sh) pw2_scoring_main "$@" ;;
esac
