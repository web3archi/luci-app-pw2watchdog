#!/bin/sh
# PW2WD_KS_VERSION: v0.1.0 (C11)
# pw2watchdog-killswitch.sh — Independent killswitch table for PassWall2 Watchdog.
#
# Purpose:
#   Keep the LAN→WAN traffic locked down whenever the proxy engine (xray) is
#   not running. Unlike PW2's own blackhole rules, this killswitch lives in a
#   SEPARATE nftables table that DOES NOT depend on PassWall2 being alive or
#   on the `inet passwall2` table existing.
#
# Design:
#   * Own table:        `inet pw2wd_ks`
#   * Hook:             forward, priority -150 (runs BEFORE PW2's mangle -100)
#   * Whitelist:        LAN nets, loopback, multicast, link-local, broadcast,
#                       all VPS upstream IPs (from `uci show passwall2|.address=`),
#                       optional user-specified extras.
#   * Verdict policy:   when "armed", any LAN→WAN packet not matching whitelist
#                       is dropped.
#   * When disarmed:    chain exists but final rule is `accept` (no-op).
#
# UCI control (/etc/config/pw2watchdog):
#   config killswitch 'killswitch'
#       option enabled         '1'    # master switch
#       option auto            '1'    # auto-arm based on fallback_action
#       option whitelist_extra ''     # space-separated IPs/CIDRs (manual)
#
# Auto-logic (when auto=1):
#   fallback_action=blackhole  → arm
#   fallback_action=rotate*    → arm
#   fallback_action=direct     → disarm
#
# Manual logic (when auto=0): obeys 'enabled' only.
#
# Functions (sourced by pw2watchdog.sh):
#   ks_should_arm           — decides if killswitch must be active right now
#                              based on UCI + current xray state
#   ks_ensure_table         — idempotently builds inet pw2wd_ks
#   ks_drop_table           — removes inet pw2wd_ks entirely
#   ks_arm                  — installs the final DROP rule (engages killswitch)
#   ks_disarm               — removes the final DROP rule (passes traffic)
#   ks_is_armed             — returns 0 if currently armed
#   ks_apply                — convergence: brings table state in line with policy
#   ks_status_json_vars     — exposes KS_* vars for write_status
#
# CLI (when run directly):
#   pw2watchdog-killswitch.sh status   — print current state
#   pw2watchdog-killswitch.sh arm      — force arm (testing)
#   pw2watchdog-killswitch.sh disarm   — force disarm (testing)
#   pw2watchdog-killswitch.sh drop     — drop table entirely
#   pw2watchdog-killswitch.sh apply    — run convergence once

KS_TABLE="inet pw2wd_ks"
KS_TABLE_NAME="pw2wd_ks"
KS_CHAIN="forward"
KS_LOG_TAG="ks"

# Logging — reuse log() from parent if sourced; else use logger.
if ! command -v log >/dev/null 2>&1; then
	log() { logger -t pw2wd-killswitch "$*"; }
fi

# ---------------------------------------------------------------------------
# Whitelist sources
# ---------------------------------------------------------------------------

# Read LAN networks (IPv4 + IPv6) from UCI 'network'. Returns space-separated
# CIDRs. Falls back to known default if uci fails.
_ks_lan_nets() {
	local ip mask cidr v6
	ip="$(uci -q get network.lan.ipaddr)"
	mask="$(uci -q get network.lan.netmask)"
	if [ -n "$ip" ] && [ -n "$mask" ]; then
		cidr="$(_ks_to_cidr "$ip" "$mask")"
		[ -n "$cidr" ] && printf '%s ' "$cidr"
	fi
	# IPv6 LAN prefix (if br-lan has one delegated)
	v6="$(ip -6 -o addr show dev br-lan scope global 2>/dev/null \
		| awk '{print $4}' | head -n1)"
	[ -n "$v6" ] && printf '%s ' "$v6"
}

# Convert ip+netmask → ip/CIDR (best-effort, busybox).
_ks_to_cidr() {
	local ip="$1" mask="$2" o1 o2 o3 o4 bits=0 octet
	IFS=. read o1 o2 o3 o4 <<EOF
$mask
EOF
	for octet in $o1 $o2 $o3 $o4; do
		case "$octet" in
			255) bits=$((bits + 8)) ;;
			254) bits=$((bits + 7)) ;;
			252) bits=$((bits + 6)) ;;
			248) bits=$((bits + 5)) ;;
			240) bits=$((bits + 4)) ;;
			224) bits=$((bits + 3)) ;;
			192) bits=$((bits + 2)) ;;
			128) bits=$((bits + 1)) ;;
			0)   : ;;
		esac
	done
	# Network address (clear host bits) — approximate, ok for /24 default
	echo "${ip%.*}.0/${bits}"
}

