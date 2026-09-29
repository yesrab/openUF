'use strict';
'require view';
'require rpc';
'require fs';
'require ui';
'require poll';
'require dom';

const callStatus = rpc.declare({
	object: 'luci.openuf',
	method: 'getStatus'
});

const callRevert = rpc.declare({
	object: 'luci.openuf',
	method: 'revert'
});

// Ages against the device's own clock (the probe sends `now`), never the
// browser's: a board whose clock is days off would make every contact look
// ancient.
function age(now, ts) {
	if (!ts)
		return _('never');
	const secs = (now || Math.floor(Date.now() / 1000)) - ts;
	if (secs < 0)
		return _('just now');
	if (secs < 120)
		return _('%d seconds ago').format(secs);
	if (secs < 7200)
		return _('%d minutes ago').format(Math.floor(secs / 60));
	return _('%d hours ago').format(Math.floor(secs / 3600));
}

function yesno(v) {
	return v ? _('yes') : _('no');
}

// lua-cjson encodes an empty Lua table as {} -- so an empty list from the
// probe is an object, never an array. Every list goes through this.
function arr(v) {
	return Array.isArray(v) ? v : [];
}

function table(rows) {
	const t = E('table', { 'class': 'table' });
	for (const r of rows) {
		t.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'style': 'width:35%' }, r[0]),
			E('td', { 'class': 'td left' }, r[1] == null ? '-' : r[1])
		]));
	}
	return t;
}

function section(title, node, intro) {
	const parts = [ E('h3', {}, title) ];
	if (intro)
		parts.push(E('p', { 'class': 'cbi-section-descr' }, intro));
	parts.push(node);
	return E('div', { 'class': 'cbi-section' }, parts);
}

function controllerBlock(s) {
	const st = s.state || {}, h = s.health || {}, c = s.config || {};
	let adoption = st.adopted ? E('span', { 'class': 'label success' }, _('adopted')) :
		E('span', { 'class': 'label warning' }, _('not adopted yet'));
	if (!s.service || !s.service.running)
		adoption = E('span', { 'class': 'label danger' }, _('openUF is not running'));
	const rows = [
		[ _('Adoption'), adoption ],
		[ _('Last contact with the controller'), h.last_ok ? age(s.now, h.last_ok) : _('none yet') ],
		[ _('Last failed contact'), h.last_fail ? '%s (%s)'.format(age(s.now, h.last_fail), h.last_fail_msg || '') : _('none') ],
		[ _('Controller address'), st.inform_url || c.inform_url ],
		[ _('Controller configuration'), st.cfgversion ? _('received (version %s)').format(st.cfgversion) : _('none received yet') ],
		[ _('Address the controller knows this device by'), st.mac ],
		[ _('IP address and hostname'), st.ip ? '%s (%s)'.format(st.ip, st.hostname || '') : st.hostname ],
		[ _('Message encryption'), st.use_gcm ? _('AES-GCM, as current controllers require') : _('AES-CBC (the controller has not switched to GCM yet)') ]
	];
	return table(rows);
}

function deviceBlock(s) {
	const mm = s.modelmap || {}, id = s.identity || {};
	let profile = mm.name ? '%s (%s)'.format(mm.title || mm.name, mm.name) : _('none resolved');
	if (mm.name == 'custom')
		profile = _('custom profile from /etc/config/openuf');
	const identity = id.name ? '%s, model %s, firmware %s%s'.format(id.title || id.name, id.model || '?',
		id.fw_ver || '?', id.custom ? ' ' + _('(custom identity)') : '') : _('none');
	const sockets = mm.name ? (mm.dsa ?
		_('%d, each its own network interface; the uplink socket is detected from the cable').format(arr(mm.ports).length) :
		_('%d on a switch chip').format(arr(mm.ports).length)) : null;
	const rows = [
		[ _('Board'), s.board ],
		[ _('Hardware profile'), profile ],
		[ _('Ethernet sockets'), sockets ],
		[ _('Interface the controller identifies the device by'), mm.lan_cpueth ],
		[ _('Radios reported to the controller'), arr(mm.hwassign).length ? arr(mm.hwassign).join(', ') : _('all') ],
		[ _('Status LED'), mm.led || _('none, so "Locate" in the controller has no effect') ],
		[ _('Presented to the controller as'), identity ],
		[ _('Configured through'), s.uci_managed ? _('/etc/config/openuf (the Settings page)') :
			_('conf.lua, from a tarball install. Saving the Settings page moves the configuration to /etc/config/openuf') ],
		[ _('Service'), s.service ? '%s, %s'.format(s.service.running ? _('running') : _('stopped'),
			s.service.enabled ? _('starts at boot') : _('does not start at boot')) : null ],
		[ _('Version'), s.version ? '%s (%s)'.format(s.version, s.build || '') : (s.build || _('unknown')) ]
	];
	return table(rows);
}

