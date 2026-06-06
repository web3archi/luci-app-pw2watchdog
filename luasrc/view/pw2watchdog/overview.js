'use strict';
'require view';
'require uci';
'require fs';

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

	var barWrap = E('div', { 'class': 'pw2-indeterminate' }, [
		E('div', { 'class': 'pw2-indeterminate-bar' })
	]);

	return E('div', {
		'id': 'pw2-running-banner',
		'style': 'display:none;padding:12px 14px;border:1px solid #f59e0b;' +
		         'background:#fffbea;color:#78350f;border-radius:4px;margin-bottom:1em;'
	}, [
		E('strong', _('\u26a0 Node measurement in progress \u2014 do not change settings')),
		E('div', { 'style': 'margin-top:4px;font-size:0.9em;' },
			_('The watchdog is currently measuring latency for all candidate nodes one by one. ' +
			  'Saving settings during this time may cause incorrect results or a missed switch cycle.')
		),
		barWrap
	]);
}

function startRunningPoller(bannerEl) {
	function poll() {
		fs.read('/var/run/pw2watchdog/status.json').then(function(raw) {
			var st = {};
			try { st = JSON.parse(raw || '{}'); } catch(e) {}
			bannerEl.style.display =
				(st.running === 'true' || st.running === true) ? '' : 'none';
		}, function() {
			/* file unreadable — hide banner */
			bannerEl.style.display = 'none';
		}).then(function() {
			/* Poller runs continuously */
			setTimeout(poll, 3000);
		});
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
		'class': 'pw2-excess-banner',
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
 *  Device performance block (three boxes)
 * ------------------------------------------------------------------ */

function renderHwBadges(status) {
	var recommended = parseInt(status.recommended_candidates || 0);
	var cpuModel    = status.cpu_model    || '';
	var cpuThreads  = parseInt(status.cpu_threads  || 0);

	if (!recommended) return null;

	var level;
	if (recommended >= 6)      level = 'strong';
	else if (recommended >= 4) level = 'medium';
	else                       level = 'weak';

	var cpuLine = (cpuModel && cpuModel !== 'unknown')
		? cpuModel + (cpuThreads > 0 ? ' \u00d7 ' + cpuThreads + ' thr.' : '')
		: (cpuThreads > 0 ? cpuThreads + ' threads' : 'unknown CPU');

	function makeBox(color, bg, border, label, active) {
		return E('div', {
			'style': 'flex:1;padding:8px 10px;border:2px solid ' + border + ';' +
			         'border-radius:5px;background:' + (active ? bg : '#f8f9fa') + ';' +
			         'color:' + (active ? color : '#aaa') + ';text-align:center;'
		}, [
			E('div', { 'style': 'font-weight:700;font-size:0.9em;' }, label),
			active ? E('div', { 'style': 'font-size:0.75em;margin-top:3px;word-break:break-word;' }, cpuLine) : ''
		]);
	}

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Device performance')),
		E('div', { 'style': 'display:flex;gap:8px;margin-bottom:6px;' }, [
			makeBox('#842029','#f8d7da','#f1b0b7', _('Weak'),     level === 'weak'),
			makeBox('#856404','#fff3cd','#ffe08a', _('Medium'),   level === 'medium'),
			makeBox('#1a7f3c','#d4edda','#b7e3c1', _('Powerful'), level === 'strong')
		]),
	]);
}

/* ------------------------------------------------------------------ *
 *  Node helpers (for the overview table)
 * ------------------------------------------------------------------ */

function isRealNodeSection(s) {
	if (!s || !s['.name'])
		return false;
	var stype = String(s['.type'] || '').toLowerCase();
	var name  = String(s['.name'] || '').toLowerCase();
	var proto = String(s.protocol || '').toLowerCase();
	var label = String(s.remarks || s.remark || '').toLowerCase();
	if (stype !== 'nodes')   return false;
	if (name === 'examplenode') return false;
	if (name === 'rulenode')    return false;
	if (proto === '_shunt')     return false;
	if (label === 'example')    return false;
	return true;
}

