'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';

/* ------------------------------------------------------------------ *
 *  Node metadata helpers
 * ------------------------------------------------------------------ */
function isRealNodeSection(s) {
	if (!s || !s['.name']) return false;
	var stype = String(s['.type'] || '').toLowerCase();
	var name  = String(s['.name'] || '').toLowerCase();
	var proto = String(s.protocol || '').toLowerCase();
	var label = String(s.remarks || s.remark || '').toLowerCase();
	if (stype !== 'nodes')      return false;
	if (name === 'examplenode') return false;
	if (name === 'rulenode')    return false;
	if (proto === '_shunt')     return false;
	if (label === 'example')    return false;
	return true;
}

function detectProtocol(s, label) {
	var c = [s.protocol, s.type, s.node_type, s.proto];
	for (var i = 0; i < c.length; i++) if (c[i]) return String(c[i]).toUpperCase();
	var t = String(label || '').toUpperCase();
	if (t.indexOf('SHADOWSOCKS2022') >= 0 || t.indexOf('SS2022') >= 0) return 'SHADOWSOCKS2022';
	if (t.indexOf('SHADOWSOCKS') >= 0) return 'SHADOWSOCKS';
	if (t.indexOf('VLESS')      >= 0) return 'VLESS';
	if (t.indexOf('VMESS')      >= 0) return 'VMESS';
	if (t.indexOf('TROJAN')     >= 0) return 'TROJAN';
	if (t.indexOf('HYSTERIA2')  >= 0) return 'HYSTERIA2';
	if (t.indexOf('HYSTERIA')   >= 0) return 'HYSTERIA';
	if (t.indexOf('TUIC')       >= 0) return 'TUIC';
	if (t.indexOf('WIREGUARD')  >= 0) return 'WIREGUARD';
	if (t.indexOf('AMNEZIA')    >= 0) return 'AMNEZIAWG';
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
	if (t.indexOf('HTTPUPGRADE') >= 0) return 'HTTPUpgrade';
	if (t.indexOf('XHTTP')       >= 0) return 'XHTTP';
	if (t.indexOf('WS')          >= 0) return 'WS';
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

function buildNodeList() {
	var rows = [];
	uci.sections('passwall2').forEach(function(s) {
		if (!isRealNodeSection(s)) return;
		var label = s.remarks || s.remark || s.alias || s.address || s.server || s['.name'];
		rows.push({
			id: s['.name'], label: label,
			protocol:  detectProtocol(s, label),
			transport: detectTransport(s, label),
			security:  detectSecurity(s, label)
		});
	});
	rows.sort(function(a, b) { return String(a.label).localeCompare(String(b.label)); });
	return rows;
}

/* ------------------------------------------------------------------ *
 *  Latency badge + manual test
 * ------------------------------------------------------------------ */
function renderLatencyBadge(nodeId, cache) {
	if (!cache || !cache[nodeId])
		return E('span', { 'style': 'color:#aaa;font-size:0.85em;' }, '-');
	var entry   = cache[nodeId];
	var latency = entry.latency || 0;
	var status  = entry.status  || 'red';
	var color, bg;
	if (status === 'green')       { color = '#1a7f3c'; bg = '#d4edda'; }
	else if (status === 'yellow') { color = '#856404'; bg = '#fff3cd'; }
	else                          { color = '#842029'; bg = '#f8d7da'; }
	var text = latency > 0 ? (latency + ' ms') : _('timeout');
	return E('span', {
		'style': 'display:inline-block;padding:2px 7px;border-radius:10px;font-size:0.82em;' +
		         'font-weight:600;background:' + bg + ';color:' + color + ';white-space:nowrap;'
	}, text);
}

function testNode(nodeId, cell) {
	cell.innerHTML = '';
	cell.appendChild(E('span', { 'style': 'color:#aaa;font-size:0.85em;' }, '\u2026'));
	var url = L.url('admin/services/passwall2/urltest_node') +
	          '?id=' + encodeURIComponent(nodeId) + '&index=0';
	L.Request.get(url).then(function(res) {
		var data;
		try { data = res.json(); } catch(e) { data = null; }
		cell.innerHTML = '';
		if (data && data.use_time) {
			var ms = parseFloat(data.use_time);
			var st = ms <= 500 ? 'green' : ms <= 1500 ? 'yellow' : 'red';
			var color, bg;
			if (st === 'green')       { color = '#1a7f3c'; bg = '#d4edda'; }
			else if (st === 'yellow') { color = '#856404'; bg = '#fff3cd'; }
			else                      { color = '#842029'; bg = '#f8d7da'; }
			cell.appendChild(E('span', {
				'style': 'display:inline-block;padding:2px 7px;border-radius:10px;font-size:0.82em;' +
				         'font-weight:600;background:' + bg + ';color:' + color + ';white-space:nowrap;'
			}, Math.round(ms) + ' ms'));
		} else {
			cell.appendChild(E('span', { 'style': 'color:#842029;font-size:0.85em;' }, _('timeout')));
		}
	}).catch(function() {
		cell.innerHTML = '';
		cell.appendChild(E('span', { 'style': 'color:#842029;font-size:0.85em;' }, _('error')));
	});
}

/* ------------------------------------------------------------------ *
 *  Running banner
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
 *  Excess banner
 * ------------------------------------------------------------------ */
function renderExcessBanner(currentCount, recommendedCount) {
	if (!recommendedCount || !currentCount || currentCount <= recommendedCount) return null;
	return E('div', {
		'style': 'padding:12px 14px;border:1px solid #f1b0b7;background:#fff5f5;color:#842029;border-radius:4px;margin-bottom:1em;'
	}, [
		E('strong', _('Too many candidate nodes for this device.')),
		E('div', { 'style': 'margin-top:4px;' },
			_('You have %d candidates, but the recommended maximum is %d. ' +
			  'The watchdog may not finish measuring all nodes within one check interval. ' +
			  'Uncheck some candidates, or switch to Auto mode in Settings.')
			.format(currentCount, recommendedCount)
		)
	]);
}

/* ------------------------------------------------------------------ *
 *  Node table widget with Candidate + Excluded columns
 * ------------------------------------------------------------------ */
var NodeTable = form.Value.extend({

	renderWidget: function(section_id, option_index, cfgvalue) {
		var cbid        = this.cbid(section_id);
		var candidates  = Array.isArray(cfgvalue) ? cfgvalue : (cfgvalue ? [cfgvalue] : []);
		var excluded    = this.excludedNodes  || [];
		var cache       = this.latencyCache   || {};
		var recommended = this.recommendedCandidates || 0;
		var nodeMode    = this.nodeSelection  || 'auto';
		var rows        = buildNodeList();

		/* Candidate column heading depends on selection mode */
		var candidateColHeader = nodeMode === 'auto'
			? _('Auto')
			: _('Candidate');

		/* Live excess banner */
		var excessContainer = E('div', { 'id': 'pw2-excess-container' });

		function countChecked() {
			var n = 0;
			excessContainer.closest && excessContainer.closest('div') &&
				document.querySelectorAll('input[data-candidate]:checked').forEach(function() { n++; });
			/* More reliable: count via DOM from wrapper */
			n = 0;
			var wrap = document.getElementById(cbid);
			if (wrap) wrap.querySelectorAll('input[data-candidate]:checked').forEach(function() { n++; });
			return n;
		}

		function updateExcess() {
			excessContainer.innerHTML = '';
			var n = countChecked();
			/* Update counter */
			var counter = document.getElementById('pw2-candidate-counter');
			if (counter) counter.textContent = _('Nodes: %d \u2022 Selected: %d').format(rows.length, n);
			var b = renderExcessBanner(n, recommended);
			if (b) excessContainer.appendChild(b);
		}

		/* Table rows */
		var tableRows = rows.map(function(row, idx) {
			var isCandidate = candidates.indexOf(row.id) >= 0;
			var isExcluded  = excluded.indexOf(row.id)   >= 0;

			/* Row background for excluded nodes */
			var rowStyle = isExcluded
				? 'background:#f0f0f0;opacity:0.6;'
				: '';

			/* Candidate checkbox */
			var cbCandidate = E('input', {
				'type':           'checkbox',
				'data-candidate': '1',
				'data-node-id':   row.id,
				'checked':        isCandidate ? true : null,
				'disabled':       isExcluded  ? true : null,
				'style':          isExcluded  ? 'opacity:0.3;' : ''
			});

			/* Excluded checkbox */
			var cbExcluded = E('input', {
				'type':          'checkbox',
				'data-excluded': '1',
				'data-node-id':  row.id,
				'checked':       isExcluded ? true : null
			});

			/* Mutual exclusion: Excluded unchecks and disables Candidate */
			cbExcluded.addEventListener('change', function() {
				if (cbExcluded.checked) {
					cbCandidate.checked  = false;
					cbCandidate.disabled = true;
					cbCandidate.style.opacity = '0.3';
					cbCandidate.closest('tr').style.background = '#f0f0f0';
					cbCandidate.closest('tr').style.opacity    = '0.6';
				} else {
					cbCandidate.disabled = false;
					cbCandidate.style.opacity = '';
					cbCandidate.closest('tr').style.background = '';
					cbCandidate.closest('tr').style.opacity    = '';
				}
				var field = cbExcluded.closest('[data-field]');
				if (field) field.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
				updateExcess();
			});

			cbCandidate.addEventListener('change', function() {
				var field = cbCandidate.closest('[data-field]');
				if (field) field.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
				updateExcess();
			});

			/* Manual test result cell */
			var testResultCell = E('td', {
				'class': 'td',
				'style': 'padding:6px 8px;text-align:center;min-width:80px;'
			}, [ E('span', { 'style': 'color:#aaa;font-size:0.85em;' }, '-') ]);

			var testBtn = E('button', {
				'class': 'btn cbi-button',
				'style': 'padding:2px 8px;font-size:0.82em;',
				'click': function(ev) { ev.preventDefault(); testNode(row.id, testResultCell); }
			}, _('Test'));

			return E('tr', { 'class': 'tr cbi-section-table-row', 'style': rowStyle }, [
				E('td', { 'class': 'td', 'style': 'text-align:right;padding:6px 8px;width:1%;white-space:nowrap;color:#666;' }, String(idx + 1)),
				E('td', { 'class': 'td', 'style': 'padding:6px 8px;' }, row.label || '-'),
				E('td', { 'class': 'td', 'style': 'padding:6px 8px;' }, row.protocol  || '-'),
				E('td', { 'class': 'td', 'style': 'padding:6px 8px;' }, row.transport || '-'),
				E('td', { 'class': 'td', 'style': 'padding:6px 8px;' }, row.security  || '-'),
				E('td', { 'class': 'td', 'style': 'padding:6px 8px;text-align:center;' }, [ renderLatencyBadge(row.id, cache) ]),
				E('td', { 'class': 'td', 'style': 'text-align:center;padding:6px 8px;' }, [ testBtn ]),
				testResultCell,
				E('td', { 'class': 'td', 'style': 'text-align:center;padding:6px 8px;' }, [ cbCandidate ]),
				E('td', { 'class': 'td', 'style': 'text-align:center;padding:6px 8px;' }, [ cbExcluded ])
			]);
		});

		var initialSelected = candidates.length;

		var counterEl = E('span', {
			'id': 'pw2-candidate-counter',
			'style': 'color:#666;'
		}, _('Nodes: %d \u2022 Selected: %d').format(rows.length, initialSelected));

		var autoModeNote = nodeMode === 'auto'
			? E('p', { 'style': 'margin:0 0 0.75em 0;padding:8px 10px;background:#fffbea;border:1px solid #f59e0b;border-radius:4px;color:#78350f;font-size:0.9em;' },
				_('\u26a0 Node selection mode is Auto. The watchdog will automatically update the candidate list ' +
				  'after each scan cycle. Checked nodes shown here reflect the current auto selection \u2014 ' +
				  'manual changes will be overwritten on the next scan. ' +
				  'Changes take effect only after Save & Apply.')
			  )
			: E('p', { 'style': 'margin:0 0 0.75em 0;color:#666;font-size:0.9em;' },
				_('Check nodes to include in automatic switching (Candidate). ' +
				  'Check Excluded to permanently remove a node from all watchdog cycles. ' +
				  'Candidate and Excluded are mutually exclusive. ' +
				  'Changes take effect only after Save & Apply.')
			  );

		var wrapper = E('div', { 'id': cbid, 'style': 'width:95%;max-width:1200px;' }, [
			excessContainer,
			E('div', { 'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px;' }, [
				counterEl,
				E('div', { 'style': 'margin-left:auto;display:flex;gap:6px;' }, [
					E('button', {
						'class': 'btn cbi-button',
						'click': function(ev) {
							ev.preventDefault();
							var wrap = document.getElementById(cbid);
							if (wrap) wrap.querySelectorAll('input[data-candidate]:not(:disabled)').forEach(function(cb) {
								if (!cb.checked) { cb.checked = true; cb.dispatchEvent(new Event('change', { bubbles: true })); }
							});
						}
					}, _('Select all')),
					E('button', {
						'class': 'btn cbi-button',
						'click': function(ev) {
							ev.preventDefault();
							var wrap = document.getElementById(cbid);
							if (wrap) wrap.querySelectorAll('input[data-candidate]:checked').forEach(function(cb) {
								cb.checked = false; cb.dispatchEvent(new Event('change', { bubbles: true }));
							});
						}
					}, _('Clear all'))
				])
			]),
			autoModeNote,
			E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th', 'style': 'text-align:right;padding:6px 8px;width:1%;' }, '#'),
					E('th', { 'class': 'th', 'style': 'padding:6px 8px;' }, _('Label')),
					E('th', { 'class': 'th', 'style': 'padding:6px 8px;' }, _('Protocol')),
					E('th', { 'class': 'th', 'style': 'padding:6px 8px;' }, _('Transport')),
					E('th', { 'class': 'th', 'style': 'padding:6px 8px;' }, _('Security')),
					E('th', { 'class': 'th', 'style': 'text-align:center;padding:6px 8px;' }, _('Latency')),
					E('th', { 'class': 'th', 'style': 'text-align:center;padding:6px 8px;' }, _('Test')),
					E('th', { 'class': 'th', 'style': 'text-align:center;padding:6px 8px;' }, _('Result')),
					E('th', { 'class': 'th', 'style': 'text-align:center;padding:6px 8px;' }, candidateColHeader),
					E('th', { 'class': 'th', 'style': 'text-align:center;padding:6px 8px;' }, _('Excluded'))
				])
			].concat(tableRows))
		]);

		/* Initial excess banner */
		var initBanner = renderExcessBanner(initialSelected, recommended);
		if (initBanner) excessContainer.appendChild(initBanner);

		return wrapper;
	},

	/* Returns {candidate_node: [...], exclude_node: [...]} */
	formvalue: function(section_id) {
		var cbid  = this.cbid(section_id);
		var field = document.getElementById(cbid);
		if (!field) return [];
		/* candidate_node — primary list, written by form.Map */
		var result = [];
		field.querySelectorAll('input[data-candidate]:checked').forEach(function(cb) {
			var id = cb.getAttribute('data-node-id');
			if (id) result.push(id);
		});
		return result;
	},

	/* Excluded is read separately via getExcluded() */
	getExcluded: function(section_id) {
		var cbid  = this.cbid(section_id);
		var field = document.getElementById(cbid);
		if (!field) return [];
		var result = [];
		field.querySelectorAll('input[data-excluded]:checked').forEach(function(cb) {
			var id = cb.getAttribute('data-node-id');
			if (id) result.push(id);
		});
		return result;
	}
});

