# pw2watchdog

A LuCI application for OpenWrt that monitors PassWall2 proxy nodes, automatically switches to the best available node based on latency measurements, and activates a fallback policy when all candidates fail.

**Tested on:**
- OpenWrt 23.05.5 (`ramips/mt7621`, Asus RT-AX53U)
- PassWall2 `26.4.20`
- Lua 5.1.5

---

## How it works

Two background daemons run continuously under procd:

**`pw2watchdog.sh daemon`** — the main watchdog loop. Every `check_interval` seconds it:
1. Measures latency for all candidate nodes by running PassWall2's own `test.sh` through each node
2. Finds the best candidate (lowest latency below `max_latency`)
3. Switches PassWall2's default node (`passwall2.rulenode.default_node`) if the improvement exceeds `latency_improvement_threshold` and `min_switch_interval` has elapsed
4. If all candidates fail — activates the fallback policy (Blackhole or Direct)
5. Writes runtime state to `/var/run/pw2watchdog/status.json` and appends a decision record to `/var/run/pw2watchdog/history.jsonl`

**`pw2watchdog-scanner.sh daemon`** — runs in parallel. Periodically scans the full PassWall2 node list and writes latency scores to `/var/run/pw2watchdog/latency_cache.json`. In `auto` node selection mode, the watchdog uses this cache to rotate the candidate pool automatically.

**`pw2watchdog-env.sh`** — service discovery helper. Finds all PassWall2 paths and parameters programmatically (init script, share dir, nftables chain, fwmark, etc.) and caches the result in `/var/run/pw2watchdog/env.static`. All other scripts source this file — no hardcoded paths anywhere. Re-runs automatically if the cache is stale (TTL 1 hour) or on first boot.

**`pw2watchdog-subscribe.sh`** — optional subscription auto-update helper. Updates all PassWall2 `subscribe_list` entries via `subscribe.lua` and installs/removes a cron job based on UCI settings.

### Fallback policy

When all candidate nodes exceed `max_latency` or fail:

- **Blackhole** (recommended) — inserts a static `nft drop` rule into the PassWall2 mangle chain. Proxy traffic is dropped. No unproxied leaks. The rule is removed as soon as a healthy node is found.
- **Direct** — does nothing. PassWall2 continues with whatever node is currently set.
- **Rotate** — cycles through all live nodes from the scanner cache using a circular buffer. Each watchdog cycle advances the cursor by exactly **one** node position. The active candidate pool fills to `recommended_candidates` nodes starting at the cursor (wrapping around if needed), always picking the lowest-latency nodes in that window. After the configured number of full rotations through the entire live-node list, the **final action** (Blackhole or Direct) is applied and the rotation counter resets.

  > Why one step at a time? If one proxy died, one new candidate is tried per cycle. If three died, new candidates fill in naturally over the next few cycles. No group-jumping, no edge cases at list boundaries.

> The watchdog does **not** use `_blackhole` or `_direct` as PassWall2 node targets. The blackhole is implemented as a real nftables rule, independent of node switching.

### PassWall2 health check

At the start of every watchdog cycle, the watchdog checks whether the PassWall2 init script reports the service as running. If PassWall2 is found dead:

- A `passwall2 health check: service not running` message is logged.
- If **Auto-restart PassWall2 on failure** is enabled in Advanced Settings, PassWall2 is restarted once and the timestamp is recorded in state (`LAST_PW2_RESTART`) and shown in the Settings page.
- This prevents false "all candidates dead" events that are actually caused by a crashed PassWall2 process rather than failing proxy nodes.

### Transit Blackhole

During a node switch, PassWall2 briefly has no active proxy (restart in progress). The watchdog inserts the same nft drop rule before calling `passwall2 restart` and removes it after the new node is confirmed ready. This prevents traffic leaks during the switch window.

---

## File layout

