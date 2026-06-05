#!/bin/sh
# pw2watchdog-subscribe.sh — PassWall2 subscription auto-update helper
#
# Updates all PassWall2 subscriptions (subscribe_list entries) and
# writes a timestamp to sub_update.json for the LuCI overview panel.
#
# Called by:
#   - pw2watchdog init.d script (on boot, if sub_update_on_boot=1)
#   - cron (daily at user-configured time, if sub_auto_update=1)
#   - manually: pw2watchdog-subscribe.sh run
#
# Usage:
#   pw2watchdog-subscribe.sh run        — update all subscriptions now
#   pw2watchdog-subscribe.sh install    — install cron/boot hooks per UCI
#   pw2watchdog-subscribe.sh uninstall  — remove all cron/boot hooks
#   pw2watchdog-subscribe.sh status     — show current hook state

STATE_DIR="/var/run/pw2watchdog"
ENV_FILE="$STATE_DIR/env.static"
SUB_STATE_FILE="$STATE_DIR/sub_update.json"
CONFIG_NAME="pw2watchdog"
CRON_FILE="/etc/crontabs/root"
CRON_TAG="pw2watchdog-subscribe"

log()  { logger -t pw2watchdog-subscribe "$*"; }
err()  { logger -t pw2watchdog-subscribe "ERROR: $*"; }
info() { log "$*"; }

# ---------------------------------------------------------------------------
# Load env.static — resolve first if missing or stale
# ---------------------------------------------------------------------------
_load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        info "env.static not found, running resolver..."
        if ! pw2watchdog-env.sh resolve; then
            err "env resolver failed — cannot continue"
            return 1
        fi
    fi
    # shellcheck source=/dev/null
    . "$ENV_FILE" || { err "failed to source $ENV_FILE"; return 1; }
    if [ -z "$PW2_PASSWALL_CONFIG" ]; then
        err "PW2_PASSWALL_CONFIG is empty in env.static"
        return 1
    fi
    if [ -z "$PW2_SHARE_DIR" ]; then
        err "PW2_SHARE_DIR is empty in env.static"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Load UCI settings for this script
# ---------------------------------------------------------------------------
_load_uci() {
    . /lib/functions.sh
    config_load "$CONFIG_NAME"
    config_get SUB_AUTO_UPDATE    advanced sub_auto_update    '0'
    config_get SUB_UPDATE_TIME    advanced sub_update_time    '04:00'
    config_get SUB_UPDATE_ON_BOOT advanced sub_update_on_boot '0'
}

# ---------------------------------------------------------------------------
# Get all subscribe_list cfgids from PassWall2 UCI
# Returns space-separated list of config IDs, e.g. "cfg1 cfg2"
# ---------------------------------------------------------------------------
_get_sub_cfgids() {
    local cfgids
    # uci show passwall2 | grep "=subscribe_list"
    # Output format: passwall2.cfg123abc=subscribe_list
    # cut: field 2 after '.', then field 1 before '='
    cfgids="$(uci show "$PW2_PASSWALL_CONFIG" 2>/dev/null \
        | grep '=subscribe_list' \
        | cut -d'.' -f2 \
        | cut -d'=' -f1)"
    echo "$cfgids"
}

# ---------------------------------------------------------------------------
# Write sub_update.json
# ---------------------------------------------------------------------------
_write_state() {
    local ts="$1"
    local count="$2"
    local result="$3"   # "ok" or "error"
    mkdir -p "$STATE_DIR"
    cat > "$SUB_STATE_FILE" <<JSON
{"ts":${ts},"subs_updated":${count},"result":"${result}"}
JSON
}

# ---------------------------------------------------------------------------
# cmd_run — main update logic
# ---------------------------------------------------------------------------
cmd_run() {
    info "starting subscription update"

    _load_env || return 1

    local subscribe_lua="${PW2_SHARE_DIR}/subscribe.lua"
    if [ ! -f "$subscribe_lua" ]; then
        err "subscribe.lua not found at $subscribe_lua"
        _write_state "$(date +%s)" 0 "error"
        return 1
    fi

    local cfgids
    cfgids="$(_get_sub_cfgids)"

    if [ -z "$cfgids" ]; then
        info "no subscribe_list entries found in UCI ($PW2_PASSWALL_CONFIG) — nothing to update"
        _write_state "$(date +%s)" 0 "ok"
        return 0
    fi

    local count=0
    local failed=0
    local id

    for id in $cfgids; do
        info "updating subscription: $id"
        # subscribe.lua start <cfgid> cron  — same call as PassWall2 app.sh cron handler
        if lua "$subscribe_lua" start "$id" cron; then
            info "subscription $id: OK"
            count=$((count + 1))
        else
            err "subscription $id: FAILED (lua exited $?)"
            failed=$((failed + 1))
        fi
    done

    local ts
    ts="$(date +%s)"

    if [ "$failed" -gt 0 ]; then
        err "subscription update finished: $count ok, $failed failed"
        _write_state "$ts" "$count" "error"
        return 1
    fi

    info "subscription update finished: $count subscription(s) updated"
    _write_state "$ts" "$count" "ok"
    return 0
}

