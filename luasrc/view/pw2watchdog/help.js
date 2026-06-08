'use strict';
'require view';

function renderNote(title, items) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', title),
		E('ul', { 'style': 'margin:0;padding-left:18px;' },
			items.map(function(item) {
				return E('li', { 'style': 'margin:0 0 0.5em 0;' }, item);
			})
		)
	]);
}

return view.extend({
	handleSave:      null,
	handleSaveApply: null,
	handleReset:     null,

	render: function() {
		return E('div', {}, [
			E('div', { 'class': 'cbi-map' }, [
				E('h2', _('PassWall2 Watchdog — Help')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Reference notes for pw2watchdog configuration and behavior.')
				),

				renderNote(_('Setup order'), [
					_('PassWall2 must be fully working before enabling the watchdog: subscription added, nodes fetched, a real proxy node set as the default in Shunt Rules.'),
					_('Step 1: Services → PassWall2 → Node Subscribe — add your subscription URL and fetch nodes.'),
					_('Step 2: Node list → URL Test — test nodes, identify the best working one.'),
					_('Step 3: Basic Settings → Main → Node — set "Node Xray_shunt: [rulenode]" (or whatever your shunt rule node is named).'),
					_('Step 4: Shunt Rules → Default — set a real proxy node as the default.'),
					_('The watchdog reads passwall2.rulenode.default_node. If this is empty, _direct, or _blackhole, the watchdog will not operate correctly.'),
					_('Enable the watchdog in Settings, choose node selection mode and fallback action, then Save & Apply.'),
					_('Open Overview to confirm the current node and latency are visible.')
				]),

				renderNote(_('Node selection modes'), [
					_('Auto: the watchdog scans the full PassWall2 node list and automatically maintains a pool of the best N candidates. The pool is updated after each scanner cycle. Recommended for most setups.'),
					_('Manual: you pin specific candidates on the Nodes page. The watchdog only picks the best node from that fixed list. Use this when you want to restrict selection to a known-good subset.')
				]),

				renderNote(_('Latency and switching'), [
					_('Every check_interval seconds the watchdog measures latency for all candidates by running PassWall2 test.sh through each node.'),
					_('A switch happens only if the best candidate is faster than the current node by at least latency_improvement_threshold milliseconds, and min_switch_interval seconds have elapsed since the last switch.'),
					_('Nodes with latency above max_latency are treated as dead for that cycle.'),
					_('These are operational measurements under real traffic conditions, not synthetic benchmarks.')
				]),

				renderNote(_('Fallback policy'), [
					_('When all candidates exceed max_latency or fail, the fallback action is triggered.'),
					_('Blackhole inserts a static nft drop rule into the PassWall2 mangle chain. Proxy-bound traffic is dropped until a healthy node is found. No unproxied leaks. Strongly recommended.'),
					_('Direct does nothing — PassWall2 continues with the current node. Traffic may pass unproxied if PassWall2 itself is in a degraded state.'),
					_('Rotate cycles through all live nodes from the scanner cache one by one (circular buffer). Each watchdog cycle moves the cursor by one node, regardless of how many candidates died. The active pool (shown in Candidates) always fills to the recommended size with the best available nodes starting at the cursor position. After the configured number of full rotations, the final action (blackhole or direct) is applied.'),
					_('The watchdog does not use _blackhole or _direct as PassWall2 node targets. The blackhole is a real nftables rule, independent of node switching.')
				]),

				renderNote(_('Transit Blackhole'), [
					_('When switching nodes, PassWall2 briefly restarts. During this window, the watchdog inserts the same nft drop rule before the restart and removes it once the new node is confirmed ready.'),
					_('Transit Blackhole requires a working environment: nftables chain and fwmark must be resolved correctly by pw2watchdog-env.sh. If env resolution fails, Transit Blackhole is silently disabled.'),
					_('Use pw2watchdog-env.sh check in a terminal to verify env status. If errors are reported, fill in the failing fields in Advanced Settings.')
				]),

				renderNote(_('Advanced Settings'), [
					_('All Advanced Settings fields are optional. Leave them blank — pw2watchdog-env.sh will auto-detect all paths and parameters from the running PassWall2 installation.'),
					_('Fill in a field only if auto-detection fails for that specific value on your setup. Check pw2watchdog-env.sh check output to see what failed.'),
					_('Reset advanced to auto-detect clears all path overrides. Subscription settings are not affected by this button.'),
					_('The env cache has a 1-hour TTL. After changing Advanced Settings or updating PassWall2, run pw2watchdog-env.sh resolve --force to apply immediately.'),
					_('Auto-restart PassWall2 on failure: when enabled, the watchdog checks at the start of every cycle whether PassWall2 is running. If it is not, PassWall2 is restarted once and the timestamp is recorded. This prevents false “all candidates dead” events caused by a crashed PassWall2 process. The last restart time is shown in Advanced Settings under the checkbox.')
				]),

				renderNote(_('Subscription auto-update'), [
					_('Some PassWall2 builds do not update subscriptions automatically. Enable Subscription auto-update in Advanced Settings to add a daily cron job.'),
					_('After Save & Apply, the cron job is installed automatically. Verify with crontab -l or pw2watchdog-subscribe.sh status.'),
					_('Update subscriptions on boot runs one update shortly after each service start, in addition to the daily schedule.'),
					_('tr: write error: Broken pipe in the terminal output of pw2watchdog-subscribe.sh run is a known cosmetic issue from PassWall2 subscribe.lua. It does not indicate a failure — check the result field in /var/run/pw2watchdog/sub_update.json instead.')
				]),

				renderNote(_('Node fields'), [
					_('Label is the human-readable node name taken from PassWall2 remarks.'),
					_('Protocol is the main proxy type: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, etc.'),
					_('Transport is the connection layer: TCP, WS, gRPC, HTTPUpgrade, XHTTP, QUIC, mKCP, etc.'),
					_('Security shows the handshake mode: TLS, REALITY, or none.')
				]),

				renderNote(_('Diagnostics'), [
					_('logread | grep pw2watchdog | tail -30 — live watchdog and scanner log.'),
					_('pw2watchdog-env.sh check — show resolved paths, hardware info, and live proxy port status.'),
					_('pw2watchdog-env.sh resolve --force — force env re-detection.'),
					_('pw2watchdog.sh run — run one watchdog cycle manually.'),
					_('pw2watchdog-subscribe.sh status — show subscription settings, cron state, and last update result.'),
					_('pw2watchdog-subscribe.sh run — update all subscriptions immediately.')
				]),

				renderNote(_('Limitations'), [
					_('Candidate count: on MT7621 with default settings the recommended maximum is 3 candidates. The Overview page warns if you exceed the recommended count.'),
					_('After router reboot, PassWall2 needs time to fully initialize before nodes can be tested. Running URL Test or a manual watchdog cycle immediately after boot will produce timeouts. Wait 30\u201360 seconds after PassWall2 appears online. The watchdog handles this automatically on service start.'),
					_('Node metadata (protocol, transport, security) is taken from PassWall2 UCI and may fall back to label heuristics if UCI fields are absent.'),
					_('Special entries _direct, _blackhole and _default are shown as special modes, not real proxy nodes.'),
					_('All runtime files live in /var/run/pw2watchdog/ on tmpfs and are lost on reboot. They are recreated automatically on service start.'),
					_('The ACL file /usr/share/rpcd/acl.d/luci-app-pw2watchdog.json controls which runtime files the LuCI frontend can read. Missing entries cause silent empty data in the UI.')
				])
			])
		]);
	}
});