```
/usr/bin/pw2watchdog.sh                          main watchdog daemon
/usr/bin/pw2watchdog-scanner.sh                  latency scanner daemon
/usr/bin/pw2watchdog-env.sh                      service discovery / env builder
/usr/bin/pw2watchdog-subscribe.sh                subscription auto-update helper
/etc/init.d/pw2watchdog                          procd init script
/www/luci-static/resources/view/pw2watchdog/     LuCI views
    overview.js                                  runtime status page
    settings.js                                  configuration page
    nodes.js                                     node list with latency
    help.js                                      help page
/usr/share/rpcd/acl.d/luci-app-pw2watchdog.json  rpcd ACL
/var/run/pw2watchdog/                            runtime state (tmpfs, lost on reboot)
    env.static                                   resolved paths and hw info
    status.json                                  current watchdog state
    history.jsonl                                decision log (one JSON per line)
    latency_cache.json                           per-node latency from scanner
    sub_update.json                              last subscription update result
```

---

## Setup order

Follow this order exactly — each step depends on the previous one.

### 1. Configure PassWall2 first

Before enabling the watchdog, PassWall2 must be working:

1. **Services → PassWall2 → Node Subscribe** — add your subscription URL
2. **Node Subscribe → Manual Subscribe** — update the subscription (fetch nodes)
3. **Node list → URL Test** — test nodes, identify the best working one
4. **Basic Settings → Main → Node** — set `Node Xray_shunt: [rulenode]` (or whatever your shunt rule node is named)
5. **Shunt Rules → Default** — set a real proxy node as the default
6. Verify that proxy traffic actually works through PassWall2

> The watchdog reads `passwall2.rulenode.default_node`. If this is empty, `_direct`, or `_blackhole`, the watchdog will not start correctly.

### 2. Enable the watchdog

1. **Services → PassWall2 Watchdog → Settings**
2. Set **Enabled** = on
3. Choose **Node selection mode**:
   - `Auto` — watchdog picks the best N candidates from the full node pool automatically. Recommended.
   - `Manual` — you pin specific candidates on the Nodes page.
4. Choose **Fallback action** — `Blackhole` is strongly recommended
5. **Save & Apply**

### 3. Verify

Open **Overview** — you should see:
- Current default node and its latency
- Best candidate node
- Last decision reason

Check logs:
```sh
logread | grep pw2watchdog | tail -30
```

Check env resolution:
```sh
pw2watchdog-env.sh check
```

---

## Subscription auto-update

Some PassWall2 builds do not update subscriptions automatically. The watchdog includes an optional helper for this.

**Settings → Advanced settings → Subscription auto-update:**

| Option | Default | Description |
|---|---|---|
| Subscription auto-update | off | Enable daily cron update |
| Subscription update time | 04:00 | Daily update time (HH:MM, 24h, router local time) |
| Update subscriptions on boot | off | Run one update after each service start |

After **Save & Apply**, the cron job is installed automatically. Verify:
```sh
crontab -l
pw2watchdog-subscribe.sh status
```

Manual update:
```sh
pw2watchdog-subscribe.sh run
```

Result is written to `/var/run/pw2watchdog/sub_update.json`. When auto-update is enabled, the **Overview** page shows the last update time.

> `tr: write error: Broken pipe` in the output of `subscribe.sh run` is normal — it comes from PassWall2's internal `subscribe.lua` pipeline and does not indicate a failure. Check the exit status or `sub_update.json` instead.

---

## Advanced settings

All fields are optional. Leave blank to use auto-detected values. Fill in only if auto-detection fails on your setup.

| Field | Auto-detected from |
|---|---|
| PassWall2 init script | `/etc/init.d/<passwall_config>` |
| PassWall2 test script | `$share_dir/test.sh` |
| NFT table name | parsed from `nftables.sh` |
| NFT chain (mangle) | live nftables state or `nftables.sh` |
| PassWall2 tmp path | parsed from `utils.sh` |
| NFT script path | `$share_dir/nftables.sh` |
| Utils script path | `$share_dir/utils.sh` |
| Firewall mark (hex) | parsed from `nftables.sh` |

**Reset advanced to auto-detect** — clears all override fields. The watchdog will re-run service discovery on next cycle.

If auto-detection fails (env errors > 0), the Overview will show a warning. Use `pw2watchdog-env.sh check` to diagnose, then fill in the failing fields manually.