// What openUF needs installed. The package brings every dependency in
// except the hostapd build: every wpad variant provides the same names, so
// no dependency can say "a full one", and a wpad-basic-* build rejects the
// 802.11v option every controller WLAN carries and takes the radio down.
// openUF refuses to start until a full build is there; the button below
// runs `openuf deps --install`, which does the swap and installs whatever
// else is missing. Rendered once, outside the polled block (see render()).
function installButton(w, missing) {
	const swap = (w.full === false);
	const choices = arr(w.choices);
	const select = E('select', { 'class': 'cbi-input-select' },
		choices.map(c => E('option', { 'value': c, 'selected': (c == w.suggested) ? '' : null }, c)));
	const label = swap
		? (missing.length ? _('Replace hostapd with the full build and install the missing packages') : _('Replace hostapd with the full build'))
		: _('Install the missing packages');
	const btn = E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': function() {
		const chosen = swap ? select.value : null;
		ui.showModal(label, [
			swap ? E('p', {}, _('%s is removed and %s installed. The radios are down for about ten seconds in between, then brought back up on the new build, and openUF is restarted. Do this over a cable, not over WiFi.').format(w.installed || _('the basic build'), chosen))
			     : E('p', {}, _('The packages are downloaded from the OpenWrt repository and installed, then openUF is restarted. The device needs internet access for this.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, function() {
					const args = [ 'deps', '--install' ];
					if (chosen)
						args.push('--wpad', chosen.replace(/^(wpad|hostapd)-/, ''));
					ui.showModal(_('Installing'), [ E('p', { 'class': 'spinning' }, _('Downloading and installing. This takes a minute or two; the page reloads when it is done.')) ]);
					const close = E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': function() { window.location.reload(); } }, _('Close')));
					return fs.exec_direct('/usr/bin/openuf', args, 'text', false, true).then(function(out) {
						ui.showModal(label, [ E('pre', {}, out || _('(no output)')), close ]);
					}).catch(function(e) {
						ui.showModal(label, [ E('pre', {}, String(e.message || e)), close ]);
					});
				}) }, _('Go ahead'))
			])
		]);
	} }, label);
	return E('div', {}, swap ? [ E('label', {}, _('Full build to install: ')), ' ', select, ' ', btn ] : [ btn ]);
}

