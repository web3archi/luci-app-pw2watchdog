'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';

function getNodeLabel(nodeId) {
	if (!nodeId) return '';
	if (nodeId === '_direct')    return _('Direct');
	if (nodeId === '_blackhole') return _('Blackhole');
	if (nodeId === '_default')   return _('Internal default alias');
	return uci.get('passwall2', nodeId, 'remarks') || '';
}

function restoreDefaults(map) {
	uci.set('pw2watchdog', 'main', 'enabled',                       '1');
	uci.set('pw2watchdog', 'main', 'passwall_config',               'passwall2');
	uci.set('pw2watchdog', 'main', 'passwall_section',              'rulenode');
	uci.set('pw2watchdog', 'main', 'check_interval',                '180');
	uci.set('pw2watchdog', 'main', 'timeout',                       '4');
	uci.set('pw2watchdog', 'main', 'max_latency',                   '1500');
	uci.set('pw2watchdog', 'main', 'min_switch_interval',           '600');
	uci.set('pw2watchdog', 'main', 'latency_improvement_threshold', '80');
	uci.set('pw2watchdog', 'main', 'test_url',                      'https://cp.cloudflare.com/generate_204');
	uci.set('pw2watchdog', 'main', 'node_selection',                'auto');
	uci.set('pw2watchdog', 'main', 'fallback_action',               'blackhole');

	ui.addNotification(null, E('p', _('Default values have been restored. Click Save & Apply to commit them.')));

	return map.render().then(function(node) {
		var container = document.querySelector('.cbi-map');
		if (container && container.parentNode)
			container.parentNode.replaceChild(node, container);
		else
			document.body.appendChild(node);
	});
}

function resetAdvanced(map) {
	uci.unset('pw2watchdog', 'advanced', 'init_script');
	uci.unset('pw2watchdog', 'advanced', 'test_script');
	uci.unset('pw2watchdog', 'advanced', 'nftable_name');
	uci.unset('pw2watchdog', 'advanced', 'nftchain_mangle');
	uci.unset('pw2watchdog', 'advanced', 'tmp_path');
	uci.unset('pw2watchdog', 'advanced', 'nftables_script');
	uci.unset('pw2watchdog', 'advanced', 'utils_script');
	uci.unset('pw2watchdog', 'advanced', 'fwmark');

	ui.addNotification(null, E('p', _(
		'Advanced overrides cleared. Click Save & Apply — the watchdog will auto-detect paths on next run.'
	)));

	return map.render().then(function(node) {
		var container = document.querySelector('.cbi-map');
		if (container && container.parentNode)
			container.parentNode.replaceChild(node, container);
		else
			document.body.appendChild(node);
	});
}

/* ------------------------------------------------------------------ *
 *  "Measurement in progress" banner — infinite CSS animation
 * ------------------------------------------------------------------ */
function renderRunningBanner() {
	var styleId = 'pw2-indeterminate-style';
	if (!document.getElementById(styleId)) {
		var style = document.createElement('style');
		style.id  = styleId;
		style.textContent =
			'@keyframes pw2-slide{' +
			'0%{transform:translateX(-100%)}' +
			'100%{transform:translateX(400%)}' +
			'}' +
			'.pw2-indeterminate{' +
			'position:relative;height:6px;background:#fde68a;' +
			'border-radius:3px;overflow:hidden;margin-top:8px;' +
			'}' +
			'.pw2-indeterminate-bar{' +
			'position:absolute;top:0;left:0;width:25%;height:100%;' +
			'background:#f59e0b;border-radius:3px;' +
			'animation:pw2-slide 1.4s linear infinite;' +
			'}';
		document.head.appendChild(style);
	}
	return E('div', {
		'id': 'pw2-running-banner',
		'style': 'display:none;padding:12px 14px;border:1px solid #f59e0b;' +
		         'background:#fffbea;color:#78350f;border-radius:4px;margin-bottom:1em;'
	}, [
		E('strong', _('\u26a0 Node measurement in progress \u2014 do not change settings')),
		E('div', { 'style': 'margin-top:4px;font-size:0.9em;' },
			_('The watchdog is currently measuring latency for candidate nodes. ' +
			  'Saving settings during this time may cause incorrect results or a missed switch cycle.')
		),
		E('div', { 'class': 'pw2-indeterminate' }, [ E('div', { 'class': 'pw2-indeterminate-bar' }) ])
	]);
}