---

## UCI reference

```
pw2watchdog.main=config
  enabled                       1|0
  passwall_config               passwall2
  passwall_section              rulenode
  check_interval                seconds between cycles (default 180)
  timeout                       seconds per node test (default 4)
  max_latency                   ms, nodes above this are dead (default 1500)
  min_switch_interval           seconds between switches (default 600)
  latency_improvement_threshold ms improvement required to switch (default 80)
  test_url                      URL for latency measurement
  node_selection                auto|manual
  fallback_action               blackhole|direct
  candidate_node                list of node IDs (manual mode)
  exclude_node                  list of node IDs always excluded

pw2watchdog.advanced=config
  init_script                   override: PassWall2 init script path
  test_script                   override: test.sh path
  nftable_name                  override: nftables table name
  nftchain_mangle               override: nftables mangle chain name
  tmp_path                      override: PassWall2 tmp dir
  nftables_script               override: nftables.sh path
  utils_script                  override: utils.sh path
  fwmark                        override: fwmark hex value
  sub_auto_update               1|0
  sub_update_time               HH:MM
  sub_update_on_boot            1|0
```

---

## Runtime files

All runtime files live in `/var/run/pw2watchdog/` (tmpfs — lost on reboot, recreated automatically).

**`status.json`** — updated after every watchdog cycle:
```json
{
  "current_node": "xS95Tzji",
  "current_latency": 142,
  "best_node": "n1mlBLGP",
  "best_latency": 98,
  "last_reason": "best_latency",
  "last_switch": 1780238055,
  "candidate_count": 3,
  "recommended_candidates": 3,
  "cpu_model": "MIPS 1004Kc V2.15",
  "running": false
}
```

**`history.jsonl`** — one JSON object per line, newest events appended:
```json
{"ts":1780358023,"action":"switch","node":"n1mlBLGP","reason":"best_latency"}
```

**`sub_update.json`** — written by `pw2watchdog-subscribe.sh run`:
```json
{"ts":1780667833,"subs_updated":1,"result":"ok"}
```

---

## Diagnostics

```sh
# Service status
/etc/init.d/pw2watchdog status

# Live logs
logread | grep pw2watchdog | tail -30

# Env check (paths, hw info, live proxy port)
pw2watchdog-env.sh check

# Force env re-detection (after PassWall2 update etc.)
pw2watchdog-env.sh resolve --force

# Manual watchdog cycle
pw2watchdog.sh run

# Subscription update status
pw2watchdog-subscribe.sh status

# Manual subscription update
pw2watchdog-subscribe.sh run

# Check cron hooks
crontab -l
```

---

## ACL

The file `/usr/share/rpcd/acl.d/luci-app-pw2watchdog.json` grants the LuCI frontend read access to runtime files. If you add new runtime files that the UI needs to read, add them here and run `/etc/init.d/rpcd restart`.

---

## Monitor proxy connection

An optional feature that periodically checks whether traffic is actually going through the proxy, by querying an external IP-echo URL and matching the result against known PassWall2 node addresses and configured direct IP ranges.

### How it works

1. Once per configured interval (minimum 60 s, default 120 s), `pw2watchdog.sh` runs `_check_proxy_connection()`
2. `curl` fetches the external IP from the configured URL (default `https://api.ipify.org`)
3. The result is matched against PassWall2 node addresses from UCI (all sections with an `address` field containing a valid IP)
4. If not matched against a node, the result is compared against user-configured **Direct IP ranges** (CIDR list)
5. State and node label are written to `status.json` and displayed in Overview under **Monitor proxy connection**

| State | Meaning |
|---|---|
| **Proxy OK** + flag + label | External IP matched a known proxy node — node identified |
| **Proxy OK** (no label) | External IP not in node list and not in direct ranges — proxied via unknown node |
| **Direct** | External IP matched one of the configured direct CIDR ranges |
| **Blackhole** | nft DROP rule is active — no HTTP check performed |

### Enable and recommended first-time setup