function detectProtocol(s, label) {
	var candidates = [ s.protocol, s.type, s.node_type, s.proto ];
	for (var i = 0; i < candidates.length; i++)
		if (candidates[i]) return String(candidates[i]).toUpperCase();
	var text = String(label || '').toUpperCase();
	if (text.indexOf('SHADOWSOCKS2022') >= 0 || text.indexOf('SS2022') >= 0) return 'SHADOWSOCKS2022';
	if (text.indexOf('SHADOWSOCKS') >= 0) return 'SHADOWSOCKS';
	if (text.indexOf('VLESS')      >= 0) return 'VLESS';
	if (text.indexOf('VMESS')      >= 0) return 'VMESS';
	if (text.indexOf('TROJAN')     >= 0) return 'TROJAN';
	if (text.indexOf('HYSTERIA2')  >= 0) return 'HYSTERIA2';
	if (text.indexOf('HYSTERIA')   >= 0) return 'HYSTERIA';
	if (text.indexOf('TUIC')       >= 0) return 'TUIC';
	if (text.indexOf('WIREGUARD')  >= 0) return 'WIREGUARD';
	if (text.indexOf('AMNEZIA')    >= 0) return 'AMNEZIAWG';
	return '-';
}

function detectTransport(s, label) {
	var candidates = [ s.transport, s.network, s.net, s.transfer_protocol ];
	for (var i = 0; i < candidates.length; i++) {
		if (candidates[i]) {
			var val = String(candidates[i]).toLowerCase();
			if (val === 'grpc')        return 'gRPC';
			if (val === 'ws')          return 'WS';
			if (val === 'tcp')         return 'TCP';
			if (val === 'quic')        return 'QUIC';
			if (val === 'kcp')         return 'mKCP';
			if (val === 'httpupgrade') return 'HTTPUpgrade';
			if (val === 'xhttp')       return 'XHTTP';
			if (val === 'raw')         return 'RAW';
			if (val === 'ssh')         return 'SSH';
			return String(candidates[i]).toUpperCase();
		}
	}
	var text = String(label || '').toUpperCase();
	if (text.indexOf('GRPC')        >= 0) return 'gRPC';
	if (text.indexOf('WS')          >= 0) return 'WS';
	if (text.indexOf('HTTPUPGRADE') >= 0) return 'HTTPUpgrade';
	if (text.indexOf('XHTTP')       >= 0) return 'XHTTP';
	if (text.indexOf('KCP')         >= 0) return 'mKCP';
	if (text.indexOf('QUIC')        >= 0) return 'QUIC';
	if (text.indexOf('TCP')         >= 0) return 'TCP';
	if (text.indexOf('SSH')         >= 0) return 'SSH';
	return '-';
}

function detectSecurity(s, label) {
	var text = String(label || '').toUpperCase();
	if (s.reality || s.pbk || s.sid || text.indexOf('REALITY') >= 0) return 'REALITY';
	if (s.tls === '1' || s.tls === 1 || s.xtls === '1' || text.indexOf('TLS') >= 0) return 'TLS';
	if (text.indexOf('VISION') >= 0) return 'VISION';
	return '-';
}

function buildNodeIndex() {
	var idx = {};
	uci.sections('passwall2').forEach(function(s) {
		if (!isRealNodeSection(s)) return;
		var label = s.remarks || s.remark || s.alias || s.address || s.server || s['.name'];
		idx[s['.name']] = {
			id: s['.name'], label: label,
			protocol: detectProtocol(s, label),
			transport: detectTransport(s, label),
			security:  detectSecurity(s, label)
		};
	});
	return idx;
}

function getNodeMeta(nodeIndex, nodeId) {
	if (!nodeId || nodeId === '-')
		return { id: '', label: '-', protocol: '-', transport: '-', security: '-' };
	if (nodeId === '_direct')
		return { id: '_direct',    label: 'Direct',           protocol: '-', transport: '-', security: '-' };
	if (nodeId === '_blackhole')
		return { id: '_blackhole', label: 'Blackhole',        protocol: '-', transport: '-', security: '-' };
	if (nodeId === '_default')
		return { id: '_default',   label: 'Internal default', protocol: '-', transport: '-', security: '-' };
	return nodeIndex[nodeId] || { id: nodeId, label: nodeId, protocol: '-', transport: '-', security: '-' };
}

function fmtLatency(v) {
	var n = Number(v);
	if (!n || n <= 0 || n >= 999999) return '-';
	return String(n) + ' ms';
}