function softwareBlock(s) {
	const d = s.deps || {};
	const w = d.wpad || {};
	const missing = arr(d.missing);
	function installed(ok, mandatory, detail) {
		if (ok)
			return E('span', { 'class': 'label success' }, detail ? _('yes (%s)').format(detail) : _('yes'));
		return E('span', { 'class': 'label ' + (mandatory ? 'danger' : 'warning') }, detail ? _('no: %s').format(detail) : _('no'));
	}
	const t = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Package')),
			E('th', { 'class': 'th' }, _('Needed')),
			E('th', { 'class': 'th' }, _('Installed')),
			E('th', { 'class': 'th' }, _('Enables'))
		])
	]);
	// The hostapd build first: the one thing the package cannot pull in.
	let build;
	if (w.full === true)
		build = installed(true, true, w.installed || _('not from a package'));
	else if (w.full === false)
		build = installed(false, true, w.installed || _('a basic build'));
	else
		build = E('em', {}, d.error || _('could not be determined'));
	t.appendChild(E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td' }, _('wpad, full build')),
		E('td', { 'class': 'td' }, _('mandatory')),
		E('td', { 'class': 'td' }, build),
		E('td', { 'class': 'td' }, _('802.11k/v, which every network from the controller uses; band steering, roaming assistant'))
	]));
	for (const p of arr(d.packages))
		t.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, p.pkg),
			E('td', { 'class': 'td' }, p.required ? _('mandatory') : _('optional')),
			E('td', { 'class': 'td' }, installed(p.present, p.required)),
			E('td', { 'class': 'td' }, p.unlocks)
		]));
	const parts = [ t ];
	if (w.full === false)
		parts.push(E('p', {}, _('openUF will not start with a basic hostapd build: it rejects the 802.11v option every network from the controller carries and takes the radio down with it. The full build of the same crypto library is suggested, so nothing else on the device changes and no extra flash is used.')));
	if (missing.length)
		parts.push(E('p', {}, _('A missing mandatory package stops openUF from running; a missing optional one leaves that feature off. Everything is installed from the OpenWrt package repository, so the device needs internet access for this.')));
	if (w.full === false || missing.length)
		parts.push(installButton(w, missing));
	return E('div', {}, parts);
}

function wlanBlock(s) {
	const w = arr(s.wlans);
	if (!w.length)
		return E('p', {}, _('None yet. The controller sends its WiFi networks once the device is adopted.'));
	const t = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Network name')),
			E('th', { 'class': 'th' }, _('Radio')),
			E('th', { 'class': 'th' }, _('Security')),
			E('th', { 'class': 'th' }, _('BSSID')),
			E('th', { 'class': 'th' }, _('On air'))
		])
	]);
	for (const v of w) {
		t.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, v.ssid || v.name),
			E('td', { 'class': 'td' }, v.radio || '-'),
			E('td', { 'class': 'td' }, v.encryption || '-'),
			E('td', { 'class': 'td' }, v.bssid || '-'),
			E('td', { 'class': 'td' }, yesno(!v.disabled))
		]));
	}
	return t;
}

function run(cmd, args, label, done) {
	return fs.exec(cmd, args).then(function(res) {
		if (res.code != 0)
			ui.addNotification(null, E('p', _('%s failed: %s').format(label, res.stderr || res.stdout || res.code)), 'danger');
		else
			ui.addNotification(null, E('p', done), 'info');
	}).catch(function(e) {
		ui.addNotification(null, E('p', _('%s failed: %s').format(label, e.message)), 'danger');
	});
}

function revertButton(status) {
	const c = status.convert || {};
	if (!c.converted)
		return null;
	return E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': function() {
		ui.showModal(_('Turn this device back into a router?'), [
			E('p', {}, _('The configuration files backed up when the device was converted are put back and the services that were enabled then are enabled again, then the device reboots. openUF stays installed. Anything changed in those files since the conversion is lost.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
					return callRevert().then(function(r) {
						if (r.code != 0) {
							ui.hideModal();
							ui.addNotification(null, E('pre', {}, _('Nothing was changed:') + '\n' + (r.output || r.code)), 'danger');
							return;
						}
						ui.showModal(_('Rebooting'), [ E('pre', {}, r.output || ''),
							E('p', { 'class': 'spinning' }, _('The device reboots now and comes back as a router.')) ]);
					});
				}) }, _('Restore the router configuration and reboot'))
			])
		]);
	} }, _('Turn back into a router'));
}

