#!/bin/sh
# pw2watchdog-env.sh — service discovery for pw2watchdog
#
# Finds all PassWall2/OpenWrt paths and parameters programmatically.
# Falls back to UCI overrides from pw2watchdog.advanced on failure.
# Saves the result to /var/run/pw2watchdog/env.static
#
# Usage:
#   pw2watchdog-env.sh resolve          — resolve and save (idempotent, TTL-based)
#   pw2watchdog-env.sh resolve --force  — force re-resolution
#   pw2watchdog-env.sh check            — show current env status
#   pw2watchdog-env.sh get <VAR>        — print a single variable from env
#
# Other scripts source the result like this:
#   . /var/run/pw2watchdog/env.static || exit 1
#
# Dynamic helpers (change on every passwall2 restart — not cached):
#   pw2_get_tproxy_port   — current tproxy port from passwall2 var file
#   pw2_is_proxy_ready    — check if the port is actually listening right now
#   pw2_wait_proxy_ready  — wait for proxy to become ready with timeout

CONFIG_NAME="pw2watchdog"
STATE_DIR="/var/run/pw2watchdog"
ENV_FILE="$STATE_DIR/env.static"
ENV_TTL=3600   # seconds: skip re-resolution if env is fresher than this

log() { logger -t pw2watchdog-env "$*"; }
err() { logger -t pw2watchdog-env "ERROR: $*"; }

# ---------------------------------------------------------------------------
# UCI overrides (Advanced Settings in LuCI)
# ---------------------------------------------------------------------------
load_uci_overrides() {
	. /lib/functions.sh
	config_load "$CONFIG_NAME"
	config_get OVR_PASSWALL_CONFIG  advanced passwall_config  ''
	config_get OVR_INIT_SCRIPT      advanced init_script      ''
	config_get OVR_TEST_SCRIPT      advanced test_script      ''
	config_get OVR_UTILS_SCRIPT     advanced utils_script     ''
	config_get OVR_NFTABLES_SCRIPT  advanced nftables_script  ''
	config_get OVR_TMP_PATH         advanced tmp_path         ''
	config_get OVR_NFTABLE_NAME     advanced nftable_name     ''
	config_get OVR_NFTCHAIN_MANGLE  advanced nftchain_mangle  ''
	config_get OVR_FWMARK           advanced fwmark           ''
}

# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------