# ---------------------------------------------------------------------------
# Cron line builder
# ---------------------------------------------------------------------------
_build_cron_line() {
    local time="$1"   # HH:MM
    local hour min

    # Validate and parse HH:MM
    hour="$(echo "$time" | cut -d: -f1)"
    min="$(echo  "$time" | cut -d: -f2)"

    # Fallback to 04:00 if format is wrong
    case "$hour" in
        [0-9]|[01][0-9]|2[0-3]) ;;
        *) hour="4"; min="0" ;;
    esac
    case "$min" in
        [0-9]|[0-5][0-9]) ;;
        *) min="0" ;;
    esac

    # Strip leading zeros for cron (ash cron is strict)
    hour="$(echo "$hour" | sed 's/^0*//')"
    min="$(echo  "$min"  | sed 's/^0*//')"
    [ -z "$hour" ] && hour="0"
    [ -z "$min"  ] && min="0"

    echo "$min $hour * * * /usr/bin/pw2watchdog-subscribe.sh run # $CRON_TAG"
}

# ---------------------------------------------------------------------------
# cmd_install — install cron + boot hooks based on UCI
# ---------------------------------------------------------------------------
cmd_install() {
    _load_env  || return 1
    _load_uci

    info "installing hooks: auto_update=$SUB_AUTO_UPDATE on_boot=$SUB_UPDATE_ON_BOOT time=$SUB_UPDATE_TIME"

    # Always remove old lines first (idempotent)
    _remove_cron_lines

    if [ "$SUB_AUTO_UPDATE" = "1" ]; then
        local cron_line
        cron_line="$(_build_cron_line "$SUB_UPDATE_TIME")"
        info "adding cron: $cron_line"

        # Ensure cron file exists
        touch "$CRON_FILE"

        # Append cron line
        echo "$cron_line" >> "$CRON_FILE"

        # Reload crond
        /etc/init.d/cron reload 2>/dev/null || true

        info "cron hook installed"
    else
        info "sub_auto_update=0 — cron hook not installed"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# cmd_uninstall — remove all hooks
# ---------------------------------------------------------------------------
cmd_uninstall() {
    info "removing all pw2watchdog-subscribe hooks"
    _remove_cron_lines
    /etc/init.d/cron reload 2>/dev/null || true
    info "uninstall done"
}

# ---------------------------------------------------------------------------
# Remove our tagged cron lines
# ---------------------------------------------------------------------------
_remove_cron_lines() {
    [ -f "$CRON_FILE" ] || return 0
    # Remove any line containing our tag
    sed -i "/$CRON_TAG/d" "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# cmd_status — show current state
# ---------------------------------------------------------------------------
cmd_status() {
    _load_env 2>/dev/null
    _load_uci

    echo "── UCI settings ────────────────────────────────"
    echo "  sub_auto_update:    $SUB_AUTO_UPDATE"
    echo "  sub_update_time:    $SUB_UPDATE_TIME"
    echo "  sub_update_on_boot: $SUB_UPDATE_ON_BOOT"
    echo ""
    echo "── Cron ────────────────────────────────────────"
    if [ -f "$CRON_FILE" ] && grep -q "$CRON_TAG" "$CRON_FILE"; then
        echo "  installed:"
        grep "$CRON_TAG" "$CRON_FILE"
    else
        echo "  not installed"
    fi
    echo ""
    echo "── Last update ─────────────────────────────────"
    if [ -f "$SUB_STATE_FILE" ]; then
        echo "  $(cat "$SUB_STATE_FILE")"
    else
        echo "  never"
    fi
    echo ""
    echo "── Subscriptions in UCI ────────────────────────"
    if _load_env 2>/dev/null; then
        local cfgids
        cfgids="$(_get_sub_cfgids)"
        if [ -n "$cfgids" ]; then
            local id
            for id in $cfgids; do
                local remark
                remark="$(uci get "${PW2_PASSWALL_CONFIG}.${id}.remark" 2>/dev/null || echo '?')"
                echo "  $id  ($remark)"
            done
        else
            echo "  none found"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
run)
    cmd_run
    exit $?
    ;;
install)
    cmd_install
    exit $?
    ;;
uninstall)
    cmd_uninstall
    exit $?
    ;;
status)
    cmd_status
    exit 0
    ;;
*)
    echo "Usage: $0 {run|install|uninstall|status}"
    exit 1
    ;;
esac
