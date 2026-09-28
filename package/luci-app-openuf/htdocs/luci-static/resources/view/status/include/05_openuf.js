'use strict';
'require baseclass';
'require rpc';

// The essentials, on LuCI's Status -> Overview page: is the device adopted,
// when did the controller last hear from it, what does it present itself as.
// Everything else is on Services -> openUF.
const callStatus = rpc.declare({
	object: 'luci.openuf',
	method: 'getStatus'
});

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

return baseclass.extend({
	title: _('UniFi access point (openUF)'),

	load: function() {
		return L.resolveDefault(callStatus(), null);
	},

	render: function(s) {
		if (!s)
			return E('em', {}, _('openUF is not answering.'));
		const st = s.state || {}, h = s.health || {}, mm = s.modelmap || {}, id = s.identity || {};
		let adoption;
		if (!s.service || !s.service.running)
			adoption = E('span', { 'class': 'label danger' }, _('openUF is not running'));
		else if (s.config_error)
			adoption = E('span', { 'class': 'label danger' }, _('configuration error, see Services → openUF'));
		else
			adoption = st.adopted ? E('span', { 'class': 'label success' }, _('adopted')) :
				E('span', { 'class': 'label warning' }, _('not adopted yet'));
		const rows = [
			[ _('Adoption'), adoption ],
			[ _('Last contact with the controller'), h.last_ok ? age(s.now, h.last_ok) : _('none yet') ],
			[ _('Controller'), st.inform_url || (s.config || {}).inform_url || '-' ],
			[ _('Presented as'), id.name ? '%s (firmware %s)'.format(id.title || id.model || id.name, id.fw_ver || '?') : '-' ],
			[ _('Hardware profile'), mm.title || mm.name || '-' ]
		];
		const t = E('table', { 'class': 'table' });
		for (const r of rows)
			t.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:33%' }, r[0]),
				E('td', { 'class': 'td left' }, r[1])
			]));
		return t;
	}
});