find_init_script() {
	local cfg="$1"
	local candidate

	candidate="/etc/init.d/${cfg}"
	[ -x "$candidate" ] && { echo "$candidate"; return 0; }

	candidate="$(grep -rl "^CONFIG=${cfg}$" /etc/init.d/ 2>/dev/null | head -1)"
	[ -n "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }

	candidate="$(grep -rl "/${cfg}" /etc/init.d/ 2>/dev/null | head -1)"
	[ -n "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }

	return 1
}

find_share_dir() {
	local cfg="$1"
	local d
	for d in \
		"/usr/share/${cfg}" \
		"/usr/share/$(echo "$cfg" | sed 's/[0-9]*$//')" \
		"/opt/share/${cfg}"
	do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	return 1
}

extract_var_from_script() {
	local script="$1" var="$2"
	[ -f "$script" ] || return 1
	grep -m1 "^${var}=" "$script" | sed "s/^${var}=//;s/[\"']//g;s/ *#.*//"
}

find_nftable_name() {
	local nft_script="$1"
	[ -f "$nft_script" ] || return 1
	extract_var_from_script "$nft_script" "NFTABLE_NAME"
}

find_fwmark() {
	local nft_script="$1"
	[ -f "$nft_script" ] || return 1
	local val
	val="$(extract_var_from_script "$nft_script" "FWMARK")"
	[ -n "$val" ] && { echo "$val"; return 0; }
	val="$(grep -m1 'meta mark set 0x' "$nft_script" | grep -o '0x[0-9A-Fa-f]\+' | head -1)"
	[ -n "$val" ] && { echo "$val"; return 0; }
	return 1
}

find_tmp_path() {
	local utils_script="$1" cfg="$2"
	[ -f "$utils_script" ] || return 1
	local val
	val="$(grep -m1 '^TMP_PATH=' "$utils_script" \
		| sed "s/^TMP_PATH=//;s/[\"']//g" \
		| sed "s|\${CONFIG}|${cfg}|g")"
	[ -n "$val" ] && { echo "$val"; return 0; }
	return 1
}

find_nftchain_mangle() {
	local nftable="$1" nft_script="$2"
	local chain

	# Live nftables state — most accurate source
	chain="$(nft list table $nftable 2>/dev/null \
		| awk '/chain PSW/{c=$2} /tproxy/{if(c!~/V6/) print c; exit}')"
	[ -n "$chain" ] && { echo "$chain"; return 0; }

	# Fall back to parsing the nftables script
	chain="$(grep -m1 'PSW.*MANGLE[^_V6]' "$nft_script" 2>/dev/null \
		| grep -oE 'PSW[0-9A-Z_]+MANGLE' | grep -v V6 | head -1)"
	[ -n "$chain" ] && { echo "$chain"; return 0; }

	return 1
}

# ---------------------------------------------------------------------------
# Hardware info and recommended candidate count
# ---------------------------------------------------------------------------
collect_hw_info() {
	local check_interval="$1"    # seconds
	local timeout_per_node="$2"  # seconds

	HW_CPU_THREADS="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"

	HW_CPU_MODEL="$(grep -m1 'cpu model\|model name\|Processor' /proc/cpuinfo 2>/dev/null \
		| sed 's/.*: *//' | tr -d '\n')"
	[ -n "$HW_CPU_MODEL" ] || HW_CPU_MODEL="unknown"

	# RAM from /proc/meminfo, in MB
	HW_RAM_TOTAL_KB="$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
	HW_RAM_FREE_KB="$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
	HW_RAM_TOTAL_MB=$(( HW_RAM_TOTAL_KB / 1024 ))
	HW_RAM_FREE_MB=$(( HW_RAM_FREE_KB / 1024 ))

	# Recommended candidate count.
	# Measured overhead on weak hardware (single-core MIPS class): ~9x the configured
	# timeout per node (e.g. timeout=4s → ~36s per node including PassWall2 restart overhead).
	# On medium/powerful hardware the actual overhead is lower, so the formula is conservative.
	# Formula: floor(check_interval * 0.6 / (timeout * 9)), min=2, max=10
	local t real_per_node recommended
	t=$(( timeout_per_node > 0 ? timeout_per_node : 4 ))
	real_per_node=$(( t * 9 ))
	recommended=$(( (check_interval * 6) / (real_per_node * 10) ))
	[ "$recommended" -lt 2  ] && recommended=2
	[ "$recommended" -gt 10 ] && recommended=10
	HW_RECOMMENDED_CANDIDATES="$recommended"
}

# ---------------------------------------------------------------------------
# Main resolver
# ---------------------------------------------------------------------------
resolve() {
	local errors=0 warnings=0

	load_uci_overrides

	# PassWall2 config name
	PASSWALL_CONFIG="${OVR_PASSWALL_CONFIG:-}"
	if [ -z "$PASSWALL_CONFIG" ]; then
		. /lib/functions.sh
		config_load "$CONFIG_NAME"
		config_get PASSWALL_CONFIG main passwall_config 'passwall2'
	fi

	log "resolving environment for passwall_config=$PASSWALL_CONFIG"

	# ── 1. Init script ───────────────────────────────────────────────────
	local init_script="${OVR_INIT_SCRIPT:-}"
	if [ -z "$init_script" ]; then
		init_script="$(find_init_script "$PASSWALL_CONFIG")"
	fi
	if [ -z "$init_script" ] || [ ! -x "$init_script" ]; then
		err "init script not found for '$PASSWALL_CONFIG'"
		errors=$((errors + 1)); init_script=""
	else
		log "init_script=$init_script"
	fi

	# ── 2. Share directory ───────────────────────────────────────────────
	local share_dir
	share_dir="$(find_share_dir "$PASSWALL_CONFIG")"
	if [ -z "$share_dir" ]; then
		err "share directory not found for '$PASSWALL_CONFIG'"
		errors=$((errors + 1))
	else
		log "share_dir=$share_dir"
	fi

	# ── 3. test.sh ───────────────────────────────────────────────────────
	local test_script="${OVR_TEST_SCRIPT:-}"
	[ -z "$test_script" ] && [ -n "$share_dir" ] && test_script="${share_dir}/test.sh"
	if [ -z "$test_script" ] || [ ! -f "$test_script" ]; then
		err "test.sh not found (expected $test_script)"
		errors=$((errors + 1)); test_script=""
	else
		log "test_script=$test_script"
	fi

	# ── 4. utils.sh ──────────────────────────────────────────────────────
	local utils_script="${OVR_UTILS_SCRIPT:-}"
	[ -z "$utils_script" ] && [ -n "$share_dir" ] && utils_script="${share_dir}/utils.sh"
	if [ -z "$utils_script" ] || [ ! -f "$utils_script" ]; then
		err "utils.sh not found (expected $utils_script)"
		errors=$((errors + 1)); utils_script=""
	else
		log "utils_script=$utils_script"
	fi

	# ── 5. nftables.sh ───────────────────────────────────────────────────
	local nftables_script="${OVR_NFTABLES_SCRIPT:-}"
	[ -z "$nftables_script" ] && [ -n "$share_dir" ] && nftables_script="${share_dir}/nftables.sh"
	if [ -z "$nftables_script" ] || [ ! -f "$nftables_script" ]; then
		err "nftables.sh not found (expected $nftables_script)"
		errors=$((errors + 1)); nftables_script=""
	else
		log "nftables_script=$nftables_script"
	fi

	# ── 6. TMP_PATH ──────────────────────────────────────────────────────
	local tmp_path="${OVR_TMP_PATH:-}"
	[ -z "$tmp_path" ] && [ -n "$utils_script" ] && \
		tmp_path="$(find_tmp_path "$utils_script" "$PASSWALL_CONFIG")"
	if [ -z "$tmp_path" ]; then
		tmp_path="/tmp/etc/${PASSWALL_CONFIG}"
		log "tmp_path: using default $tmp_path"
		warnings=$((warnings + 1))
	else
		log "tmp_path=$tmp_path"
	fi

	# ── 7. NFTable name ──────────────────────────────────────────────────
	local nftable_name="${OVR_NFTABLE_NAME:-}"
	[ -z "$nftable_name" ] && [ -n "$nftables_script" ] && \
		nftable_name="$(find_nftable_name "$nftables_script")"
	if [ -z "$nftable_name" ]; then
		err "nftable name not found"
		errors=$((errors + 1)); nftable_name=""
	else
		log "nftable_name=$nftable_name"
	fi

	# ── 8. FWMARK ────────────────────────────────────────────────────────
	local fwmark="${OVR_FWMARK:-}"
	[ -z "$fwmark" ] && [ -n "$nftables_script" ] && \
		fwmark="$(find_fwmark "$nftables_script")"
	if [ -z "$fwmark" ]; then
		err "fwmark not found"
		errors=$((errors + 1)); fwmark=""
	else
		log "fwmark=$fwmark"
	fi

	# ── 9. NFT chain mangle ──────────────────────────────────────────────
	local nftchain_mangle="${OVR_NFTCHAIN_MANGLE:-}"
	[ -z "$nftchain_mangle" ] && [ -n "$nftable_name" ] && [ -n "$nftables_script" ] && \
		nftchain_mangle="$(find_nftchain_mangle "$nftable_name" "$nftables_script")"
	if [ -z "$nftchain_mangle" ]; then
		err "nft mangle chain not found"
		errors=$((errors + 1)); nftchain_mangle=""
	else
		log "nftchain_mangle=$nftchain_mangle"
	fi

	# ── 10. Hardware info ────────────────────────────────────────────────
	local check_interval timeout_per_node
	config_get check_interval   main check_interval '180'
	config_get timeout_per_node main timeout        '4'
	collect_hw_info "$check_interval" "$timeout_per_node"
	log "hw: cpu_model=$HW_CPU_MODEL threads=$HW_CPU_THREADS ram=${HW_RAM_TOTAL_MB}MB recommended_candidates=$HW_RECOMMENDED_CANDIDATES"

	# ── Write env.static ─────────────────────────────────────────────────
	mkdir -p "$STATE_DIR"

	cat > "$ENV_FILE" <<ENVEOF
# pw2watchdog environment — auto-generated $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT EDIT — regenerated by pw2watchdog-env.sh resolve
# errors=${errors} warnings=${warnings}
PW2_PASSWALL_CONFIG='${PASSWALL_CONFIG}'
PW2_INIT_SCRIPT='${init_script}'
PW2_SHARE_DIR='${share_dir}'
PW2_TEST_SCRIPT='${test_script}'
PW2_UTILS_SCRIPT='${utils_script}'
PW2_NFTABLES_SCRIPT='${nftables_script}'
PW2_TMP_PATH='${tmp_path}'
PW2_NFTABLE_NAME='${nftable_name}'
PW2_NFTCHAIN_MANGLE='${nftchain_mangle}'
PW2_FWMARK='${fwmark}'
HW_CPU_MODEL='${HW_CPU_MODEL}'
HW_CPU_THREADS='${HW_CPU_THREADS}'
HW_RAM_TOTAL_MB='${HW_RAM_TOTAL_MB}'
HW_RAM_FREE_MB='${HW_RAM_FREE_MB}'
HW_RECOMMENDED_CANDIDATES='${HW_RECOMMENDED_CANDIDATES}'
PW2_ENV_ERRORS='${errors}'
PW2_ENV_WARNINGS='${warnings}'
PW2_ENV_TS='$(date +%s)'
ENVEOF

	if [ "$errors" -gt 0 ]; then
		err "resolve finished with $errors error(s) — Transit Blackhole will be disabled"
		err "Fix via LuCI → pw2watchdog → Settings → Advanced"
		return 1
	fi

	[ "$warnings" -gt 0 ] && log "resolve finished with $warnings warning(s)"
	log "resolve OK"
	return 0
}

# ---------------------------------------------------------------------------
# Dynamic helpers (not cached — call on demand)
# ---------------------------------------------------------------------------

# Current tproxy port from PassWall2 var file
pw2_get_tproxy_port() {
	local tmp_path var_file
	tmp_path="${PW2_TMP_PATH:-}"
	if [ -z "$tmp_path" ] && [ -f "$ENV_FILE" ]; then
		tmp_path="$(grep '^PW2_TMP_PATH=' "$ENV_FILE" | head -1 \
			| sed "s/^PW2_TMP_PATH=//;s/[\"']//g")"
	fi
	[ -n "$tmp_path" ] || return 1

	var_file="${tmp_path}/var"
	[ -f "$var_file" ] || return 1

	grep -m1 '^ACL_GLOBAL_redir_port=' "$var_file" \
		| sed "s/^ACL_GLOBAL_redir_port=//;s/[\"']//g"
}

# Check if the proxy is actually listening on the tproxy port (UDP)
# PassWall2/xray listens on UDP :::PORT (dual-stack), not TCP
pw2_is_proxy_ready() {
	local port
	port="$(pw2_get_tproxy_port)"
	[ -n "$port" ] || return 1

	local hex_port
	hex_port="$(printf '%04X' "$port")"

	# /proc/net/udp6 — listening socket has remote addr 00000000
	grep -qi "^[[:space:]]*[0-9]*: [0-9A-F]*:${hex_port} 00000000" \
		/proc/net/udp6 2>/dev/null && return 0

	# /proc/net/udp — IPv4 fallback
	grep -qi "^[[:space:]]*[0-9]*: [0-9A-F]*:${hex_port} 00000000" \
		/proc/net/udp 2>/dev/null && return 0

	return 1
}

# Wait for proxy to become ready after passwall2 restart
# pw2_wait_proxy_ready [timeout_seconds]
# Returns 0 if ready, 1 if timed out
pw2_wait_proxy_ready() {
	local timeout="${1:-60}"
	local elapsed=0

	# Initial delay — process cannot start instantly
	sleep 2

	while [ "$elapsed" -lt "$timeout" ]; do
		pw2_is_proxy_ready && return 0
		sleep 2
		elapsed=$((elapsed + 2))
	done

	return 1
}

# ---------------------------------------------------------------------------
# check — human-readable env status + live data
# ---------------------------------------------------------------------------
cmd_check() {
	if [ ! -f "$ENV_FILE" ]; then
		echo "ENV FILE: not found ($ENV_FILE)"
		echo "Run: pw2watchdog-env.sh resolve"
		return 1
	fi

	. "$ENV_FILE"

	local age=$(( $(date +%s) - ${PW2_ENV_TS:-0} ))
	echo "ENV FILE:   $ENV_FILE  (age: ${age}s, TTL: ${ENV_TTL}s)"
	echo "ERRORS:     ${PW2_ENV_ERRORS:-?}"
	echo "WARNINGS:   ${PW2_ENV_WARNINGS:-?}"
	echo ""
	echo "── PassWall2 ──────────────────────────────────"
	echo "  passwall_config:  ${PW2_PASSWALL_CONFIG:-NOT SET}"
	echo "  init_script:      ${PW2_INIT_SCRIPT:-NOT SET}"
	echo "  test_script:      ${PW2_TEST_SCRIPT:-NOT SET}"
	echo "  utils_script:     ${PW2_UTILS_SCRIPT:-NOT SET}"
	echo "  nftables_script:  ${PW2_NFTABLES_SCRIPT:-NOT SET}"
	echo "  tmp_path:         ${PW2_TMP_PATH:-NOT SET}"
	echo "  nftable_name:     ${PW2_NFTABLE_NAME:-NOT SET}"
	echo "  nftchain_mangle:  ${PW2_NFTCHAIN_MANGLE:-NOT SET}"
	echo "  fwmark:           ${PW2_FWMARK:-NOT SET}"
	echo ""
	echo "── Hardware ────────────────────────────────────"
	echo "  cpu_model:        ${HW_CPU_MODEL:-NOT SET}"
	echo "  cpu_threads:      ${HW_CPU_THREADS:-NOT SET}"
	echo "  ram_total:        ${HW_RAM_TOTAL_MB:-?} MB"
	echo "  ram_free:         ${HW_RAM_FREE_MB:-?} MB"
	echo "  recommended_cand: ${HW_RECOMMENDED_CANDIDATES:-?}"
	echo ""
	echo "── Live (dynamic) ──────────────────────────────"
	local tproxy_port
	tproxy_port="$(pw2_get_tproxy_port)"
	if [ -n "$tproxy_port" ]; then
		echo "  tproxy_port:      ${tproxy_port}"
		if pw2_is_proxy_ready; then
			echo "  proxy_ready:      YES"
		else
			echo "  proxy_ready:      NO  (port not listening)"
		fi
	else
		echo "  tproxy_port:      NOT AVAILABLE (passwall2 not running?)"
		echo "  proxy_ready:      NO"
	fi

	[ "${PW2_ENV_ERRORS:-1}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Entry point — skipped when sourced (. pw2watchdog-env.sh)
# ---------------------------------------------------------------------------
_self="$(basename "$0")"
[ "$_self" = "pw2watchdog-env.sh" ] || return 0

case "$1" in
resolve)
	if [ "$2" != "--force" ] && [ -f "$ENV_FILE" ]; then
		. "$ENV_FILE"
		local_ts="${PW2_ENV_TS:-0}"
		age=$(( $(date +%s) - local_ts ))
		if [ "$age" -lt "$ENV_TTL" ] && [ "${PW2_ENV_ERRORS:-1}" -eq 0 ]; then
			log "env is fresh (age=${age}s < TTL=${ENV_TTL}s), skipping resolve"
			exit 0
		fi
	fi
	resolve
	exit $?
	;;
check)
	cmd_check
	exit $?
	;;
get)
	[ -f "$ENV_FILE" ] || { echo ""; exit 1; }
	. "$ENV_FILE"
	var="$2"
	[ -n "$var" ] || { echo "Usage: $0 get <VAR>"; exit 1; }
	eval "echo \"\${$var}\""
	exit 0
	;;
*)
	echo "Usage: $0 {resolve [--force]|check|get <VAR>}"
	exit 1
	;;
esac