1. `opkg install curl` (required)
2. Settings → Advanced → **Monitor proxy connection** → enable
3. Set **Direct IP ranges**: your ISP address range in CIDR notation (e.g. `198.51.100.0/24`).  
   A single IP without mask is also accepted (treated as `/32`).
4. Set **Check interval** (minimum 60 s)
5. **Save & Apply**
6. Open Overview — after the first check cycle the monitor block will show the current state

#### How to find your Direct IP range

1. Go to **[https://2ip.io](https://2ip.io)** — note your current external IP address
2. Go to **[https://2ip.io/whois/](https://2ip.io/whois/)** — find the **CIDR** field in the result
3. Copy that value (e.g. `198.51.100.0/24`) into Settings → Advanced → **Monitor: Direct IP ranges**

> Your ISP may use dynamic IPs within a fixed pool. The CIDR range from WHOIS covers the whole pool, so the direct detection will work even if your specific IP changes.

### Monitor vs Current node — what to trust

The monitor and the **Current node** field in Overview are updated independently and may briefly show different servers — this is expected.

- **Current node** reflects what the watchdog last wrote to PassWall2 UCI. It is updated every `check_interval` seconds (default 180 s). It is an *instruction*, not a measurement: it says which node the watchdog selected, but it does not confirm that traffic is actually flowing through it.
- **Monitor** performs a real HTTP request through the live traffic path and returns the actual external IP. It is updated every `proxy_check_interval` seconds (default 120 s, minimum 60 s). It is a *measurement*.

After a node switch, PassWall2 restarts briefly. During that restart window — and until the next monitor check cycle completes — the two fields may point to different nodes. This is normal and resolves on its own within one check interval.

**If you want to know what proxy your traffic is actually using right now, trust the monitor.** It reflects reality, not intent.

### Important caveats

- **Timing lag** — the displayed state reflects the _last completed_ check. With a 120 s interval, up to 2 minutes may pass between the actual state change and the display update.
- **Shunt / split-routing** — if the IP-echo URL is routed directly (not through the proxy) by your PassWall2 shunt rules or any other routing rule, the check will always show **Direct** even when the proxy is working correctly. Use a URL that is proxied in your setup.
- **Single check URL** — only one URL is used. There is no cross-validation.
- **Interval minimum** — cannot be set below 60 seconds.
- **Direct ranges optional** — if left empty, direct detection is disabled. The monitor will still identify proxy nodes by address and show their label/flag.

## Known limitations and notes

- **Candidate count** — on MT7621 with default settings (`check_interval=180`, `timeout=4`) the recommended maximum is 3 candidates. More candidates mean the scanner may not finish within one interval, causing stale latency data. The Overview page warns if you exceed the recommended count.
- **Transit Blackhole requires working env** — if `pw2watchdog-env.sh` reports errors (nftables chain not found, fwmark missing), Transit Blackhole is silently disabled. Fix env errors first via Advanced Settings overrides.
- **`sub_update_on_boot`** — runs `subscribe.lua` in the background a few seconds after service start. If PassWall2 is not yet ready at that moment, the update may partially fail. Check `sub_update.json` result field.
- **Broken pipe from subscribe.lua** — `tr: write error: Broken pipe` is a known cosmetic issue in PassWall2's subscribe pipeline. It does not affect the result.
- **UCI ACL** — `/usr/share/rpcd/acl.d/luci-app-pw2watchdog.json` must include all runtime files the LuCI frontend reads. Missing entries cause 403 errors in the browser console and silent empty data in the UI.
- **Boot delay** — after router reboot, PassWall2 needs time to fully initialize before the watchdog can test nodes. If you run a manual cycle or URL Test immediately after boot, nodes will time out. Wait 30–60 seconds after PassWall2 appears online before testing. The watchdog handles this automatically via `pw2_wait_proxy_ready` on service start.
- **env.static TTL** — env is cached for 1 hour. After updating PassWall2 or changing Advanced Settings overrides, run `pw2watchdog-env.sh resolve --force` to force a refresh before the next watchdog cycle.

---

## Localization

All user-facing strings in JS views are wrapped in `_('...')` (LuCI i18n). Shell script comments and log messages are in English. A `.po`/`.pot` translation workflow is planned.
