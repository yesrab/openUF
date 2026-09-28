'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
'require dom';

const callPresets = rpc.declare({
	object: 'luci.openuf',
	method: 'listPresets'
});

const callStatus = rpc.declare({
	object: 'luci.openuf',
	method: 'getStatus'
});

const callDiscover = rpc.declare({
	object: 'luci.openuf',
	method: 'discover'
});

const callExport = rpc.declare({
	object: 'luci.openuf',
	method: 'exportPreset'
});

const callConvertState = rpc.declare({
	object: 'luci.openuf',
	method: 'getConvertState'
});

const callConvert = rpc.declare({
	object: 'luci.openuf',
	method: 'convert',
	params: [ 'address', 'gateway', 'dns', 'keep_wan_socket' ]
});

// lua-cjson encodes an empty Lua table as {}, so an empty list from the
// probe arrives as an object.
function arr(v) {
	return Array.isArray(v) ? v : [];
}

// A tarball install (setup.sh / install.sh) has no /etc/config/openuf. The
// first save here creates it, and from then on it is the configuration -- so
// the form starts from what the daemon currently runs with, read off the
// probe, and the first save changes nothing but the source.
function seedFromStatus(status) {
	const mm = status.modelmap || {}, id = status.identity || {}, c = status.config || {};
	uci.add('openuf', 'openuf', 'main');
	uci.set('openuf', 'main', 'modelmap', mm.name || 'auto');
	uci.set('openuf', 'main', 'ufmodel', id.name || 'auto');
	const opts = [ 'inform_url', 'neighbour_scan_interval', 'rrm_request_interval', 'roam_assist_diff_db',
		'country_override', 'bootstrap_adopt_user', 'debug_dump_file', 'debug_dump_max_bytes' ];
	for (const k of opts)
		if (c[k] != null && c[k] !== '')
			uci.set('openuf', 'main', k, String(c[k]));
	const flags = [ 'use_only_unifi_wlan', 'l2_announce', 'rrm_enrichment', 'debug_dump_requests' ];
	for (const k of flags)
		if (c[k] != null)
			uci.set('openuf', 'main', k, c[k] ? '1' : '0');
	if (arr(c.keep_wlan_sections).length)
		uci.set('openuf', 'main', 'keep_wlan_section', c.keep_wlan_sections);
}