function startRunningPoller(bannerEl) {
	function poll() {
		fs.read('/var/run/pw2watchdog/status.json').then(function(raw) {
			var st = {};
			try { st = JSON.parse(raw || '{}'); } catch(e) {}
			if (st.running === 'true' || st.running === true) {
				bannerEl.style.display = '';
				setTimeout(poll, 3000);
			} else {
				bannerEl.style.display = 'none';
			}
		}).catch(function() { bannerEl.style.display = 'none'; });
	}
	poll();
}

/* ------------------------------------------------------------------ *
 *  Excess candidates banner
 * ------------------------------------------------------------------ */
function renderExcessBanner(currentCount, recommendedCount) {
	if (!recommendedCount || !currentCount || currentCount <= recommendedCount)
		return null;
	return E('div', {
		'style': 'padding:12px 14px;border:1px solid #f1b0b7;background:#fff5f5;' +
		         'color:#842029;border-radius:4px;margin-bottom:1em;'
	}, [
		E('strong', _('Too many candidate nodes.')),
		E('div', { 'style': 'margin-top:4px;' },
			_('You have %d candidates selected, but the recommended maximum for this device is %d. ' +
			  'Reduce the number of candidates, or switch to Auto mode in Settings.')
			.format(currentCount, recommendedCount)
		)
	]);
}

/* ------------------------------------------------------------------ *
 *  View
 * ------------------------------------------------------------------ */