function fmtTs(ts) {
	var n = Number(ts);
	return (!n || n <= 0) ? '-' : new Date(n * 1000).toLocaleString();
}

function parseHistory(raw) {
	var out = [];
	String(raw || '').split('\n').forEach(function(line) {
		line = line.trim();
		if (!line) return;
		try { out.push(JSON.parse(line)); } catch(e) {}
	});
	out.reverse();
	return out;
}

function describeAction(action) {
	switch (action) {
	case 'switch':              return _('Switched');
	case 'stay':                return _('Stayed');
	case 'fallback_direct':     return _('Fallback to Direct');
	case 'fallback_blackhole':  return _('Fallback to Blackhole');
	case 'rotate_all':          return _('Rotate All Nodes');
	default:                    return action || '-';
	}
}

/* ------------------------------------------------------------------ *
 *  Formatting UCI values for display
 * ------------------------------------------------------------------ */

function formatNodeSelectionMode(mode) {
	switch (String(mode || '')) {
	case 'auto':   return _('Auto: Best Available Node');
	case 'manual': return _('Manual: Best Available Node');
	default:       return mode || '-';
	}
}

function formatFallbackAction(action) {
	switch (String(action || '')) {
	case 'blackhole': return _('Blackhole \u2014 block traffic (recommended)');
	case 'direct':    return _('Direct \u2014 bypass proxy, use WAN');
	default:          return action || '-';
	}
}

function formatReason(reason) {
	switch (reason) {
	case 'best_latency':                   return _('Switched to the best candidate by latency');
	case 'all_failed':                     return _('All candidate nodes failed');
	case 'all_failed_rotate_hold':         return _('All candidate nodes failed; keeping current node and retrying later');
	case 'all_failed_sticky_hold':         return _('All candidate nodes failed; keeping the current default node');
	case 'all_failed_unknown_mode_hold':   return _('All candidate nodes failed; keeping current node due to unknown fallback mode');
	case 'fallback_direct_all_failed':     return _('All candidate nodes failed; switched to direct connection');
	case 'fallback_blackhole_all_failed':  return _('All candidate nodes failed; blocked traffic');
	case 'rotate_all':                     return _('All candidates failed; rotating through all available nodes');
	case 'suppressed_min_switch_interval': return _('Switch suppressed by minimum switch interval');
	case 'suppressed_small_improvement':   return _('Switch suppressed because latency improvement was too small');
	case 'switch_failed':                  return _('Switch attempt failed');
	case 'no_candidates':                  return _('No candidate nodes configured');
	case 'disabled':                       return _('Watchdog is disabled');
	case 'empty_passwall_section':         return _('PassWall section name is empty');
	case 'empty_current_default':          return _('Current PassWall2 default node is empty');
	case 'running':                        return _('Measurement cycle in progress');
	default:                               return reason || '-';
	}
}

function makeNodeValue(meta, latency) {
	return E('div', { 'style': 'display:flex;justify-content:space-between;gap:12px;align-items:flex-start;' }, [
		E('div', { 'style': 'display:flex;flex-direction:column;gap:2px;min-width:0;' }, [
			E('div', {}, meta.label || '-'),
			E('div', { 'style': 'font-size:12px;color:#666;' }, [
				_('Protocol: %s').format(meta.protocol || '-'), '  \xb7  ',
				_('Transport: %s').format(meta.transport || '-'), '  \xb7  ',
				_('Security: %s').format(meta.security || '-')
			])
		]),
		E('div', { 'style': 'white-space:nowrap;font-weight:600;color:inherit;' }, fmtLatency(latency))
	]);
}

function makeSimpleValue(text) {
	return E('span', {}, text != null && text !== '' ? String(text) : '-');
}

function makeRow(label, valueNode, note) {
	return E('tr', {}, [
		E('td', { 'style': 'font-weight:600;width:22%;padding:8px;vertical-align:top;' }, label),
		E('td', { 'style': 'width:40%;padding:8px;vertical-align:top;' }, [ valueNode ]),
		E('td', { 'style': 'color:#666;padding:8px;vertical-align:top;' }, note)
	]);
}