// The custom profile starts from what the board says about itself (the
// probe's discovery draft): its sockets, its switch geometry, its radios, a
// status LED nothing else drives. Seeded once, when no custom sections exist
// yet; from then on the sections are the user's. They are saved with the rest
// of the file whichever profile is selected, and the daemon reads them only
// while the profile is "custom".
function seedCustom(discover, presets) {
	const d = discover.draft || {};
	if (!uci.get('openuf', 'custom')) {
		uci.add('openuf', 'device', 'custom');
		const set = (k, v) => { if (v != null && v !== '') uci.set('openuf', 'custom', k, String(v)); };
		set('openwrt_board', d.openwrt_board);
		set('lan_cpueth', d.lan_cpueth);
		set('lan_name', 'lan');
		set('lan_vlanid', d.lan_vlanid);
		set('wan_cpueth', d.wan_cpueth);
		set('uplink_detect', d.uplink_detect);
		set('led', d.led);
		set('ufmodel', 'u6iw');
		if (arr(d.hwassign).length)
			uci.set('openuf', 'custom', 'hwassign', d.hwassign);
		for (const p of arr(d.ports)) {
			const sid = uci.add('openuf', 'port');
			uci.set('openuf', sid, 'idx', String(p.idx));
			if (p.ifname)
				uci.set('openuf', sid, 'ifname', p.ifname);
			if (p.swport)
				uci.set('openuf', sid, 'swport', String(p.swport));
		}
		if (d.vlan && typeof d.vlan == 'object' && !Array.isArray(d.vlan)) {
			uci.add('openuf', 'vlan', 'custom_vlan');
			if (d.vlan.device)
				uci.set('openuf', 'custom_vlan', 'device', d.vlan.device);
			if (d.vlan.cpu_lan != null)
				uci.set('openuf', 'custom_vlan', 'cpu_lan', String(d.vlan.cpu_lan));
			if (d.vlan.cpu_wan != null)
				uci.set('openuf', 'custom_vlan', 'cpu_wan', String(d.vlan.cpu_wan));
			const ports = (d.vlan.ports && !Array.isArray(d.vlan.ports)) ? d.vlan.ports : {};
			for (const label of Object.keys(ports).sort()) {
				const sid = uci.add('openuf', 'swport');
				uci.set('openuf', sid, 'label', label);
				uci.set('openuf', sid, 'num', String(ports[label]));
			}
		}
		const radio = (d.radio && !Array.isArray(d.radio)) ? d.radio : {};
		for (const band of [ 'na', 'ng' ]) {
			const r = radio[band];
			if (!r || !uci.add('openuf', 'radio', band))
				continue;
			if (r.acs_exclude_dfs != null)
				uci.set('openuf', band, 'acs_exclude_dfs', r.acs_exclude_dfs ? '1' : '0');
			if (r.htmode_floor)
				uci.set('openuf', band, 'htmode_floor', r.htmode_floor);
			if (r.htmode_max)
				uci.set('openuf', band, 'htmode_max', r.htmode_max);
		}
	}
	if (!uci.get('openuf', 'custom_identity')) {
		// Start from the identity every shipped profile uses, so a custom one
		// is a change of firmware version or model code, not a blank form.
		let u6 = null;
		for (const u of arr(presets.ufmodels))
			if (u.name == 'u6iw')
				u6 = u;
		uci.add('openuf', 'identity', 'custom_identity');
		uci.set('openuf', 'custom_identity', 'platform', (u6 && u6.platform) || 'U6IW');
		uci.set('openuf', 'custom_identity', 'model', (u6 && u6.model) || 'U6IW');
		uci.set('openuf', 'custom_identity', 'fw_pre', ((u6 && u6.model) || 'U6IW') + '.');
		if (u6 && u6.fw_ver)
			uci.set('openuf', 'custom_identity', 'fw_ver', u6.fw_ver);
		uci.set('openuf', 'custom_identity', 'required_version', '6.0.0');
	}
}

function presetMappingTable(preset) {
	if (!preset)
		return E('em', {}, _('No shipped profile is selected.'));
	const rows = [];
	for (const p of arr(preset.ports))
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, String(p.idx)),
			E('td', { 'class': 'td' }, p.ifname || (p.swport != null ? _('switch port %s').format(p.swport) : '-')),
			E('td', { 'class': 'td' }, p.uplink ? _('fixed uplink') : '')
		]));
	return E('div', {}, [
		E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Port in the controller')),
				E('th', { 'class': 'th' }, _('Socket')),
				E('th', { 'class': 'th' }, '')
			])
		].concat(rows)),
		E('p', {}, _('Radios reported: %s. Status LED: %s. Identity interface: %s.').format(
			arr(preset.hwassign).join(', ') || _('all'), preset.led || _('none'), preset.lan_cpueth || '-'))
	]);
}

function downloadLink(text, filename) {
	return E('a', {
		'class': 'btn cbi-button cbi-button-action',
		'href': 'data:text/x-lua;charset=utf-8,' + encodeURIComponent(text),
		'download': filename
	}, _('Download %s').format(filename));
}