return view.extend({
	load: function() {
		return Promise.all([
			uci.load('pw2watchdog'),
			uci.load('passwall2'),
			L.resolveDefault(
				fs.read('/var/run/pw2watchdog/status.json').then(function(d) {
					try { return JSON.parse(d); } catch(e) { return {}; }
				}), {}
			)
		]);
	},

	render: function(data) {
		var status               = data[2] || {};
		var recommendedCandidates = parseInt(status.recommended_candidates || 0);
		var candidateCount        = parseInt(status.candidate_count        || 0);

		var passwallDefault = uci.get('passwall2', 'rulenode', 'default_node');
		var pwState = 'missing';
		if (passwallDefault === '_direct' || passwallDefault === '_blackhole') pwState = 'special';
		else if (passwallDefault === '_default') pwState = 'special_default';
		else if (passwallDefault) pwState = 'ok';

		/* Initialize main section on first run */
		if (!uci.get('pw2watchdog', 'main')) {
			uci.add('pw2watchdog', 'config', 'main');
			uci.set('pw2watchdog', 'main', 'enabled',                       '1');
			uci.set('pw2watchdog', 'main', 'passwall_config',               'passwall2');
			uci.set('pw2watchdog', 'main', 'passwall_section',              'rulenode');
			uci.set('pw2watchdog', 'main', 'check_interval',                '180');
			uci.set('pw2watchdog', 'main', 'timeout',                       '4');
			uci.set('pw2watchdog', 'main', 'max_latency',                   '1500');
			uci.set('pw2watchdog', 'main', 'min_switch_interval',           '600');
			uci.set('pw2watchdog', 'main', 'latency_improvement_threshold', '80');
			uci.set('pw2watchdog', 'main', 'test_url',                      'https://cp.cloudflare.com/generate_204');
			uci.set('pw2watchdog', 'main', 'node_selection',                'auto');
			uci.set('pw2watchdog', 'main', 'fallback_action',               'blackhole');
		}

		/* Initialize advanced section if absent (fields empty — auto-detect) */
		if (!uci.get('pw2watchdog', 'advanced')) {
			uci.add('pw2watchdog', 'config', 'advanced');
		}

		var m = new form.Map('pw2watchdog',
			_('PassWall2 Watchdog'),
			_('Main watchdog configuration.')
		);

		/* --- PassWall2 status banner --- */
		var info = m.section(form.NamedSection, '__status__', 'dummy');
		info.render = function() {
			var style, title, msg;
			if (pwState === 'ok') {
				style = 'padding:12px 14px;border:1px solid #b7e3c1;background:#f0fff4;color:#1f5132;border-radius:4px;margin-bottom:1em;';
				title = _('PassWall2 default proxy node is configured.');
				msg   = _('Current default node: ') + (getNodeLabel(passwallDefault) || passwallDefault);
			} else if (pwState === 'special') {
				style = 'padding:12px 14px;border:1px solid #ffe08a;background:#fffbea;color:#7a5d00;border-radius:4px;margin-bottom:1em;';
				title = _('PassWall2 default node uses a special mode (Direct or Blackhole).');
				msg   = _('Current default node: ') + (getNodeLabel(passwallDefault) || passwallDefault) + '. ' +
				        _('Choose a real proxy node in PassWall2 for proxy-based fallback.');
			} else if (pwState === 'special_default') {
				style = 'padding:12px 14px;border:1px solid #ffe08a;background:#fffbea;color:#7a5d00;border-radius:4px;margin-bottom:1em;';
				title = _('PassWall2 default node uses an internal alias.');
				msg   = _('Verify and set a real proxy node as default in PassWall2.');
			} else {
				style = 'padding:12px 14px;border:1px solid #f1b0b7;background:#fff5f5;color:#842029;border-radius:4px;margin-bottom:1em;';
				title = _('PassWall2 default proxy node is not set.');
				msg   = _('Configure a default proxy node in PassWall2 before using the watchdog.');
			}
			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': style }, [
					E('strong', title),
					E('div', { 'style': 'margin-top:4px;' }, msg)
				])
			]);
		};

		/* --- General settings --- */
		var s = m.section(form.NamedSection, 'main', 'config', _('General settings'));
		s.anonymous = true;
		s.addremove = false;

		var o;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Enable or disable the watchdog.');

		o = s.option(form.ListValue, 'node_selection', _('Node selection mode'));
		o.default  = 'auto';
		o.rmempty  = false;
		o.value('auto',   _('Auto: Best Available Node'));
		o.value('manual', _('Manual: Best Available Node'));
		o.description = _(
			'Auto: the watchdog selects the best N nodes automatically from the entire pool ' +
			'(excluding your Excluded list). Candidates are updated after each scan cycle. ' +
			'Manual: the watchdog picks the best node only from your manually pinned Candidates. ' +
			'Keep the number of candidates close to the recommended slot count for your device.'
		);

		o = s.option(form.ListValue, 'fallback_action', _('Fallback action'));
		o.default  = 'blackhole';
		o.rmempty  = false;
		o.value('blackhole',  _('Blackhole \u2014 block traffic (recommended)'));
		o.value('direct',     _('Direct \u2014 bypass proxy, use WAN'));
		o.value('rotate_all', _('Rotate all \u2014 cycle through all nodes'));
		o.description = _(
			'What to do when no healthy candidate node is available. ' +
			'Blackhole blocks all proxy traffic and prevents unproxied leaks. ' +
			'Direct falls back to the regular WAN connection. ' +
			'Rotate all cycles through all non-excluded nodes from the last scan.'
		);

		/* ── Killswitch warning ── */
		var ksWarn = s.option(form.DummyValue, '_ks_warning', '');
		ksWarn.depends('fallback_action', 'blackhole');
		ksWarn.renderWidget = function() {
			return E('div', {
				'style': 'padding:10px 14px;border:1px solid #f59e0b;background:#fffbea;' +
				         'color:#78350f;border-radius:4px;font-size:0.9em;line-height:1.5;'
			}, [
				E('strong', {}, '⚠ Blackhole ≠ killswitch. '),
				_('The nft drop rule is inserted at runtime and does not exist until pw2watchdog starts. '),
				_('On every reboot, traffic flows through the default WAN gateway unproxied for 10–30 s '),
				_('until PassWall2 and pw2watchdog finish starting. '),
				_('A true killswitch must be configured at the OpenWrt firewall level (fw4 / firewall.user), '),
				_('independently of this addon.')
			]);
		};

		o = s.option(form.Value, 'rotate_max_rounds', _('Rotate: max rounds'));
		o.datatype    = 'uinteger';
		o.placeholder = '3';
		o.rmempty     = true;
		o.depends('fallback_action', 'rotate_all');
		o.description = _('Number of full rotations through all nodes before applying the final action. Default: 3.');

		o = s.option(form.ListValue, 'rotate_final_action', _('Rotate: final action'));
		o.default  = 'blackhole';
		o.rmempty  = true;
		o.depends('fallback_action', 'rotate_all');
		o.value('blackhole', _('Blackhole \u2014 block traffic after rotation'));
		o.value('direct',    _('Direct \u2014 use WAN after rotation'));
		o.value('rotate_all', _('Continue rotating indefinitely'));
		o.description = _('Action to take after exhausting all rotation rounds.');

		o = s.option(form.Value, 'check_interval', _('Check interval'));
		o.datatype    = 'uinteger';
		o.placeholder = '180';
		o.rmempty     = false;
		o.description = _('Seconds between watchdog measurement cycles.');

		o = s.option(form.Value, 'timeout', _('Timeout'));
		o.datatype    = 'uinteger';
		o.placeholder = '4';
		o.rmempty     = false;
		o.description = _('Maximum seconds to wait for one test request.');

		o = s.option(form.Value, 'max_latency', _('Max latency'));
		o.datatype    = 'uinteger';
		o.placeholder = '1500';
		o.rmempty     = false;
		o.description = _('Latency threshold in ms. Nodes above this value are treated as dead.');

		o = s.option(form.Value, 'min_switch_interval', _('Min switch interval'));
		o.datatype    = 'uinteger';
		o.placeholder = '600';
		o.rmempty     = false;
		o.description = _('Minimum seconds between two successive node switches.');

		o = s.option(form.Value, 'latency_improvement_threshold', _('Latency improvement threshold'));
		o.datatype    = 'uinteger';
		o.placeholder = '80';
		o.rmempty     = false;
		o.description = _('Minimum latency improvement in ms required to trigger a switch.');

		o = s.option(form.Value, 'test_url', _('Test URL'));
		o.rmempty     = false;
		o.placeholder = 'https://cp.cloudflare.com/generate_204';
		o.description = _('URL used for latency measurement.');

		/* ------------------------------------------------------------------ *
		 *  Advanced Settings
		 *  All fields are optional — if blank, pw2watchdog-env.sh auto-detects values.
		 * ------------------------------------------------------------------ */
		var adv = m.section(form.NamedSection, 'advanced', 'config', _('Advanced settings'));
		adv.anonymous  = true;
		adv.addremove  = false;
		adv.description = _(
			'Override paths auto-detected by pw2watchdog-env.sh. ' +
			'Leave all fields blank to use auto-detected values. ' +
			'Only fill in fields where auto-detection fails on your setup.'
		);

		o = adv.option(form.Value, 'init_script', _('PassWall2 init script'));
		o.placeholder = '/etc/init.d/passwall2';
		o.rmempty     = true;
		o.description = _('Path to the PassWall2 init script. Leave blank for auto-detect.');

		o = adv.option(form.Value, 'test_script', _('PassWall2 test script'));
		o.placeholder = '/usr/share/passwall2/test.sh';
		o.rmempty     = true;
		o.description = _('Path to the PassWall2 URL test script. Leave blank for auto-detect.');

		o = adv.option(form.Value, 'nftable_name', _('NFT table name'));
		o.placeholder = 'inet passwall2';
		o.rmempty     = true;
		o.description = _('nftables table used by PassWall2. Leave blank for auto-detect.');

		o = adv.option(form.Value, 'nftchain_mangle', _('NFT chain (mangle)'));
		o.placeholder = 'PSW2_MANGLE';
		o.rmempty     = true;
		o.description = _('nftables mangle chain used by PassWall2 for tproxy. Leave blank for auto-detect.');

		o = adv.option(form.Value, 'tmp_path', _('PassWall2 tmp path'));
		o.placeholder = '/tmp/etc/passwall2';
		o.rmempty     = true;
		o.description = _('Temporary directory used by PassWall2 (contains var file with tproxy port). Leave blank for auto-detect.');

		/* Low-level overrides — edge cases */
		o = adv.option(form.Value, 'nftables_script', _('NFT script path'));
		o.placeholder = '';
		o.rmempty     = true;
		o.description = _('Path to PassWall2 nftables setup script. Leave blank for auto-detect.');

		o = adv.option(form.Value, 'utils_script', _('Utils script path'));
		o.placeholder = '';
		o.rmempty     = true;
		o.description = _('Path to PassWall2 utils script (used for tmp path detection). Leave blank for auto-detect.');

		o = adv.option(form.Value, 'fwmark', _('Firewall mark (hex)'));
		o.placeholder = '0x50535732';
		o.rmempty     = true;
		o.description = _('fwmark value used by PassWall2 for tproxy routing. Leave blank for auto-detect.');

		/* --- Subscription auto-update --- */
		o = adv.option(form.Flag, 'sub_auto_update', _('Subscription auto-update'));
		o.default     = '0';
		o.rmempty     = false;
		o.description = _(
			'Automatically update PassWall2 subscriptions once a day via cron. ' +
			'Some PassWall2 builds do not update subscriptions automatically \u2014 ' +
			'enable this option to keep your node list up to date. ' +
			'Changes take effect after Save & Apply.'
		);

		o = adv.option(form.Value, 'sub_update_time', _('Subscription update time'));
		o.placeholder = '04:00';
		o.rmempty     = true;
		o.description = _('Daily update time in HH:MM format (24h, router local time). Example: 04:00');
		o.depends('sub_auto_update', '1');

		o = adv.option(form.Flag, 'sub_update_on_boot', _('Update subscriptions on boot'));
		o.default     = '0';
		o.rmempty     = false;
		o.description = _('Run a subscription update once after each router reboot, in addition to the daily schedule.');
		o.depends('sub_auto_update', '1');

		o = adv.option(form.Value, 'sub_boot_delay', _('Boot update delay (seconds)'));
		o.datatype    = 'uinteger';
		o.placeholder = '120';
		o.rmempty     = true;
		o.depends('sub_update_on_boot', '1');
		o.description = _('Delay in seconds before running subscription update on boot. Minimum: 120 s — allows the scanner to complete its first cycle and populate the node cache before nodes are replaced by a subscription update. Values below 120 are ignored and 120 is used instead.');

		/* --- PassWall2 health check --- */
		o = adv.option(form.Flag, 'pw2_restart_on_failure', _('Auto-restart PassWall2 on failure'));
		o.default     = '0';
		o.rmempty     = false;
		o.description = _(
			'If PassWall2 is found not running at the start of a watchdog cycle, restart it automatically. ' +
			'Prevents false “all candidates dead” failures caused by a crashed PassWall2 process. ' +
			'The restart timestamp is recorded below.'
		);

		/* Read-only: last PW2 restart timestamp from status.json.
		 * DummyValue + load() is the standard LuCI pattern for read-only
		 * fields: cfgvalue returns the display string, no poll() needed.
		 */
		var pw2RestartRow = adv.option(form.DummyValue, '_pw2_restart_ts', _('Last watchdog-triggered PW2 restart'));
		pw2RestartRow.depends('pw2_restart_on_failure', '1');
		pw2RestartRow.load = function(section_id) {
			/* Read status.json from the filesystem (same way the status banner does). */
			return fs.read('/var/run/pw2watchdog/status.json')
				.then(function(raw) {
					try {
						var st = JSON.parse(raw || '{}');
						var ts = parseInt(st.last_pw2_restart || '0', 10);
						return ts > 0
							? new Date(ts * 1000).toLocaleString()
							: _('never');
					} catch(e) {
						return '—';
					}
				})
				.catch(function() { return '—'; });
		};
		pw2RestartRow.cfgvalue = function(section_id, value) {
			/* value is what load() resolved to */
			return value || '—';
		};

		/* --- Actions --- */
		var actions = m.section(form.NamedSection, '__actions__', 'dummy');
		var self = this;
		actions.render = function() {
			return E('div', { 'class': 'cbi-section', 'style': 'margin-top:1em;' }, [
				E('h3', _('Actions')),
				E('p', { 'style': 'margin:0 0 0.75em 0;color:#666;' },
					_('Open PassWall2 to review proxy nodes, or restore recommended watchdog defaults.')
				),
				E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;' }, [
					E('a', {
						'class': 'btn cbi-button cbi-button-action',
						'href':  L.url('admin/services/passwall2')
					}, _('Open PassWall2')),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function(ev) {
							ev.preventDefault();
							return restoreDefaults(m);
						}
					}, _('Restore defaults')),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'id': 'pw2-restore-advanced-btn',
						'style': 'display:none;',
						'click': function(ev) {
							ev.preventDefault();
							return resetAdvanced(m);
						}
					}, _('Restore advanced to auto-detect'))
				])
			]);
		};

		return m.render().then(function(mapEl) {
			/* --- Collapse the Advanced settings section --- */
			(function() {
				var sections = mapEl.querySelectorAll('.cbi-section');
				for (var i = 0; i < sections.length; i++) {
					var h3 = sections[i].querySelector('h3');
					if (!h3 || h3.textContent.trim() !== 'Advanced settings') continue;
					var sec = sections[i];
					/* Hide everything except the heading */
					Array.prototype.forEach.call(sec.children, function(child) {
						if (child !== h3) child.style.display = 'none';
					});
					/* Style the heading as clickable */
					h3.style.cursor  = 'pointer';
					h3.style.userSelect = 'none';
					h3.title = _('Click to expand / collapse');
					var arrow = document.createElement('span');
					arrow.textContent = ' ▶';
					arrow.style.fontSize = '0.8em';
					h3.appendChild(arrow);
					var expanded = false;
					h3.addEventListener('click', function() {
						expanded = !expanded;
						Array.prototype.forEach.call(sec.children, function(child) {
							if (child !== h3) child.style.display = expanded ? '' : 'none';
						});
						arrow.textContent = expanded ? ' ▼' : ' ▶';
						var restoreBtn = document.getElementById('pw2-restore-advanced-btn');
						if (restoreBtn) restoreBtn.style.display = expanded ? '' : 'none';
					});
					break;
				}
			})();

			var banner = renderRunningBanner();
			var descr  = mapEl.querySelector('.cbi-map-descr');
			if (descr && descr.parentNode)
				descr.parentNode.insertBefore(banner, descr.nextSibling);
			else
				mapEl.insertBefore(banner, mapEl.firstChild);
			startRunningPoller(banner);

			var nodeSelMode = uci.get('pw2watchdog', 'main', 'node_selection') || 'auto';
			var excess = nodeSelMode === 'manual' ? renderExcessBanner(candidateCount, recommendedCandidates) : null;
			if (excess) {
				if (banner.parentNode)
					banner.parentNode.insertBefore(excess, banner.nextSibling);
				else
					mapEl.insertBefore(excess, mapEl.firstChild);
			}
			return mapEl;
		});
	}
});