function renderActions() {
	return E('div', { 'class': 'cbi-section', 'style': 'margin-top:1em;' }, [
		E('h3', _('Actions')),
		E('p', { 'style': 'margin:0 0 0.75em 0;color:#666;' },
			_('Use PassWall2 to review or change the currently selected default proxy node.')
		),
		E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;' }, [
			E('a', {
				'class': 'btn cbi-button cbi-button-action',
				'href': L.url('admin/services/passwall2')
			}, _('Open PassWall2'))
		])
	]);
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			uci.load('pw2watchdog'),
			uci.load('passwall2'),
			fs.read_direct('/var/run/pw2watchdog/status.json', 'json').catch(function() { return {}; }),
			fs.read_direct('/var/run/pw2watchdog/history.jsonl', 'text').catch(function() { return ''; })
		]);
	},

	render: function(data) {
		var nodeIndex         = buildNodeIndex();
		var checkInterval     = uci.get('pw2watchdog', 'main', 'check_interval')  || '-';
		var nodeSelectionCfg  = uci.get('pw2watchdog', 'main', 'node_selection')  || 'auto';
		var fallbackActionCfg = uci.get('pw2watchdog', 'main', 'fallback_action') || 'blackhole';
		var excludeNodes      = uci.get('pw2watchdog', 'main', 'exclude_node')    || [];
		var candidateNodes    = uci.get('pw2watchdog', 'main', 'candidate_node')  || [];

		var status = {};
		try { status = data[2] || {}; } catch(e) {}

		var recommendedCandidates = parseInt(status.recommended_candidates || 0);
		var candidateCount        = parseInt(status.candidate_count        || 0);

		var historyItems = parseHistory(data[3] || '');

		var runtimeTable     = E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, []);
		var historyContainer = E('div', { 'id': 'pw2-history-container' }, []);

		function renderRuntime(obj) {
			/* Current PassWall2 node */
			var currentNodeId = uci.get('passwall2', 'rulenode', 'default_node') || obj.current_node || '-';
			var bestNodeId    = obj.best_node || '-';
			var currentMeta   = getNodeMeta(nodeIndex, currentNodeId);
			var bestMeta      = getNodeMeta(nodeIndex, bestNodeId);

			/* Node selection mode — from UCI (config) and status.json (live) */
			var nodeSelectionLive  = obj.node_selection  || nodeSelectionCfg;
			var fallbackActionLive = obj.fallback_action || fallbackActionCfg;

			/* Fallback target — either _direct or _blackhole */
			var fallbackTargetId   = (fallbackActionLive === 'direct') ? '_direct' : '_blackhole';
			var fallbackTargetMeta = getNodeMeta(nodeIndex, fallbackTargetId);

			/* Candidates and excluded from UCI (current after auto-rotation) */
			var liveCandidates = uci.get('pw2watchdog', 'main', 'candidate_node') || [];
			var liveExcluded   = uci.get('pw2watchdog', 'main', 'exclude_node')   || [];
			if (!Array.isArray(liveCandidates)) liveCandidates = [liveCandidates];
			if (!Array.isArray(liveExcluded))   liveExcluded   = [liveExcluded];
			liveCandidates = liveCandidates.filter(function(x) { return x && x !== ''; });
			liveExcluded   = liveExcluded.filter(function(x)   { return x && x !== ''; });

			runtimeTable.innerHTML = '';

			/* Node selection mode */
			runtimeTable.appendChild(makeRow(
				_('Node selection mode'),
				makeSimpleValue(formatNodeSelectionMode(nodeSelectionLive)),
				_('auto: watchdog rotates candidates automatically; manual: you pick candidates on the Nodes page.')
			));

			/* Recommended max candidates */
			var recMax = parseInt(obj.recommended_candidates || 0);
			if (recMax > 0) {
				runtimeTable.appendChild(makeRow(
					_('Recommended max candidates'),
					makeSimpleValue(String(recMax)),
					_('Based on check_interval and measured per-node overhead on this device.')
				));
			}

			/* Active candidates — show dash until watchdog has run at least once */
			var candidateCountRaw = obj.candidate_count !== undefined ? obj.candidate_count : null;
			var candidateCountLive = (candidateCountRaw !== null && candidateCountRaw !== '')
				? String(candidateCountRaw)
				: (liveCandidates.length > 0 ? String(liveCandidates.length) : '\u2014');
			runtimeTable.appendChild(makeRow(
				_('Active candidates'),
				makeSimpleValue(candidateCountLive),
				_('Number of nodes currently in the candidate pool for automatic selection.')
			));

			/* Excluded nodes */
			runtimeTable.appendChild(makeRow(
				_('Excluded nodes'),
				makeSimpleValue(liveExcluded.length > 0 ? String(liveExcluded.length) : _('none')),
				_('Nodes permanently excluded from both candidate rotation and latency scanning.')
			));

			/* Fallback action */
			runtimeTable.appendChild(makeRow(
				_('Fallback action'),
				makeSimpleValue(formatFallbackAction(fallbackActionLive)),
				_('What happens when all candidate nodes are unavailable.')
			));

			/* Fallback target */
			runtimeTable.appendChild(makeRow(
				_('Fallback target'),
				makeSimpleValue(fallbackTargetMeta.label),
				_('Special target used when fallback action is triggered.')
			));

			/* Current default node */
			runtimeTable.appendChild(makeRow(
				_('Current default node'),
				makeNodeValue(currentMeta, obj.current_latency),
				_('Currently active PassWall2 default node with its measured latency.')
			));

			/* Best candidate node */
			runtimeTable.appendChild(makeRow(
				_('Best candidate node'),
				makeNodeValue(bestMeta, obj.best_latency),
				_('Best candidate from the last watchdog cycle, with its measured latency.')
			));

			/* Last decision reason */
			runtimeTable.appendChild(makeRow(
				_('Last decision reason'),
				makeSimpleValue(formatReason(obj.last_reason || '-')),
				_('Reason recorded for the latest watchdog decision.')
			));

			/* Last node switch */
			runtimeTable.appendChild(makeRow(
				_('Last node switch'),
				makeSimpleValue(fmtTs(obj.last_switch)),
				_('Time of the last successful node switch.')
			));

			/* Check interval */
			runtimeTable.appendChild(makeRow(
				_('Check interval'),
				makeSimpleValue(checkInterval !== '-' ? String(checkInterval) + ' s' : '-'),
				_('Delay between automatic node health and latency checks.')
			));

			/* Last refresh */
			runtimeTable.appendChild(makeRow(
				_('Last refresh'),
				makeSimpleValue(new Date().toLocaleString()),
				_('Time when this page last refreshed runtime information.')
			));
		}

		function renderHistory(items) {
			historyContainer.innerHTML = '';
			if (!items.length) {
				historyContainer.appendChild(E('p', { 'style': 'margin:0;color:#666;' },
					_('No history events recorded yet.')));
				return;
			}
			var table = E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'style': 'text-align:right;padding:8px;width:1%;white-space:nowrap;' }, '#'),
					E('th', { 'style': 'text-align:left;padding:8px;' }, _('Time')),
					E('th', { 'style': 'text-align:left;padding:8px;' }, _('Action')),
					E('th', { 'style': 'text-align:left;padding:8px;' }, _('Node')),
					E('th', { 'style': 'text-align:left;padding:8px;' }, _('Reason'))
				])
			]);
			items.slice(0, 20).forEach(function(item, idx) {
				var meta = getNodeMeta(nodeIndex, item.node || '-');
				/* If node is no longer in UCI (e.g. after subscription update),
				 * fall back to the label saved in history.jsonl at the time of event */
				if (item.label && (meta.label === meta.id || meta.label === (item.node || '-'))) {
					meta = Object.assign({}, meta, { label: item.label });
				}
				table.appendChild(E('tr', { 'class': 'tr cbi-section-table-row' }, [
					E('td', { 'style': 'padding:8px;text-align:right;color:#666;width:1%;white-space:nowrap;' }, String(idx + 1)),
					E('td', { 'style': 'padding:8px;white-space:nowrap;' }, fmtTs(item.ts)),
					E('td', { 'style': 'padding:8px;' }, describeAction(item.action)),
					E('td', { 'style': 'padding:8px;' }, [
						E('div', {}, meta.label || '-'),
						E('div', { 'style': 'font-size:12px;color:#666;' }, [
							_('Protocol: %s').format(meta.protocol || '-'), '  \xb7  ',
							_('Transport: %s').format(meta.transport || '-'), '  \xb7  ',
							_('Security: %s').format(meta.security || '-')
						])
					]),
					E('td', { 'style': 'padding:8px;' }, item.reason || '-')
				]));
			});
			historyContainer.appendChild(table);
		}

		function refreshAll() {
			return Promise.all([
				fs.read('/var/run/pw2watchdog/status.json').catch(function() { return '{}'; }),
				fs.read('/var/run/pw2watchdog/history.jsonl').catch(function() { return ''; }),
				uci.load('passwall2'),
				fs.read('/var/run/pw2watchdog/sub_update.json').catch(function() { return '{}'; })
			]).then(function(res) {
				var obj = {};
				try { obj = JSON.parse(res[0] || '{}'); } catch(e) {}
				var subObj = {};
				try { subObj = JSON.parse(res[3] || '{}'); } catch(e) {}
				renderRuntime(obj);
				renderHistory(parseHistory(res[1] || ''));
				if (subAutoUpdate === '1') renderSubState(subObj);
				/* Update excess banner — only relevant in manual mode */
				if (nodeSelectionMode === 'manual') {
					excessBannerContainer.innerHTML = '';
					var freshExcess = renderExcessBanner(
						parseInt(obj.candidate_count || 0),
						parseInt(obj.recommended_candidates || 0)
					);
					if (freshExcess) excessBannerContainer.appendChild(freshExcess);
				}
			}).catch(function() {
				renderRuntime({});
				renderHistory([]);
			});
		}

		/* "Measurement in progress" banner */
		var runningBanner = renderRunningBanner();
		startRunningPoller(runningBanner);

		/* Excess candidates banner — shown only in manual node selection mode */
		var excessBannerContainer = E('div', { 'id': 'pw2-excess-container' });
		var nodeSelectionMode = uci.get('pw2watchdog', 'main', 'node_selection') || 'auto';
		if (nodeSelectionMode === 'manual') {
			var excessBanner = renderExcessBanner(candidateCount, recommendedCandidates);
			if (excessBanner) excessBannerContainer.appendChild(excessBanner);
		}

		/* Device performance block */
		var hwBadges = renderHwBadges(status);

		/* Subscription status block — shown only when sub_auto_update=1 */
		var subAutoUpdate = uci.get('pw2watchdog', 'advanced', 'sub_auto_update') || '0';
		var subValueCell  = E('td', { 'style': 'width:40%;padding:8px;vertical-align:top;' }, '-');
		var subBlock = null;
		if (subAutoUpdate === '1') {
			subBlock = E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Proxy subscriptions')),
				E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, [
					E('tr', {}, [
						E('td', { 'style': 'font-weight:600;width:22%;padding:8px;vertical-align:top;' },
							_('Last subscription update')),
						subValueCell,
						E('td', { 'style': 'color:#666;padding:8px;vertical-align:top;' },
							_('Auto-update is enabled. Updated daily by pw2watchdog-subscribe.sh.'))
					])
				])
			]);
		}

		function renderSubState(obj) {
			var subTs  = Number(obj.ts  || 0);
			var subCnt = Number(obj.subs_updated || 0);
			var subRes = String(obj.result || '');
			subValueCell.textContent = subTs > 0
				? (new Date(subTs * 1000).toLocaleString() + ' — ' +
				   subCnt + _(' subscription(s) updated') +
				   (subRes === 'error' ? ' (⚠ some failed)' : ''))
				: _('Not yet updated since boot');
		}

		var root = E('div', {}, [
			runningBanner,
			excessBannerContainer,
			E('div', { 'class': 'cbi-map' }, [
				E('h2', _('PassWall2 Watchdog')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Runtime status and recent watchdog events. This page refreshes automatically.')
				),
				hwBadges || '',
				subBlock || '',
				E('div', { 'class': 'cbi-section' }, [
					E('h3', _('Runtime status')),
					runtimeTable
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('details', { 'open': 'open' }, [
						E('summary', { 'style': 'cursor:pointer;font-weight:600;margin-bottom:12px;' },
							_('Recent events')),
						E('p', { 'style': 'margin:8px 0 12px 0;color:#666;' },
							_('History of watchdog decisions recorded since device start.')),
						historyContainer
					])
				])
			]),
			renderActions()
		]);

		renderRuntime(status);
		renderHistory(historyItems);
		if (subAutoUpdate === '1') refreshAll();
		window.setInterval(refreshAll, 5000);

		return root;
	}
});
