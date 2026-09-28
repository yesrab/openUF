'use strict';
'require view';
'require fs';
'require poll';

// Every prefix openUF's modules log under, since the daemon logs as the
// module that spoke, not as one name. Filtered here, not by logread -e: on
// OpenWrt 25.12 (ubox logread) `-e daemon` matched nothing while `-e ^`
// matched everything, so the whole ring buffer is fetched the way LuCI's own
// System Log page does and the lines are picked out client-side.
const PATTERN = /openuf|inform|announce|l2guard|roamassist|sysconf|airtime|usteer|rrmscan|switchvlan|bcfilter|shaper/i;

function fetchLog() {
	return fs.exec_direct('/sbin/logread', [ '-e', '^' ]).then(function(all) {
		return String(all || '').split('\n').filter(function(l) { return PATTERN.test(l); }).join('\n');
	}).catch(function(e) {
		return _('Unable to read the log: %s').format(e.message);
	});
}

return view.extend({
	load: fetchLog,

	render: function(log) {
		const ta = E('textarea', {
			'id': 'openuf-log',
			'style': 'width:100%; height:65vh; font-family:monospace; font-size:12px',
			'readonly': 'readonly',
			'wrap': 'off'
		}, [ log || '' ]);
		poll.add(function() {
			return fetchLog().then(function(l) {
				ta.value = l;
				ta.scrollTop = ta.scrollHeight;
			});
		}, 5);
		ta.scrollTop = ta.scrollHeight;
		return E('div', {}, [
			E('h2', {}, _('openUF log')),
			E('p', { 'class': 'cbi-section-descr' }, _('Everything openUF wrote to the system log, newest at the bottom. Refreshes every five seconds.')),
			ta
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