function convertBlock(state) {
	const reasons = arr(state.reasons);
	const modal = function() {
		const mode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'dhcp' }, _('Take an address from the network\'s DHCP server (recommended)')),
			E('option', { 'value': 'static' }, _('Use a fixed address'))
		]);
		const ip = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '192.168.1.20/24', 'style': 'width:100%' });
		const gw = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '192.168.1.1', 'style': 'width:100%' });
		const dns = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '192.168.1.1', 'style': 'width:100%' });
		const keep = E('input', { 'type': 'checkbox' });
		const staticBox = E('div', { 'style': 'display:none; margin:.5em 0' }, [
			E('label', {}, _('Address and prefix length')), ip,
			E('label', {}, _('Gateway')), gw,
			E('label', {}, _('DNS servers, space separated')), dns
		]);
		mode.addEventListener('change', function() { staticBox.style.display = (mode.value == 'static') ? '' : 'none'; });
		ui.showModal(_('Convert this device into an access point?'), [
			E('p', {}, _('This removes the WAN interfaces, joins the WAN socket to the LAN, switches off the DHCP server, the firewall and dnsmasq, enables every radio, and reboots. The device stops routing: everything on it will reach the network through the LAN sockets. A backup of the configuration is kept so this can be undone from the Overview page.')),
			E('p', {}, _('After the reboot the device will most likely have a different address. Find it in your router\'s DHCP client list or through the controller once it is adopted; this page will not reconnect on its own.')),
			E('div', { 'style': 'margin:.5em 0' }, [ E('label', {}, _('Management address')), mode ]),
			staticBox,
			E('div', { 'style': 'margin:.5em 0' }, [ E('label', {}, [ keep, ' ', _('Leave the WAN socket out of the LAN (keep it unused)') ]) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
					const address = (mode.value == 'static') ? ip.value.trim() : 'dhcp';
					if (mode.value == 'static' && !/^\d{1,3}(\.\d{1,3}){3}\/\d{1,2}$/.test(address)) {
						ui.addNotification(null, E('p', _('The fixed address must be written as address/prefix, for example 192.168.1.20/24.')), 'danger');
						return;
					}
					return callConvert(address, gw.value.trim(), dns.value.trim(), keep.checked).then(function(r) {
						if (r.code != 0) {
							ui.hideModal();
							ui.addNotification(null, E('pre', {}, _('The conversion was refused, nothing was changed:') + '\n' + (r.output || r.code)), 'danger');
							return;
						}
						ui.showModal(_('Rebooting'), [
							E('pre', {}, r.output || ''),
							E('p', { 'class': 'spinning' }, _('The device reboots now and comes back as an access point.'))
						]);
					});
				}) }, _('Convert and reboot'))
			])
		]);
	};
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Turn this device into an access point')),
		E('p', {}, _('This device is still set up as a router: %s. An access point should not route, serve DHCP or run a firewall, and its WAN socket should be an ordinary LAN socket. openUF works either way, but the network will see two routers until this is done.').format(reasons.join('; '))),
		E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': modal }, _('Convert to an access point and reboot'))
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callPresets(), {}),
			L.resolveDefault(callStatus(), {}),
			// A tarball install may have no /etc/config/openuf at all (install.sh
			// creates an empty one since 2026-09-29); a missing file must not
			// take the page down with an RPC error.
			L.resolveDefault(uci.load('openuf'), null),
			L.resolveDefault(callDiscover(), {}),
			L.resolveDefault(callConvertState(), { state: 'unknown' })
		]);
	},

	render: function(data) {
		const presets = data[0] || {}, status = data[1] || {};
		const discover = data[3] || {}, convertState = data[4] || { state: 'unknown' };
		const adopted = !!(status.state && status.state.adopted);
		const fresh = !uci.get('openuf', 'main');
		if (fresh)
			seedFromStatus(status);
		if (data[2] != null)
			seedCustom(discover, presets);
		const dsa = discover.layout == 'dsa';
		if (data[2] == null)
			ui.addNotification(null, E('p', _('This device has no /etc/config/openuf file yet, so saving here would fail. Create it once with `touch /etc/config/openuf` (newer installers do this) and reload this page.')), 'warning');

		const m = new form.Map('openuf', _('openUF settings'),
			_('Which hardware this device is, which UniFi access point it presents itself as, and how it behaves. Saving restarts openUF; the controller sees a pause of a few seconds and nothing else changes.'));

		const s = m.section(form.NamedSection, 'main', 'openuf');
		s.addremove = false;
		s.tab('profile', _('Hardware and identity'));
		s.tab('controller', _('Controller'));
		s.tab('features', _('WiFi behaviour'));
		s.tab('debug', _('Troubleshooting'));

		let o;
		const lock = adopted ? ' ' + _('Locked while the device is adopted: changing this would change the address the controller knows the device by, and the controller would refuse every message afterwards. Use "Forget the controller" on the Overview page first, then change it and adopt again.') : '';

		// ── hardware and identity ──
		o = s.taboption('profile', form.ListValue, 'modelmap', _('Hardware profile'),
			_('Describes this board to openUF: its Ethernet sockets, radios and status LED. "Automatic" picks the shipped profile made for this board, and openUF refuses to start rather than guess if none was made for it.') + lock);
		o.value('auto', presets.auto ? _('Automatic (this board: %s)').format(presets.auto) : _('Automatic (no shipped profile matches this board)'));
		for (const p of arr(presets.modelmaps))
			o.value(p.name, '%s [%s]%s'.format(p.title, arr(p.boards).join(', ') || _('generic'),
				p.unverified ? ' ' + _('(not yet verified on real hardware)') : ''));
		o.value('custom', _('Custom profile (the device, port, vlan and radio sections of /etc/config/openuf)'));
		o.default = 'auto';
		o.rmempty = false;
		o.readonly = adopted;

		o = s.taboption('profile', form.ListValue, 'ufmodel', _('UniFi model to present'),
			_('The Ubiquiti access point the controller will believe this device is. "Automatic" is the profile\'s own choice. Match the hardware generation: a WiFi 5 board should present as a WiFi 5 model, a board with one radio as a single-radio model.') + lock);
		o.value('auto', _('Automatic (the profile\'s choice)'));
		for (const u of arr(presets.ufmodels))
			o.value(u.name, '%s, model %s, firmware %s%s'.format(u.title, u.model || u.name, u.fw_ver || '?',
				u.unverified ? ' ' + _('(not yet verified with a controller)') : ''));
		o.value('custom', _('Custom identity (the identity section of /etc/config/openuf)'));
		o.default = 'auto';
		o.rmempty = false;
		o.readonly = adopted;

		if (fresh)
			o.description += ' ' + _('This device is currently configured by its conf.lua file. The values shown are the ones it runs with; saving moves the configuration to /etc/config/openuf and changes nothing else.');

		// ── controller ──
		o = s.taboption('controller', form.Value, 'inform_url', _('Controller address'),
			_('Where the device sends its heartbeats until the controller assigns another address during adoption. When the controller is on the same network, discovery finds it and this can stay as it is.'));
		o.placeholder = 'http://unifi:8080/inform';
		o.validate = function(section_id, value) {
			if (value == '' || /^https?:\/\/[^\s/]+(\/\S*)?$/.test(value))
				return true;
			return _('Must be a web address starting with http:// or https://');
		};

		o = s.taboption('controller', form.Flag, 'l2_announce', _('Announce the device on the local network'),
			_('Broadcasts on UDP port 10001 so the controller lists the device for adoption without any manual step. Switch off only when the controller is on another network and the address above is set.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('controller', form.Value, 'bootstrap_adopt_user', _('SSH account for adoption'),
			_('The locked-down user the controller may log in as during adoption (created by `install.sh --bootstrap-adopt`). It is locked once the device is adopted and unlocked again after a reset. Leave empty if you adopt with the root account or by address.'));
		o.placeholder = 'ubnt';
		o.datatype = 'uciname';

		// ── WiFi behaviour ──
		o = s.taboption('features', form.Flag, 'use_only_unifi_wlan', _('Broadcast only the controller\'s WiFi networks'),
			_('Turns off WiFi networks that were set up by hand in OpenWrt, so the radios carry only what the controller sends. openUF remembers what it turned off; unticking this brings them back.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('features', form.DynamicList, 'keep_wlan_section', _('Hand-made WiFi networks to keep on air'),
			_('OpenWrt wireless section names (for example default_radio0) that stay enabled even with the option above ticked.'));
		o.depends('use_only_unifi_wlan', '1');
		o.datatype = 'uciname';

		o = s.taboption('features', form.Flag, 'rrm_enrichment', _('Ask clients to report nearby networks'),
			_('Fills the controller\'s Environment view without taking the radios off their channels: one capable client at a time is asked to look around and report what it sees (802.11k).'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('features', form.Value, 'rrm_request_interval', _('Ask a client every (seconds)'),
			_('How often one client is asked to report. 600 (ten minutes) when left empty.'));
		o.placeholder = '600';
		o.datatype = 'uinteger';
		o.depends('rrm_enrichment', '1');

		o = s.taboption('features', form.Value, 'neighbour_scan_interval', _('Scan for nearby networks every (seconds)'),
			_('The access point itself looks around at this interval. 0 or empty means never. Each scan takes a radio off its channel for a moment, which clients notice as a short pause.'));
		o.placeholder = '0';
		o.datatype = 'uinteger';

		o = s.taboption('features', form.Value, 'roam_assist_diff_db', _('Roaming Assistant: required signal advantage (dB)'),
			_('How much more strongly another access point must hear a weak client before openUF moves the client there. The Roaming Assistant itself is switched on per WiFi network in the controller. 8 when left empty.'));
		o.placeholder = '8';
		o.datatype = 'uinteger';

		o = s.taboption('features', form.Value, 'country_override', _('Country code override'),
			_('A two-letter country code programmed into the radios instead of the one the controller sends. Leave empty to follow the controller.'));
		o.placeholder = _('for example SE');
		o.validate = function(section_id, value) {
			if (value == '' || /^[A-Za-z]{2}$/.test(value))
				return true;
			return _('Two letters, for example SE');
		};

		// ── troubleshooting ──
		o = s.taboption('debug', form.Value, 'debug_dump_file', _('Write the controller\'s messages to a file'),
			_('For troubleshooting only: every message the controller sends is written to this file. It contains WiFi passwords, so keep it on /tmp (cleared at reboot) and empty this field when done.'));
		o.placeholder = '/tmp/openuf-dump.txt';

		o = s.taboption('debug', form.Flag, 'debug_dump_requests', _('Also write what openUF sends to the controller'),
			_('Adds every outgoing heartbeat to the same file. Only meaningful with a file set above.'));
		o.rmempty = false;
		o.default = '0';

		o = s.taboption('debug', form.Value, 'debug_dump_max_bytes', _('Maximum size of that file (bytes)'),
			_('The file starts over once it reaches this size, so it cannot fill /tmp. 4194304 (4 MiB) when left empty.'));
		o.placeholder = '4194304';
		o.datatype = 'uinteger';

		// ── custom hardware profile: what the board reported, editable ──
		const netdevs = arr(discover.netdevs).slice().sort(function(a, b) {
			return (b.bridge ? 1 : 0) - (a.bridge ? 1 : 0) || a.name.localeCompare(b.name);
		});
		const sd = m.section(form.NamedSection, 'custom', 'device', _('Custom hardware profile'),
			_('Used only while the hardware profile above is "Custom profile". Filled in from what this board reports about itself (%s, %s); check every line against the device, because two of them cannot be read off the board: which socket carries which label, and which LED is free for Locate.').format(
				discover.board ? discover.board.name || discover.board.id : _('unknown board'),
				dsa ? _('one network interface per socket') : (discover.layout == 'swconfig' ? _('a switch chip with a VLAN table') : _('switch layout unknown'))));
		sd.addremove = false;

		o = sd.option(form.Value, 'openwrt_board', _('OpenWrt board name'),
			_('The name OpenWrt reports for this board (vendor,model). "Automatic" matches shipped profiles by it.'));
		o.placeholder = discover.board ? discover.board.id : 'vendor,model';
		o.validate = function(section_id, value) {
			return (value == '' || /^[\w.-]+,[\w.-]+$/.test(value)) ? true : _('Written as vendor,model');
		};

		o = sd.option(form.ListValue, 'lan_cpueth', _('Interface whose address identifies the device'),
			_('The controller adopts the device under this interface\'s MAC address, and a pushed IP setting lands on it. On a board with one interface per socket this is the LAN bridge; on a switch-chip board it is the CPU-side interface of the LAN.'));
		for (const n of netdevs)
			o.value(n.name, '%s (%s%s)'.format(n.name, n.mac, n.bridge ? ', ' + _('bridge') : (n.dsa ? ', ' + _('socket') : '')));
		o.rmempty = false;

		o = sd.option(form.ListValue, 'wan_cpueth', _('WAN socket or interface'),
			_('The socket a router uses for its uplink. Listed so it can be reported like the others; openUF never assumes the cable is in it.'));
		o.value('', _('none'));
		for (const n of netdevs)
			o.value(n.name, n.name);

		o = sd.option(form.Flag, 'uplink_detect', _('Find the uplink socket from where the cable is'),
			_('On a board with one interface per socket the uplink is detected at runtime, so the cable can be in any socket. Off for switch-chip boards, which have no such per-socket view.'));
		o.enabled = 'fdb';
		o.disabled = '';
		o.default = dsa ? 'fdb' : '';

		o = sd.option(form.ListValue, 'led', _('Status LED used for Locate'),
			_('The LED the controller\'s Locate blinks. Pick one nothing else drives; the ones OpenWrt itself uses at boot or for WiFi activity are marked.'));
		o.value('', _('none (Locate does nothing)'));
		for (const l of arr(discover.leds)) {
			const used = arr(l.used_by);
			o.value(l.name, l.name + (used.length ? ' (' + _('used by %s').format(used.join(', ')) + ')' :
				(l.trigger != 'none' ? ' (' + _('trigger %s').format(l.trigger) + ')' : '')));
		}

		o = sd.option(form.MultiValue, 'hwassign', _('Radios reported to the controller'),
			_('Tick the radios openUF should present and manage. A radio left out is never reported and never touched.'));
		for (const r of arr(discover.radios))
			if (r.uci)
				o.value(r.uci, '%s: %s, up to %s MHz%s'.format(r.uci, r.band, r.max_width || '?', r.he ? ', WiFi 6' : (r.vht ? ', WiFi 5' : ', WiFi 4')));
		o.rmempty = true;

		o = sd.option(form.Value, 'lan_name', _('LAN network name'), _('The OpenWrt network the identity interface belongs to; "lan" on a stock configuration.'));
		o.placeholder = 'lan';

		o = sd.option(form.Value, 'lan_vlanid', _('LAN VLAN id'), _('The VLAN of the LAN on the switch chip; 1 unless the board tags its CPU port.'));
		o.placeholder = '1';
		o.datatype = 'uinteger';

		// ── sockets → ports ──
		const sp = m.section(form.GridSection, 'port', _('Ethernet sockets as the controller lists them'),
			_('One line per RJ45 socket on the case. The port number is what the controller shows and keys per-port settings on, so pick it once and never renumber. The list starts in the order OpenWrt names the sockets, which is usually the order on the case but not always.'));
		sp.anonymous = true;
		sp.addremove = true;
		sp.sortable = true;
		sp.nodescriptions = true;
		o = sp.option(form.Value, 'idx', _('Port number'));
		o.datatype = 'uinteger';
		o.rmempty = false;
		if (dsa) {
			o = sp.option(form.ListValue, 'ifname', _('Socket'));
			for (const sk of arr(discover.sockets))
				o.value(sk.netdev, '%s (%s)'.format(sk.netdev, sk.role));
		}
		else {
			o = sp.option(form.Value, 'swport', _('Switch port label'));
			o.placeholder = 'lan1';
			o = sp.option(form.Flag, 'uplink', _('Fixed uplink'));
		}

		// ── switch geometry, switch-chip boards only ──
		if (!dsa) {
			const sv = m.section(form.NamedSection, 'custom_vlan', 'vlan', _('Switch chip'),
				_('Which switch device carries the LAN and which of its ports are the CPU ports. Board truth: read it off the board\'s stock configuration, not from guesswork.'));
			sv.addremove = true;
			o = sv.option(form.Value, 'device', _('Switch device'));
			o.placeholder = 'switch0';
			o = sv.option(form.Value, 'cpu_lan', _('CPU port of the LAN'));
			o.datatype = 'uinteger';
			o = sv.option(form.Value, 'cpu_wan', _('CPU port of the WAN'));
			o.datatype = 'uinteger';
			const sw = m.section(form.GridSection, 'swport', _('Switch port labels'),
				_('Which physical switch port carries which socket label.'));
			sw.anonymous = true;
			sw.addremove = true;
			sw.nodescriptions = true;
			o = sw.option(form.Value, 'label', _('Label'));
			o.placeholder = 'lan1';
			o.rmempty = false;
			o = sw.option(form.Value, 'num', _('Physical port'));
			o.datatype = 'uinteger';
			o.rmempty = false;
		}

		// ── per-band radio policy ──
		const radioByBand = {};
		for (const r of arr(discover.radios))
			radioByBand[r.openuf_band] = r;
		for (const band of [ 'na', 'ng' ]) {
			const rd = radioByBand[band] || {};
			const sr = m.section(form.NamedSection, band, 'radio',
				band == 'na' ? _('5 GHz radio: what "Auto" means on this board') : _('2.4 GHz radio: what "Auto" means on this board'),
				_('Overrides the controller where the board needs it: widths the driver advertises but cannot run, DFS channels to leave to ACS. Leave empty to follow the controller.'));
			sr.addremove = true;
			if (band == 'na') {
				o = sr.option(form.Flag, 'acs_exclude_dfs', _('Keep automatic channel selection off DFS channels'),
					_('Radar-detection channels take a minute of silence before use and can be vacated at any time.'));
				o.rmempty = true;
			}
			o = sr.option(form.ListValue, 'htmode_floor', _('Narrowest channel width to use'));
			o.value('', _('no floor'));
			for (const md of arr(rd.modes))
				if (md != 'NOHT')
					o.value(md, md);
			o = sr.option(form.ListValue, 'htmode_max', _('Widest channel width to use'));
			o.value('', _('no cap'));
			for (const md of arr(rd.modes))
				if (md != 'NOHT')
					o.value(md, md);
			o = sr.option(form.DynamicList, 'channel', _('Channels allowed for automatic selection'));
			o.datatype = 'uinteger';
		}

		// ── custom UniFi identity ──
		const si = m.section(form.NamedSection, 'custom_identity', 'identity', _('Custom UniFi identity'),
			_('Used only while "UniFi model to present" above is "Custom identity". The model code and firmware version come from Ubiquiti\'s own firmware catalogue; the controller compares the version character for character, so a prefix or a "+" shows as a permanent "Update available".'));
		si.addremove = false;
		o = si.option(form.Value, 'platform', _('Platform code'), _('For example U6IW or UHDIW.'));
		o.rmempty = false;
		o = si.option(form.Value, 'model', _('Model code'), _('Usually the same as the platform code.'));
		o.rmempty = false;
		o = si.option(form.Value, 'fw_ver', _('Firmware version'), _('Bare, as 6.8.2.15592.'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^\d+\.\d+\.\d+\.\d+$/.test(value) ? true : _('Four numbers separated by dots, for example 6.8.2.15592');
		};
		o = si.option(form.Value, 'fw_pre', _('Firmware name prefix'), _('For example U6IW. (with the dot). Empty means the model code plus a dot.'));
		o = si.option(form.Value, 'fw_buildtime', _('Firmware build time'), _('Cosmetic, reaches only the discovery broadcast. Written as YYMMDD.HHMM.'));
		o = si.option(form.Value, 'fw_factoryver', _('Factory firmware version'), _('Cosmetic, as above.'));
		o = si.option(form.Value, 'required_version', _('Minimum controller version'), _('6.0.0 when empty.'));
		o.placeholder = '6.0.0';
		o = si.option(form.Value, 'bootver', _('Boot loader version'), _('Usually left empty.'));

		// ── which sections show, from the two dropdowns ──
		const presetByName = {};
		for (const p of arr(presets.modelmaps))
			presetByName[p.name] = p;
		return m.render().then(function(node) {
			// lookupOption walks the rendered DOM, so only now.
			const mmOpt = m.lookupOption('modelmap', 'main')[0];
			const ufOpt = m.lookupOption('ufmodel', 'main')[0];
			const presetMapping = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Ports, radios and LED of the selected shipped profile')),
				E('p', { 'class': 'cbi-section-descr' }, _('A custom identity keeps the shipped profile\'s mapping. To change the mapping, choose "Custom profile" above: it starts from what this board reports.')),
				E('div', { 'id': 'openuf-preset-mapping' })
			]);
			const exportBlock = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Share this profile')),
				E('p', { 'class': 'cbi-section-descr' }, _('Once saved, the custom profile can be exported as a profile file for the openUF project, so the next owner of this board gets it as a shipped profile. It is exported with a note that it has not been verified by the maintainers.')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
					return callExport().then(function(r) {
						if (!r || r.error) {
							ui.addNotification(null, E('p', _('Nothing to export: %s').format(r ? r.error : '')), 'warning');
							return;
						}
						ui.showModal(_('Profile file %s').format(r.filename), [
							E('textarea', { 'style': 'width:100%; height:50vh; font-family:monospace; font-size:12px', 'readonly': 'readonly' }, [ r.text ]),
							E('div', { 'class': 'right' }, [
								E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')), ' ',
								downloadLink(r.text, r.filename)
							])
						]);
					});
				}) }, _('Export the saved custom profile as a file'))
			]);
			const extras = E('div', {}, [ presetMapping, exportBlock ]);
			if (!fresh && convertState.state == 'router')
				extras.appendChild(convertBlock(convertState));

			// A named section carries the id on its field container, a grid
			// section on the section itself; hide the whole section either way.
			function show(id, on) {
				const el = node.querySelector('#cbi-openuf-' + id);
				const sec = el ? (el.closest('.cbi-section') || el) : null;
				if (sec)
					sec.style.display = on ? '' : 'none';
			}
			function refresh() {
				const mm = mmOpt.formvalue('main'), uf = ufOpt.formvalue('main');
				const customDev = (mm == 'custom'), customId = (uf == 'custom');
				for (const id of [ 'custom', 'port', 'custom_vlan', 'swport', 'na', 'ng' ])
					show(id, customDev);
				show('custom_identity', customId);
				presetMapping.style.display = (!customDev && customId) ? '' : 'none';
				exportBlock.style.display = customDev ? '' : 'none';
				const presetName = (mm == 'auto') ? presets.auto : mm;
				dom.content(presetMapping.querySelector('#openuf-preset-mapping'), presetMappingTable(presetByName[presetName]));
			}
			mmOpt.onchange = refresh;
			ufOpt.onchange = refresh;
			refresh();
			return E('div', {}, [ node, extras ]);
		});
	}
});
