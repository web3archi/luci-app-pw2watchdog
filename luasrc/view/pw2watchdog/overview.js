'use strict';
'require view';
'require uci';
'require fs';

/* ------------------------------------------------------------------ *
 *  "Measurement in progress" banner
 * ------------------------------------------------------------------ */
function renderRunningBanner() {
	var styleId = 'pw2-indeterminate-style';
	if (!document.getElementById(styleId)) {
		var style = document.createElement('style');
		style.id  = styleId;
		style.textContent =
			'@keyframes pw2-slide{0%{transform:translateX(-100%)}100%{transform:translateX(400%)}}' +
			'.pw2-indeterminate{position:relative;height:6px;background:#fde68a;border-radius:3px;overflow:hidden;margin-top:8px;}' +
			'.pw2-indeterminate-bar{position:absolute;top:0;left:0;width:25%;height:100%;background:#f59e0b;border-radius:3px;animation:pw2-slide 1.4s linear infinite;}';
		document.head.appendChild(style);
	}
	return E('div', {
		'id': 'pw2-running-banner',
		'style': 'display:none;padding:12px 14px;border:1px solid #f59e0b;background:#fffbea;color:#78350f;border-radius:4px;margin-bottom:1em;'
	}, [
		E('strong', _('\u26a0 Node measurement in progress \u2014 do not change settings')),
		E('div', { 'style': 'margin-top:4px;font-size:0.9em;' },
			_('The watchdog is currently measuring latency for all candidate nodes one by one. ' +
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
			bannerEl.style.display = (st.running === 'true' || st.running === true) ? '' : 'none';
		}, function() {
			bannerEl.style.display = 'none';
		}).then(function() { setTimeout(poll, 3000); });
	}
	poll();
}

/* ------------------------------------------------------------------ *
 *  Excess candidates banner (manual mode only)
 * ------------------------------------------------------------------ */
function renderExcessBanner(currentCount, recommendedCount) {
	if (!recommendedCount || !currentCount || currentCount <= recommendedCount) return null;
	return E('div', {
		'style': 'padding:12px 14px;border:1px solid #f1b0b7;background:#fff5f5;color:#842029;border-radius:4px;margin-bottom:1em;'
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
 *  Device performance block
 * ------------------------------------------------------------------ */
function renderHwBlock(status) {
	var recommended = parseInt(status.recommended_candidates || 0);
	var cpuModel    = status.cpu_model   || '';
	var cpuThreads  = parseInt(status.cpu_threads || 0);
	if (!recommended) return null;

	var level;
	if (recommended >= 6)      level = 'strong';
	else if (recommended >= 4) level = 'medium';
	else                       level = 'weak';

	var levelColor  = level === 'strong' ? '#1a7f3c' : (level === 'medium' ? '#856404' : '#842029');
	var levelBg     = level === 'strong' ? '#d4edda' : (level === 'medium' ? '#fff3cd' : '#f8d7da');
	var levelBorder = level === 'strong' ? '#b7e3c1' : (level === 'medium' ? '#ffe08a' : '#f1b0b7');

	var cpuLine = (cpuModel && cpuModel !== 'unknown')
		? cpuModel + (cpuThreads > 0 ? ' \u00d7 ' + cpuThreads + ' thr.' : '')
		: (cpuThreads > 0 ? cpuThreads + ' threads' : 'unknown CPU');

	function makeBox(color, bg, border, label, active) {
		/* Inactive boxes: very light tint of their own color so Medium=yellowish, Strong=greenish */
		var inactiveBg = active ? bg :
			(border === '#ffe08a' ? '#fffef5' :
			 (border === '#b7e3c1' ? '#f5fbf7' : '#fdf5f5'));
		return E('div', {
			'style': 'flex:1;padding:2px 8px;border:2px solid ' + border + ';' +
			         'border-radius:5px;background:' + (active ? bg : inactiveBg) + ';' +
			         'color:' + (active ? color : '#bbb') + ';text-align:center;'
		}, [
			E('div', { 'style': 'font-weight:700;font-size:0.9em;' }, label),
			active ? E('div', { 'style': 'font-size:0.75em;margin-top:2px;word-break:break-word;' }, cpuLine) : ''
		]);
	}

	/* Recommended candidates mini-badge — same color as active box */
	var recBadge = E('div', {
		'style': 'display:inline-flex;align-items:center;gap:8px;margin-top:8px;'
	}, [
		E('span', {
			'style': 'display:inline-block;min-width:28px;padding:2px 8px;border-radius:4px;' +
			         'background:' + levelBg + ';border:1.5px solid ' + levelBorder + ';' +
			         'color:' + levelColor + ';font-weight:700;font-size:1em;text-align:center;'
		}, String(recommended)),
		E('span', { 'style': 'font-weight:600;font-size:1em;' },
			_('Recommended max candidates — based on check_interval and measured per-node overhead on this device.')
		)
	]);

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Device performance')),
		E('div', { 'style': 'display:flex;gap:8px;margin-bottom:8px;' }, [
			makeBox('#842029','#f8d7da','#f1b0b7', _('Weak'),     level === 'weak'),
			makeBox('#856404','#fff3cd','#ffe08a', _('Medium'),   level === 'medium'),
			makeBox('#1a7f3c','#d4edda','#b7e3c1', _('Powerful'), level === 'strong')
		]),
		recBadge
	]);
}

/* ------------------------------------------------------------------ *
 *  Node helpers
 * ------------------------------------------------------------------ */
function isRealNodeSection(s) {
	if (!s || !s['.name']) return false;
	if (String(s['.type']  || '').toLowerCase() !== 'nodes') return false;
	if (String(s['.name']  || '').toLowerCase() === 'examplenode') return false;
	if (String(s['.name']  || '').toLowerCase() === 'rulenode')    return false;
	if (String(s.protocol  || '').toLowerCase() === '_shunt')      return false;
	if (String(s.remarks   || s.remark || '').toLowerCase() === 'example') return false;
	return true;
}

function detectProtocol(s, label) {
	var c = [s.protocol, s.type, s.node_type, s.proto];
	for (var i = 0; i < c.length; i++) if (c[i]) return String(c[i]).toUpperCase();
	var t = String(label || '').toUpperCase();
	if (t.indexOf('SHADOWSOCKS2022') >= 0 || t.indexOf('SS2022') >= 0) return 'SHADOWSOCKS2022';
	if (t.indexOf('SHADOWSOCKS') >= 0) return 'SHADOWSOCKS';
	if (t.indexOf('VLESS')       >= 0) return 'VLESS';
	if (t.indexOf('VMESS')       >= 0) return 'VMESS';
	if (t.indexOf('TROJAN')      >= 0) return 'TROJAN';
	if (t.indexOf('HYSTERIA2')   >= 0) return 'HYSTERIA2';
	if (t.indexOf('HYSTERIA')    >= 0) return 'HYSTERIA';
	if (t.indexOf('TUIC')        >= 0) return 'TUIC';
	if (t.indexOf('WIREGUARD')   >= 0) return 'WIREGUARD';
	if (t.indexOf('AMNEZIA')     >= 0) return 'AMNEZIAWG';
	return '-';
}

function detectTransport(s, label) {
	var c = [s.transport, s.network, s.net, s.transfer_protocol];
	for (var i = 0; i < c.length; i++) {
		if (c[i]) {
			var v = String(c[i]).toLowerCase();
			if (v === 'grpc')        return 'gRPC';
			if (v === 'ws')          return 'WS';
			if (v === 'tcp')         return 'TCP';
			if (v === 'quic')        return 'QUIC';
			if (v === 'kcp')         return 'mKCP';
			if (v === 'httpupgrade') return 'HTTPUpgrade';
			if (v === 'xhttp')       return 'XHTTP';
			if (v === 'raw')         return 'RAW';
			if (v === 'ssh')         return 'SSH';
			return String(c[i]).toUpperCase();
		}
	}
	var t = String(label || '').toUpperCase();
	if (t.indexOf('GRPC')        >= 0) return 'gRPC';
	if (t.indexOf('WS')          >= 0) return 'WS';
	if (t.indexOf('HTTPUPGRADE') >= 0) return 'HTTPUpgrade';
	if (t.indexOf('XHTTP')       >= 0) return 'XHTTP';
	if (t.indexOf('KCP')         >= 0) return 'mKCP';
	if (t.indexOf('QUIC')        >= 0) return 'QUIC';
	if (t.indexOf('TCP')         >= 0) return 'TCP';
	if (t.indexOf('SSH')         >= 0) return 'SSH';
	return '-';
}

function detectSecurity(s, label) {
	var t = String(label || '').toUpperCase();
	if (s.reality || s.pbk || s.sid || t.indexOf('REALITY') >= 0) return 'REALITY';
	if (s.tls === '1' || s.tls === 1 || s.xtls === '1' || t.indexOf('TLS') >= 0) return 'TLS';
	if (t.indexOf('VISION') >= 0) return 'VISION';
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
	case 'switch':             return _('Switched');
	case 'stay':               return _('Stayed');
	case 'fallback_direct':    return _('Fallback to Direct');
	case 'fallback_blackhole': return _('Fallback to Blackhole');
	case 'rotate_all':         return _('Rotate All Nodes');
	default:                   return action || '-';
	}
}

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
	case 'rotate_all':return _('Rotate All \u2014 cycle through all nodes');
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
			fs.read_direct('/var/run/pw2watchdog/history.jsonl', 'text').catch(function() { return ''; }),
			fs.read_direct('/var/run/pw2watchdog/sub_update.json', 'json').catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var nodeIndex         = buildNodeIndex();
		var checkInterval     = uci.get('pw2watchdog', 'main', 'check_interval')  || '-';
		var nodeSelectionMode = uci.get('pw2watchdog', 'main', 'node_selection')  || 'auto';
		var fallbackActionCfg = uci.get('pw2watchdog', 'main', 'fallback_action') || 'blackhole';
		var subAutoUpdate     = uci.get('pw2watchdog', 'advanced', 'sub_auto_update') || '0';

		var status = {};
		try { status = data[2] || {}; } catch(e) {}
		var subData = {};
		try { subData = data[4] || {}; } catch(e) {}

		var recommendedCandidates = parseInt(status.recommended_candidates || 0);
		var candidateCount        = parseInt(status.candidate_count        || 0);
		var historyItems          = parseHistory(data[3] || '');

		var runtimeTable     = E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' });
		var historyContainer = E('div',   { 'id': 'pw2-history-container' });
		var lastRefreshEl    = E('span',  {}, '-');
		var subValueCell     = E('td',    { 'style': 'width:40%;padding:8px;vertical-align:top;' }, '-');

		/* ── Runtime renderer ─────────────────────────────────────────── */
		function renderRuntime(obj) {
			var currentNodeId      = uci.get('passwall2', 'rulenode', 'default_node') || obj.current_node || '-';
			// best_alt_node: best candidate != current node (set by watchdog choose_target)
			// Falls back to best_node if alt is absent (single-candidate edge case)
			var bestNodeId         = obj.best_node     || '-';
			var bestAltNodeId      = obj.best_alt_node  || '';
			var currentMeta        = getNodeMeta(nodeIndex, currentNodeId);
			var bestMeta           = getNodeMeta(nodeIndex, bestNodeId);
			var bestAltMeta        = bestAltNodeId ? getNodeMeta(nodeIndex, bestAltNodeId) : null;
			var nodeSelectionLive  = obj.node_selection  || nodeSelectionMode;
			var fallbackActionLive = obj.fallback_action || fallbackActionCfg;
			var isAuto             = (nodeSelectionLive === 'auto');

			/* All nodes except excluded — for auto mode candidate display */
			var excludeNodes = uci.get('pw2watchdog', 'main', 'exclude_node') || [];
			if (!Array.isArray(excludeNodes)) excludeNodes = [excludeNodes];
			excludeNodes = excludeNodes.filter(function(x) { return x && x !== ''; });

			var allNodes = [];
			uci.sections('passwall2').forEach(function(s) {
				if (!isRealNodeSection(s)) return;
				if (excludeNodes.indexOf(s['.name']) >= 0) return;
				allNodes.push(s['.name']);
			});

			runtimeTable.innerHTML = '';

			/* 1. Last subscription update — moved here from Proxy subscriptions block */
			if (subAutoUpdate === '1') {
				var subTs  = Number(subData.ts  || obj.sub_ts  || 0);
				var subCnt = Number(subData.subs_updated || 0);
				var subRes = String(subData.result || '');
				var subText = subTs > 0
					? (new Date(subTs * 1000).toLocaleString() + ' \u2014 ' +
					   subCnt + _(' subscription(s) updated') +
					   (subRes === 'error' ? ' (\u26a0 some failed)' : ''))
					: _('Not yet updated since boot');
				runtimeTable.appendChild(makeRow(
					_('Last subscription update'),
					makeSimpleValue(subText),
					_('Auto-update is enabled. Updated daily by pw2watchdog-subscribe.sh.')
				));
			}

			/* 2. Node selection mode */
			runtimeTable.appendChild(makeRow(
				_('Node selection mode'),
				makeSimpleValue(formatNodeSelectionMode(nodeSelectionLive)),
				_('auto: watchdog rotates candidates automatically; manual: you pick candidates on the Nodes page.')
			));

			/* 3. Fallback action */
			runtimeTable.appendChild(makeRow(
				_('Fallback action'),
				makeSimpleValue(formatFallbackAction(fallbackActionLive)),
				_('What happens when all candidate nodes are unavailable.')
			));

			/* 4. Current default node */
			runtimeTable.appendChild(makeRow(
				_('Current default node'),
				makeNodeValue(currentMeta, obj.current_latency),
				_('Currently active PassWall2 default node with its measured latency.')
			));

			/* 5. Best candidate node
			 * Show best_alt: best candidate that is NOT the current active node.
			 * If no alternative exists (only one candidate and it is the current node),
			 * show a "only candidate" note instead of the current node redundantly.
			 */
			var bestCandidateDisplay, bestCandidateLatency, bestCandidateDesc;
			if (bestAltMeta) {
				// Normal case: there is at least one candidate different from current
				bestCandidateDisplay  = makeNodeValue(bestAltMeta, obj.best_alt_latency);
				bestCandidateDesc     = _('Best available candidate node (excluding the currently active node), with its measured latency.');
			} else if (bestMeta && bestNodeId !== '-') {
				// Edge case: only candidate is the current node
				bestCandidateDisplay  = makeNodeValue(bestMeta, obj.best_latency);
				bestCandidateDesc     = _('Only candidate — no alternative nodes available at this time.');
			} else {
				bestCandidateDisplay  = makeSimpleValue('-');
				bestCandidateDesc     = _('Best candidate from the last watchdog cycle, with its measured latency.');
			}
			runtimeTable.appendChild(makeRow(
				_('Best candidate node'),
				bestCandidateDisplay,
				bestCandidateDesc
			));

			/* 6. Last node switch */
			runtimeTable.appendChild(makeRow(
				_('Last node switch'),
				makeSimpleValue(fmtTs(obj.last_switch)),
				_('Time of the last successful node switch.')
			));

			/* 7. Last node switch reason */
			runtimeTable.appendChild(makeRow(
				_('Last node switch reason'),
				makeSimpleValue(formatReason(obj.last_reason || '-')),
				_('Reason recorded for the latest watchdog decision.')
			));

			/* 8. Active candidates */
			var candidatesNote, candidatesValue;
			if (isAuto) {
				/* In auto mode — all nodes except excluded are potential candidates */
				candidatesValue = String(allNodes.length);
				candidatesNote  = _('All nodes except excluded. Watchdog rotates through them automatically.');
			} else {
				var liveCandidates = uci.get('pw2watchdog', 'main', 'candidate_node') || [];
				if (!Array.isArray(liveCandidates)) liveCandidates = [liveCandidates];
				liveCandidates = liveCandidates.filter(function(x) { return x && x !== ''; });
				candidatesValue = String(liveCandidates.length > 0 ? liveCandidates.length : (obj.candidate_count || '\u2014'));
				candidatesNote  = _('Number of nodes currently in the candidate pool for automatic selection.');
			}
			runtimeTable.appendChild(makeRow(
				_('Active candidates'),
				makeSimpleValue(candidatesValue),
				candidatesNote
			));

			/* 9. Last latency measurement (scanner) */
			var lastScanTs = Number(obj.last_scan_ts || 0);
			runtimeTable.appendChild(makeRow(
				_('Last latency measurement'),
				makeSimpleValue(lastScanTs > 0 ? new Date(lastScanTs * 1000).toLocaleString() : '-'),
				_('Time when the scanner last finished measuring node latencies.')
			));

			/* 10. Check interval */
			runtimeTable.appendChild(makeRow(
				_('Check interval'),
				makeSimpleValue(checkInterval !== '-' ? String(checkInterval) + ' s' : '-'),
				_('Delay between automatic node health and latency checks.')
			));

			/* 11. Last refresh */
			lastRefreshEl.textContent = new Date().toLocaleString();
		}

		/* ── History renderer ─────────────────────────────────────────── */
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
					E('th', { 'style': 'padding:8px;' }, _('Time')),
					E('th', { 'style': 'padding:8px;' }, _('Action')),
					E('th', { 'style': 'padding:8px;' }, _('Node')),
					E('th', { 'style': 'padding:8px;' }, _('Reason'))
				])
			]);

			items.slice(0, 20).forEach(function(item, idx) {
				var meta = getNodeMeta(nodeIndex, item.node || '-');
				if (item.label && (meta.label === meta.id || meta.label === (item.node || '-')))
					meta = Object.assign({}, meta, { label: item.label });

				/* IP address from cache if available */
				var ipStr = item.ip ? E('div', { 'style': 'font-size:12px;color:#888;' }, item.ip) : '';

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
						]),
						ipStr
					]),
					E('td', { 'style': 'padding:8px;' }, item.reason || '-')
				]));
			});
			historyContainer.appendChild(table);
		}

		/* ── Save history button ──────────────────────────────────────── */
		function makeSaveHistoryBtn(itemsRef) {
			return E('button', {
				'class': 'btn cbi-button',
				'style': 'margin-bottom:10px;',
				'click': function() {
					var lines = itemsRef.map(function(item) {
						var meta = getNodeMeta(nodeIndex, item.node || '-');
						if (item.label && (meta.label === meta.id || meta.label === (item.node || '-')))
							meta = Object.assign({}, meta, { label: item.label });
						return [
							fmtTs(item.ts),
							describeAction(item.action),
							meta.label || item.node || '-',
							(item.ip || ''),
							(item.reason || '-')
						].join('\t');
					});
					var header = ['Time', 'Action', 'Node', 'IP', 'Reason'].join('\t');
					var blob = new Blob([header + '\n' + lines.join('\n')], { type: 'text/plain' });
					var a = document.createElement('a');
					a.href = URL.createObjectURL(blob);
					a.download = 'pw2watchdog-history-' + new Date().toISOString().slice(0,19).replace(/:/g,'-') + '.txt';
					a.click();
				}
			}, _('Save history'));
		}

		/* ── Refresh all ──────────────────────────────────────────────── */
		var currentHistoryItems = historyItems;

		function refreshAll() {
			return Promise.all([
				fs.read('/var/run/pw2watchdog/status.json').catch(function() { return '{}'; }),
				fs.read('/var/run/pw2watchdog/history.jsonl').catch(function() { return ''; }),
				uci.load('passwall2'),
				fs.read('/var/run/pw2watchdog/sub_update.json').catch(function() { return '{}'; })
			]).then(function(res) {
				var obj = {};
				try { obj = JSON.parse(res[0] || '{}'); } catch(e) {}
				try { subData = JSON.parse(res[3] || '{}'); } catch(e) {}
				currentHistoryItems = parseHistory(res[1] || '');
				renderRuntime(obj);
				renderHistory(currentHistoryItems);
				/* Update excess banner (manual mode only) */
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

		/* ── Banners ──────────────────────────────────────────────────── */
		var runningBanner = renderRunningBanner();
		startRunningPoller(runningBanner);

		var excessBannerContainer = E('div', { 'id': 'pw2-excess-container' });
		if (nodeSelectionMode === 'manual') {
			var excessBanner = renderExcessBanner(candidateCount, recommendedCandidates);
			if (excessBanner) excessBannerContainer.appendChild(excessBanner);
		}

		/* ── Hardware block ───────────────────────────────────────────── */
		var hwBlock = renderHwBlock(status);

		/* ── Save history button container ────────────────────────────── */
		var saveHistoryBtnContainer = E('div', {});
		function updateSaveBtn() {
			saveHistoryBtnContainer.innerHTML = '';
			saveHistoryBtnContainer.appendChild(makeSaveHistoryBtn(currentHistoryItems));
		}
		updateSaveBtn();

		/* ── Last refresh row ─────────────────────────────────────────── */
		var lastRefreshRow = makeRow(
			_('Last refresh'),
			lastRefreshEl,
			_('Time when this page last refreshed runtime information.')
		);

		/* ── Build DOM ────────────────────────────────────────────────── */
		var root = E('div', {}, [
			runningBanner,
			excessBannerContainer,
			E('div', { 'class': 'cbi-map' }, [
				E('h2', _('PassWall2 Watchdog')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Runtime status and recent watchdog events. This page refreshes automatically.')
				),
				hwBlock || '',
				E('div', { 'class': 'cbi-section' }, [
					E('h3', _('Runtime status')),
					runtimeTable,
					/* Last refresh appended after table */
					E('table', { 'style': 'width:100%;' }, [ lastRefreshRow ])
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('details', { 'open': 'open' }, [
						E('summary', { 'style': 'cursor:pointer;font-weight:600;margin-bottom:12px;' },
							_('Recent events')),
						E('p', { 'style': 'margin:8px 0 12px 0;color:#666;' },
							_('History of watchdog decisions recorded since device start.')),
						saveHistoryBtnContainer,
						historyContainer
					])
				])
			]),
			renderActions()
		]);

		renderRuntime(status);
		renderHistory(historyItems);
		window.setInterval(function() {
			refreshAll().then(function() { updateSaveBtn(); });
		}, 5000);

		return root;
	}
});