# Collect all VPS upstream IPv4 addresses from PassWall2 UCI.
# Filters out non-IPv4 values (domains, IPv6).
_ks_vps_ips() {
	uci -q show passwall2 2>/dev/null \
		| awk -F"['=]" '/\.address=/{print $(NF-1)}' \
		| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
		| sort -u
}

# User-defined extras from UCI.
_ks_extras() {
	uci -q get pw2watchdog.killswitch.whitelist_extra 2>/dev/null
}

# ---------------------------------------------------------------------------
# Decision logic
# ---------------------------------------------------------------------------

# Returns: 0 if killswitch should be armed, 1 if disarmed, 2 if disabled entirely.
ks_should_arm() {
	local enabled auto fb_action
	enabled="$(uci -q get pw2watchdog.killswitch.enabled 2>/dev/null)"
	[ "$enabled" = "1" ] || return 2   # disabled — no table at all

	auto="$(uci -q get pw2watchdog.killswitch.auto 2>/dev/null)"
	auto="${auto:-1}"

	if [ "$auto" = "0" ]; then
		# Manual: enabled=1 means always arm (since module-disable is enabled=0)
		return 0
	fi

	# auto=1 → decide by fallback_action
	fb_action="$(uci -q get pw2watchdog.main.fallback_action 2>/dev/null)"
	fb_action="${fb_action:-blackhole}"
	case "$fb_action" in
		direct)       return 1 ;;   # disarm
		blackhole|rotate*) return 0 ;;
		*)            return 0 ;;   # safe default
	esac
}

# ---------------------------------------------------------------------------
# Table operations
# ---------------------------------------------------------------------------

# Check if our table exists.
_ks_table_exists() {
	nft list tables 2>/dev/null | grep -q "table inet $KS_TABLE_NAME$"
}

# Check if armed: the forward chain ends with our explicit drop rule.
ks_is_armed() {
	_ks_table_exists || return 1
	nft list chain $KS_TABLE $KS_CHAIN 2>/dev/null \
		| grep -q 'comment "pw2wd_ks_drop"'
}

# Build the table with whitelist + permissive policy.
# Idempotent: drops and rebuilds.
ks_ensure_table() {
	local nets ips extras item
	nets="$(_ks_lan_nets)"
	ips="$(_ks_vps_ips | tr '\n' ' ')"
	extras="$(_ks_extras)"

	# Always rebuild — UCI state may have changed
	nft delete table $KS_TABLE 2>/dev/null

	# Build batch in tmp file for atomic load
	local batch="/tmp/pw2wd_ks.nft.$$"
	{
		echo "table inet $KS_TABLE_NAME {"
		echo "    chain $KS_CHAIN {"
		echo "        type filter hook forward priority -150; policy accept;"
		echo "        # --- whitelist: never touch these ---"
		echo "        ct state established,related accept comment \"pw2wd_ks_estab\""
		echo "        meta l4proto icmp accept"
		echo "        meta l4proto ipv6-icmp accept"
		# LAN nets
		for item in $nets; do
			case "$item" in
				*:*)  echo "        ip6 daddr $item accept comment \"pw2wd_ks_lan6\"" ;;
				*)    echo "        ip daddr $item accept comment \"pw2wd_ks_lan\"" ;;
			esac
		done
		# Broadcast/multicast/loopback safety
		echo "        ip daddr 127.0.0.0/8 accept"
		echo "        ip daddr 224.0.0.0/4 accept"
		echo "        ip daddr 255.255.255.255 accept"
		echo "        ip daddr 169.254.0.0/16 accept"
		# VPS upstreams
		for item in $ips; do
			echo "        ip daddr $item accept comment \"pw2wd_ks_vps\""
		done
		# Extras
		for item in $extras; do
			case "$item" in
				*:*)  echo "        ip6 daddr $item accept comment \"pw2wd_ks_extra\"" ;;
				*)    echo "        ip daddr $item accept comment \"pw2wd_ks_extra\"" ;;
			esac
		done
		echo "        # --- final verdict appended dynamically by ks_arm/ks_disarm ---"
		echo "    }"
		echo "}"
	} > "$batch"

	if ! nft -f "$batch" 2>>"$batch.err"; then
		log "$KS_LOG_TAG: failed to build table — $(cat "$batch.err" 2>/dev/null)"
		rm -f "$batch" "$batch.err"
		return 1
	fi
	rm -f "$batch" "$batch.err"

	local n_ips n_nets
	n_ips=$(echo "$ips" | wc -w)
	n_nets=$(echo "$nets" | wc -w)
	log "$KS_LOG_TAG: table built (lan_nets=$n_nets vps_ips=$n_ips)"
	return 0
}