/* ------------------------------------------------------------------ *
 *  Custom save: write both candidate_node and exclude_node
 * ------------------------------------------------------------------ */
return view.extend({

	load: function() {
		return Promise.all([
			uci.load('pw2watchdog'),
			uci.load('passwall2'),
			L.resolveDefault(fs.read('/var/run/pw2watchdog/latency_cache.json').then(function(d) {
				try { return JSON.parse(d); } catch(e) { return {}; }
			}), {}),
			L.resolveDefault(fs.read('/var/run/pw2watchdog/status.json').then(function(d) {
				try { return JSON.parse(d); } catch(e) { return {}; }
			}), {})
		]);
	},

	render: function(data) {
		var latencyCache          = data[2] || {};
		var status                = data[3] || {};
		var recommendedCandidates = parseInt(status.recommended_candidates || 0);
		var nodeSelection         = uci.get('pw2watchdog', 'main', 'node_selection') || 'auto';
		var cfgSection            = uci.get('pw2watchdog', 'main') ? 'main' : 'config';

		/* Read excluded nodes from UCI */
		var excludedNodes = [];
		var rawExcluded = uci.get('pw2watchdog', 'main', 'exclude_node');
		if (Array.isArray(rawExcluded)) excludedNodes = rawExcluded;
		else if (rawExcluded)           excludedNodes = [rawExcluded];

		var m = new form.Map('pw2watchdog',
			_('PassWall2 Watchdog \u2014 Nodes'),
			_('Select which nodes participate in automatic switching (Candidates), ' +
			  'and which nodes are permanently excluded from all watchdog cycles (Excluded).')
		);

		var s = m.section(form.NamedSection, cfgSection, 'config', _('Node selection'));
		s.anonymous  = true;
		s.addremove  = false;
		s.full_width = true;

		var tableOpt = s.option(NodeTable, 'candidate_node', '');
		tableOpt.rmempty             = true;
		tableOpt.latencyCache        = latencyCache;
		tableOpt.excludedNodes       = excludedNodes;
		tableOpt.recommendedCandidates = recommendedCandidates;
		tableOpt.nodeSelection       = nodeSelection;

		/* Override save to write exclude_node */
		var origWrite = m.save.bind(m);
		m.save = function() {
			/* Collect excluded nodes before saving */
			var excluded = tableOpt.getExcluded ? tableOpt.getExcluded(cfgSection) : [];
			/* uci.set with an array — standard way to write a UCI list in LuCI */
			if (excluded.length > 0) {
				uci.set('pw2watchdog', cfgSection, 'exclude_node', excluded);
			} else {
				uci.unset('pw2watchdog', cfgSection, 'exclude_node');
			}
			return origWrite();
		};

		/* Actions */
		var actions = m.section(form.NamedSection, '__actions__', 'dummy');
		actions.render = function() {
			return E('div', { 'class': 'cbi-section', 'style': 'margin-top:1em;' }, [
				E('h3', _('Actions')),
				E('p', { 'style': 'margin:0 0 0.75em 0;color:#666;' },
					_('Open PassWall2 to review or change the active default proxy node.')
				),
				E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;' }, [
					E('a', {
						'class': 'btn cbi-button cbi-button-action',
						'href':  L.url('admin/services/passwall2')
					}, _('Open PassWall2'))
				])
			]);
		};

		return m.render().then(function(mapEl) {
			var banner = renderRunningBanner();
			var wrap   = E('div', {}, [ banner, mapEl ]);
			startRunningPoller(banner);
			return wrap;
		});
	}
});