function actions(status) {
	const restart = E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, function() {
		return run('/etc/init.d/openuf', ['restart'], _('Restart'),
			_('openUF restarted. The controller sees a pause of a few seconds and nothing else changes.'));
	}) }, _('Restart openUF'));
	const scan = E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
		return run('/usr/bin/openuf', ['11k-scan'], _('Scan'),
			_('Scan requested. openUF sweeps every radio within the next ten seconds and reports the result to the controller; clients notice a short pause.'));
	}) }, _('Scan for nearby networks now'));
	const reset = E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': function() {
		ui.showModal(_('Forget the controller?'), [
			E('p', {}, _('The device forgets its adoption and the controller\'s address, and the controller shows it as disconnected until it is adopted again. The device is not removed from the controller: use "Forget" there as well for a clean start.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
					ui.hideModal();
					return run('/usr/bin/openuf', ['reset-inform'], _('Forget the controller'),
						_('Done. The device is ready to be adopted again.'));
				}) }, _('Forget the controller'))
			])
		]);
	} }, _('Forget the controller'));
	const parts = [ restart, ' ', scan, ' ', reset ];
	const revert = revertButton(status || {});
	if (revert)
		parts.push(' ', revert);
	return E('div', { 'class': 'cbi-page-actions' }, parts);
}

function body(s) {
	const parts = [];
	if (s.config_error)
		parts.push(E('div', { 'class': 'alert-message error' }, [
			E('strong', {}, _('openUF cannot start because its configuration does not load: ')),
			s.config_error,
			E('p', {}, _('Fix it on the Settings page or in /etc/config/openuf and restart openUF.'))
		]));
	if (s.deps && s.deps.wpad && s.deps.wpad.full === false)
		parts.push(E('div', { 'class': 'alert-message error' }, [
			E('strong', {}, _('openUF is not running: hostapd is a basic build (%s). ').format(s.deps.wpad.installed || 'wpad-basic')),
			_('It has no 802.11v support, which every network from the controller needs. Replace it with the full build under "Software openUF needs" below.')
		]));
	if (s.config && s.config.debug_overrides)
		parts.push(E('div', { 'class': 'alert-message warning' },
			_('Testing overrides are active in conf.lua (debug_caps or debug_payload_extra): the device is telling the controller it supports things it may not. Clear them when the test is done.')));
	parts.push(section(_('Controller connection'), controllerBlock(s)));
	parts.push(section(_('This device'), deviceBlock(s)));
	parts.push(section(_('WiFi networks from the controller'), wlanBlock(s)));
	return E('div', {}, parts);
}

function ledgerBlock(s) {
	const unsupported = (s.ledger || {}).entries || 0;
	return section(_('Controller features not supported yet'), E('p', {},
		unsupported ? _('The controller has sent %d kinds of setting or command that this version of openUF does not act on. That is normal: openUF records them in %s (passwords removed) so its developers can see what to build next. Nothing needs your attention.').format(unsupported, (s.ledger || {}).file || '/etc/openuf/unhandled.json')
			: _('The controller has not sent anything this version of openUF does not handle.')));
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	render: function(status) {
		// The buttons live outside the polled block: re-creating them every
		// ten seconds pulled them out from under a click.
		const container = E('div', {}, [
			E('h2', {}, _('openUF')),
			E('p', { 'class': 'cbi-section-descr' }, _('This OpenWrt device presents itself to a UniFi Network Application as a Ubiquiti access point. This page refreshes every ten seconds.')),
			E('div', { 'id': 'openuf-status' }, body(status)),
			// Not polled: it holds the install button and its dropdown, and
			// the answer changes only when the button has done its work,
			// after which the page reloads.
			section(_('Software openUF needs'), softwareBlock(status),
				_('The OpenWrt packages openUF works through, and the hostapd build. The openuf package brings every one of them in except the hostapd build, which OpenWrt cannot express as a dependency.')),
			// Polled on its own so it can sit below the software section.
			E('div', { 'id': 'openuf-ledger' }, ledgerBlock(status)),
			actions(status)
		]);
		poll.add(function() {
			return callStatus().then(function(s) {
				dom.content(container.querySelector('#openuf-status'), body(s));
				dom.content(container.querySelector('#openuf-ledger'), ledgerBlock(s));
			});
		}, 10);
		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