# Drop the entire table.
ks_drop_table() {
	if _ks_table_exists; then
		nft delete table $KS_TABLE 2>/dev/null
		log "$KS_LOG_TAG: table dropped"
	fi
}

# Add the final DROP rule — engages the killswitch.
ks_arm() {
	if ! _ks_table_exists; then
		ks_ensure_table || return 1
	fi
	if ks_is_armed; then
		return 0   # already armed
	fi
	nft add rule $KS_TABLE $KS_CHAIN counter drop comment '"pw2wd_ks_drop"' 2>/dev/null || {
		log "$KS_LOG_TAG: arm failed — could not insert drop rule"
		return 1
	}
	log "$KS_LOG_TAG: ARMED (final drop rule installed)"
	return 0
}

# Remove the final DROP rule — disengages the killswitch.
ks_disarm() {
	_ks_table_exists || return 0
	local handles h
	handles="$(nft -a list chain $KS_TABLE $KS_CHAIN 2>/dev/null \
		| awk '/pw2wd_ks_drop.*handle/{gsub(/.*handle[[:space:]]*/,\"\"); print $1}')"
	for h in $handles; do
		nft delete rule $KS_TABLE $KS_CHAIN handle "$h" 2>/dev/null
	done
	[ -n "$handles" ] && log "$KS_LOG_TAG: disarmed (drop rules removed)"
	return 0
}

# ---------------------------------------------------------------------------
# Convergence: bring table state in line with policy + current proxy state.
# Call this once per main-loop iteration.
# Args: $1 = xray_alive ("true"/"false") — optional hint to avoid re-probing
# ---------------------------------------------------------------------------
ks_apply() {
	local xray_alive="${1:-}"
	ks_should_arm
	local policy=$?

	case "$policy" in
		2)
			# Disabled entirely → ensure table is gone
			ks_drop_table
			return 0
			;;
		1)
			# Policy says disarm (direct mode) → keep table but no DROP rule
			_ks_table_exists || ks_ensure_table
			ks_disarm
			return 0
			;;
		0)
			# Policy says arm — but only if xray is actually dead.
			# If xray is alive, keep table loaded but disarmed (warm standby).
			if [ -z "$xray_alive" ]; then
				# Caller didn't tell us — probe via _engine_alive if available
				if command -v _engine_alive >/dev/null 2>&1; then
					if _engine_alive; then xray_alive=true; else xray_alive=false; fi
				else
					# Fallback: pgrep xray
					if pgrep -f xray >/dev/null 2>&1; then
						xray_alive=true
					else
						xray_alive=false
					fi
				fi
			fi

			if [ "$xray_alive" = "true" ]; then
				# Warm standby: table loaded, but no DROP
				_ks_table_exists || ks_ensure_table
				ks_disarm
			else
				# Engine dead → ARM!
				ks_arm
			fi
			return 0
			;;
	esac
}

# ---------------------------------------------------------------------------
# Export state for write_status
# ---------------------------------------------------------------------------
ks_status_vars() {
	# Sets KS_ENABLED, KS_AUTO, KS_STATE, KS_TABLE_PRESENT, KS_VPS_COUNT
	KS_ENABLED="$(uci -q get pw2watchdog.killswitch.enabled 2>/dev/null)"
	KS_ENABLED="${KS_ENABLED:-0}"
	KS_AUTO="$(uci -q get pw2watchdog.killswitch.auto 2>/dev/null)"
	KS_AUTO="${KS_AUTO:-1}"
	if _ks_table_exists; then
		KS_TABLE_PRESENT=1
		if ks_is_armed; then
			KS_STATE="armed"
		else
			KS_STATE="standby"
		fi
	else
		KS_TABLE_PRESENT=0
		KS_STATE="disabled"
	fi
	KS_VPS_COUNT="$(_ks_vps_ips | wc -l)"
}

# ---------------------------------------------------------------------------
# CLI entry point — only when run directly (not sourced)
# ---------------------------------------------------------------------------
case "${0##*/}" in
	pw2watchdog-killswitch.sh|pw2watchdog-killswitch)
		case "$1" in
			arm)     ks_apply false ;;
			disarm)  ks_disarm ;;
			drop)    ks_drop_table ;;
			apply)   ks_apply ;;
			rebuild) ks_drop_table; ks_ensure_table ;;
			status)
				ks_status_vars
				echo "enabled=$KS_ENABLED auto=$KS_AUTO state=$KS_STATE table_present=$KS_TABLE_PRESENT vps_whitelist=$KS_VPS_COUNT"
				;;
			*)
				echo "Usage: $0 {arm|disarm|drop|apply|rebuild|status}"
				exit 1
				;;
		esac
		;;
esac
