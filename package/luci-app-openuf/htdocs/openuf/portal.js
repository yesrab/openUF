/*
 * openUF portal: the page a browser lands on instead of LuCI once the gate
 * (/usr/share/ucode/openuf/gate.uc) is active.
 *
 *   Overview        what anyone on the network may see: the device, whether
 *                   a UniFi controller manages it, and where to go to manage
 *                   it (luci.openuf getPublic, granted to unauthenticated
 *                   rpcd sessions and nothing else).
 *   Local Settings  the openUF settings, after logging in with the device's
 *                   root password (rpcd session.login, the same login LuCI
 *                   uses).
 *
 * The Konami code (or seven taps on the device picture) offers LuCI; the gate
 * then lets LuCI through until its login session ends.
 *
 * Plain ES2017, no framework, no build step: this ships as-is to routers.
 */
(function () {
	'use strict';

	const NULL_SID = '00000000000000000000000000000000';
	const SID_KEY = 'openuf.portal.sid';
	const POLL_MS = 10000;

	const $ = (sel, root) => (root || document).querySelector(sel);

	// Tiny element builder: h('div', {class: 'x', onclick: fn}, children...)
	function h(tag, attrs, ...kids) {
		const el = document.createElement(tag);
		for (const [k, v] of Object.entries(attrs || {})) {
			if (v == null || v === false) continue;
			if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
			else if (k === 'html') el.innerHTML = v;
			else if (v === true) el.setAttribute(k, '');
			else el.setAttribute(k, v);
		}
		for (const kid of kids.flat()) {
			if (kid == null || kid === false) continue;
			el.appendChild(typeof kid === 'string' || typeof kid === 'number' ? document.createTextNode(String(kid)) : kid);
		}
		return el;
	}

	// replaceChildren() turns null into the text "null"; this does not.
	function fill(el, ...kids) {
		el.replaceChildren(...kids.flat().filter(k => k != null && k !== false && k !== ''));
		return el;
	}

	const ICON = {
		lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
		info: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM8.75 11.5h-1.5V7h1.5v4.5ZM8 5.75a.9.9 0 1 1 0-1.8.9.9 0 0 1 0 1.8Z"/></svg>',
		external: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3h4v4M13 3 7.5 8.5M12 9.5V13H3V4h3.5"/></svg>',
		terminal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3M13 15h4"/></svg>'
	};

	// ── ubus over HTTP (uhttpd-mod-ubus, the endpoint LuCI uses) ──────────
	let rpcId = 0;
	async function ubus(sid, object, method, args) {
		const res = await fetch('/ubus', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method: 'call', params: [sid, object, method, args || {}] })
		});
		const doc = await res.json();
		if (doc.error) {
			const e = new Error(doc.error.message || 'ubus error');
			e.code = doc.error.code; // -32002: access denied (expired/invalid session)
			throw e;
		}
		const [code, data] = doc.result || [];
		if (code !== 0) {
			const e = new Error('ubus ' + object + '.' + method + ' failed (' + code + ')');
			e.code = code;
			throw e;
		}
		return data || {};
	}

	// ── formatting ───────────────────────────────────────────────────────
	function duration(sec) {
		sec = Math.max(0, Math.floor(sec));
		const d = Math.floor(sec / 86400), hr = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
		if (d) return d + 'd ' + hr + 'h';
		if (hr) return hr + 'h ' + m + 'm';
		if (m) return m + 'm';
		return sec + 's';
	}
	function ago(now, ts) {
		if (!ts) return null;
		const s = now - ts;
		if (s < 15) return 'just now';
		return duration(s) + ' ago';
	}
	function controllerUrl(c) {
		if (!c || !c.host || c.host === 'unifi') return null;
		return 'https://' + c.host + '/';
	}

	// ── toast & dialog ───────────────────────────────────────────────────
	let toastTimer;
	function toast(msg) {
		const t = $('#toast');
		t.textContent = msg;
		t.hidden = false;
		clearTimeout(toastTimer);
		toastTimer = setTimeout(() => { t.hidden = true; }, 3200);
	}

	function dialog({ icon, title, body, actions }) {
		const scrim = $('#scrim'), box = $('#dialog');
		const prevFocus = document.activeElement;
		fill(box, 
			icon ? h('div', { class: 'icon', html: icon }) : null,
			h('h3', { id: 'dialog-title' }, title),
			...[].concat(body).map(p => typeof p === 'string' ? h('p', {}, p) : p),
			h('div', { class: 'actions' }, actions.map(a => h('button', {
				class: 'btn ' + (a.class || ''),
				onclick: () => { close(); if (a.run) a.run(); }
			}, a.label)))
		);
		function close() {
			scrim.hidden = true;
			document.removeEventListener('keydown', onKey, true);
			if (prevFocus && prevFocus.focus) prevFocus.focus();
		}
		function onKey(e) {
			if (e.key === 'Escape') { e.preventDefault(); close(); }
		}
		scrim.onclick = e => { if (e.target === scrim) close(); };
		document.addEventListener('keydown', onKey, true);
		scrim.hidden = false;
		const buttons = box.querySelectorAll('.actions .btn');
		(buttons[buttons.length - 1] || box).focus();
	}

	// ── tabs ─────────────────────────────────────────────────────────────
	const tabs = { overview: $('#tab-overview'), settings: $('#tab-settings') };
	function selectTab(name, push) {
		for (const [n, btn] of Object.entries(tabs)) {
			const on = n === name;
			btn.setAttribute('aria-selected', on ? 'true' : 'false');
			btn.tabIndex = on ? 0 : -1;
			$('#panel-' + n).hidden = !on;
		}
		if (push) history.replaceState(null, '', name === 'settings' ? '#settings' : location.pathname);
		if (name === 'settings') renderSettings();
	}
	tabs.overview.addEventListener('click', () => selectTab('overview', true));
	tabs.settings.addEventListener('click', () => selectTab('settings', true));
	$('.segmented').addEventListener('keydown', e => {
		if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
		const next = tabs.overview.getAttribute('aria-selected') === 'true' ? 'settings' : 'overview';
		selectTab(next, true);
		tabs[next].focus();
	});

	// ── Overview ─────────────────────────────────────────────────────────
	let pub = null;

	function fact(k, v, opts) {
		opts = opts || {};
		return h('div', { class: 'fact card' },
			h('div', { class: 'k' }, k),
			h('div', { class: 'v' + (opts.mono ? ' mono' : '') + (v == null ? ' skeleton' : '') }, v == null ? '—————' : v),
			opts.sub ? h('div', { class: 's' }, opts.sub) : null);
	}

	function renderOverview() {
		const p = pub;
		const app = $('#app');
		const name = (p && (p.hostname || p.model)) || 'Access Point';
		$('#brand-name').textContent = name;
		document.title = name;

		const pill = $('#status-pill'), label = $('#status-label');
		const title = $('#hero-title'), lead = $('#hero-lead'), actions = $('#hero-actions');
		fill(actions, );
		app.classList.remove('state-ok', 'state-pending', 'state-bad');

		if (!p) {
			pill.className = 'status-pill';
			label.textContent = 'Checking…';
			return;
		}

		const ctl = p.controller;
		const url = controllerUrl(ctl);
		const presented = p.presented && (p.presented.title || p.presented.model);

		if (!p.running) {
			app.classList.add('state-bad');
			pill.className = 'status-pill bad';
			label.textContent = 'Not running';
			title.textContent = 'The UniFi agent is stopped';
			lead.textContent = 'This access point is not talking to a UniFi controller right now. Sign in under Local Settings to restart it.';
			actions.append(h('button', { class: 'btn', onclick: () => selectTab('settings', true) }, 'Local Settings'));
		} else if (p.adopted) {
			app.classList.add('state-ok');
			pill.className = 'status-pill ok';
			label.textContent = 'Managed by UniFi';
			title.textContent = 'This device is managed by UniFi Network';
			fill(lead, 
				'Its configuration comes from your UniFi controller' + (ctl ? ' at ' : ''),
				ctl ? h('strong', {}, ctl.host) : '',
				'. To change networks, radios or settings, manage it from UniFi Network.'
			);
			if (url) actions.append(h('a', { class: 'btn primary', href: url, target: '_blank', rel: 'noopener', html: 'Open UniFi Network ' + ICON.external }));
		} else {
			app.classList.add('state-pending');
			pill.className = 'status-pill warn';
			label.textContent = 'Ready for adoption';
			title.textContent = 'Waiting to be adopted';
			lead.textContent = 'Open UniFi Network and adopt this device' + (presented ? ' — it appears there as a ' + presented : '') + '. Its settings will then be managed from the controller.';
			if (url) actions.append(h('a', { class: 'btn primary', href: url, target: '_blank', rel: 'noopener', html: 'Open UniFi Network ' + ICON.external }));
			actions.append(h('button', { class: 'btn', onclick: () => selectTab('settings', true) }, 'Set controller address'));
		}

		const contact = p.last_contact ? ago(p.now, p.last_contact) : null;
		fill($('#facts'), 
			fact('Device', p.model || p.board || 'Unknown', { sub: presented ? 'Presented as ' + presented : null }),
			fact('MAC address', p.mac ? p.mac.toUpperCase() : 'Unknown', { mono: true }),
			fact('IP address', location.hostname, { mono: true }),
			(ctl && ctl.host !== 'unifi')
				? fact('Controller', ctl.host + (ctl.port && ctl.port !== 8080 ? ':' + ctl.port : ''), { mono: true })
				: fact('Controller', 'Not set', { sub: 'Looking for a host named “unifi”' }),
			fact('Last contact', contact || (p.adopted ? 'Not yet' : '—'), { sub: p.last_failure && p.last_failure > (p.last_contact || 0) ? 'Last attempt failed ' + ago(p.now, p.last_failure) : null }),
			fact('Uptime', p.uptime != null ? duration(p.uptime) : '—', { sub: p.version ? 'openUF ' + p.version : null })
		);
		$('#updated').textContent = 'Updated ' + new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
	}

	async function refreshPublic() {
		try {
			pub = await ubus(NULL_SID, 'luci.openuf', 'getPublic');
		} catch (e) {
			pub = pub || null;
			$('#updated').textContent = 'Could not reach the device: ' + e.message;
		}
		renderOverview();
	}

	// ── Local Settings ───────────────────────────────────────────────────
	let sid = sessionStorage.getItem(SID_KEY);
	let settings = null;     // { status, presets, values }
	let draft = {};          // option -> pending value
	const WEB_OPTS = ['portal'];

	function signOut(reason) {
		if (sid) ubus(sid, 'session', 'destroy', {}).catch(() => {});
		sid = null;
		settings = null;
		draft = {};
		sessionStorage.removeItem(SID_KEY);
		renderSession();
		renderSettings();
		if (reason) toast(reason);
	}

	function renderSession() {
		const slot = $('#session-slot');
		fill(slot, sid ? h('button', { class: 'btn ghost', onclick: () => signOut('Signed out') }, 'Sign out') : '');
	}

	function renderLogin(root) {
		const err = h('p', { class: 'form-error', role: 'alert' });
		const pw = h('input', { class: 'input', type: 'password', id: 'pw', autocomplete: 'current-password', placeholder: 'Password' });
		const btn = h('button', { class: 'btn primary', type: 'submit' }, 'Sign in');
		const form = h('form', {
			onsubmit: async e => {
				e.preventDefault();
				btn.disabled = true;
				err.textContent = '';
				try {
					const r = await ubus(NULL_SID, 'session', 'login', { username: 'root', password: pw.value, timeout: 1800 });
					sid = r.ubus_rpc_session;
					sessionStorage.setItem(SID_KEY, sid);
					if (pw.value === '') sessionStorage.setItem(SID_KEY + '.nopw', '1');
					else sessionStorage.removeItem(SID_KEY + '.nopw');
					renderSession();
					renderSettings();
				} catch (ex) {
					err.textContent = 'That password is not correct.';
					pw.classList.add('invalid');
					pw.select();
					btn.disabled = false;
				}
			}
		},
			h('div', { class: 'field' },
				h('label', { for: 'pw' }, 'Device password'),
				pw,
				h('p', { class: 'hint' }, 'The root password of this device.')),
			err, btn);
		pw.addEventListener('input', () => pw.classList.remove('invalid'));
		fill(root, h('div', { class: 'login card' },
			h('div', { class: 'lock', html: ICON.lock }),
			h('h2', {}, 'Local Settings'),
			h('p', {}, 'Settings for the UniFi agent on this access point.'),
			form));
		setTimeout(() => pw.focus(), 50);
	}

	async function loadSettings() {
		const [status, presets, main, web] = await Promise.all([
			ubus(sid, 'luci.openuf', 'getStatus'),
			ubus(sid, 'luci.openuf', 'listPresets'),
			ubus(sid, 'uci', 'get', { config: 'openuf', section: 'main' }).catch(() => null),
			ubus(sid, 'uci', 'get', { config: 'openuf', section: 'web' }).catch(() => null)
		]);
		// No `main` section: openUF was installed from the tarball and runs
		// from conf.lua. Creating the section would put UCI in charge of the
		// daemon with almost nothing in it, so those fields stay read-only.
		settings = {
			status, presets,
			hasMain: !!(main && main.values),
			hasWeb: !!(web && web.values),
			values: Object.assign({}, main && main.values, web && web.values)
		};
		draft = {};
	}

	function value(opt, dflt) {
		if (opt in draft) return draft[opt];
		const v = settings.values[opt];
		return v == null ? dflt : v;
	}

	function setDraft(opt, v) {
		const orig = settings.values[opt];
		if ((orig == null ? undefined : String(orig)) === String(v)) delete draft[opt];
		else draft[opt] = String(v);
		renderSavebar();
	}

	function row(label, hint, control, opts) {
		return h('div', { class: 'row' + (opts && opts.stack ? ' stack' : '') + (opts && opts.inline ? ' inline' : '') },
			h('div', { class: 'meta' }, h('span', { class: 'label' }, label), hint ? h('p', { class: 'hint' }, hint) : null),
			h('div', { class: 'control' }, control));
	}

	function toggle(opt, dflt, disabled) {
		const input = h('input', { type: 'checkbox', disabled: !!disabled, role: 'switch' });
		input.checked = value(opt, dflt) === '1';
		input.addEventListener('change', () => setDraft(opt, input.checked ? '1' : '0'));
		return h('label', { class: 'switch' }, input, h('span'));
	}

	function select(opt, dflt, choices, disabled) {
		const sel = h('select', { class: 'select', disabled: !!disabled },
			choices.map(c => h('option', { value: c.value }, c.label)));
		sel.value = value(opt, dflt);
		sel.addEventListener('change', () => setDraft(opt, sel.value));
		return sel;
	}

	function text(opt, dflt, attrs, validate) {
		const input = h('input', Object.assign({ class: 'input', type: 'text', spellcheck: 'false' }, attrs || {}));
		input.value = value(opt, dflt);
		input.addEventListener('input', () => {
			const ok = !validate || validate(input.value);
			input.classList.toggle('invalid', !ok);
			if (ok) setDraft(opt, input.value);
		});
		return input;
	}

	function presetChoices(list, autoLabel) {
		const out = [{ value: 'auto', label: autoLabel }];
		for (const p of list || []) {
			if (!p || !p.name || p.name === 'custom') continue;
			out.push({ value: p.name, label: p.title || p.name });
		}
		if (!out.some(c => c.value === 'custom')) out.push({ value: 'custom', label: 'Custom (configured in LuCI)' });
		return out;
	}

	function renderSavebar() {
		const old = $('.savebar');
		const n = Object.keys(draft).length;
		if (!n) { if (old) old.remove(); return; }
		const bar = h('div', { class: 'savebar' },
			h('span', { class: 'msg' }, n === 1 ? '1 unsaved change' : n + ' unsaved changes'),
			h('div', { class: 'actions' },
				h('button', { class: 'btn ghost', onclick: () => { draft = {}; renderSettings(); } }, 'Discard'),
				h('button', { class: 'btn primary', onclick: save }, 'Apply')));
		if (old) old.replaceWith(bar); else $('#settings-root').append(bar);
	}

	async function save() {
		const values = Object.assign({}, draft);
		const btns = document.querySelectorAll('.savebar .btn');
		btns.forEach(b => { b.disabled = true; });
		// The page switch lives in its own section (see gate.uc); every other
		// option is openuf.main's.
		const webValues = {}, mainValues = {};
		for (const [k, v] of Object.entries(values)) (WEB_OPTS.includes(k) ? webValues : mainValues)[k] = v;
		try {
			if (Object.keys(mainValues).length)
				await ubus(sid, 'uci', 'set', { config: 'openuf', section: 'main', values: mainValues });
			if (Object.keys(webValues).length) {
				if (settings.hasWeb)
					await ubus(sid, 'uci', 'set', { config: 'openuf', section: 'web', values: webValues });
				else {
					await ubus(sid, 'uci', 'add', { config: 'openuf', type: 'web', name: 'web', values: webValues });
					settings.hasWeb = true;
				}
			}
			// rpcd's commit fires config.change, which openUF's init script
			// answers with a reload (procd_add_reload_trigger "openuf").
			await ubus(sid, 'uci', 'commit', { config: 'openuf' });
			Object.assign(settings.values, values);
			draft = {};
			toast('Saved. openUF is applying the changes.');
			setTimeout(refreshPublic, 2500);
			renderSettings();
		} catch (e) {
			if (e.code === -32002) return signOut('Your session expired. Sign in again.');
			toast('Could not save: ' + e.message);
			btns.forEach(b => { b.disabled = false; });
		}
	}

	async function exec(cmd, params, done) {
		try {
			await ubus(sid, 'file', 'exec', { command: cmd, params: params || [] });
			toast(done);
			setTimeout(refreshPublic, 2500);
		} catch (e) {
			if (e.code === -32002) return signOut('Your session expired. Sign in again.');
			toast('Failed: ' + e.message);
		}
	}

	function renderForm(root) {
		const ro = !settings.hasMain;   // tarball install: conf.lua is in charge
		const st = settings.status || {};
		const state = st.state || {};
		const adopted = state.adopted === true;
		const running = st.service && st.service.running;
		const presets = settings.presets || {};
		const informValid = v => /^https?:\/\/[^\s/]+(:\d+)?(\/\S*)?$/.test(v.trim());

		const groups = [];

		groups.push(h('div', { class: 'group card' },
			h('div', { class: 'group-title' }, 'Controller'),
			ro ? h('div', { class: 'notice warn', html: ICON.info + '<span>openUF was installed without its package here, so its settings live in <code>conf.lua</code> on the device. They are shown, not editable.</span>' }) : null,
			row('Inform URL', adopted
				? 'The controller has set this. It changes it itself when needed.'
				: 'Where this access point looks for a UniFi controller until one adopts it.',
				text('inform_url', (st.config && st.config.inform_url) || 'http://unifi:8080/inform', { placeholder: 'http://192.0.2.1:8080/inform', 'aria-label': 'Inform URL', disabled: ro }, informValid),
				{ stack: true }),
			row('Adoption', adopted ? 'Adopted' + (state.inform_url ? ' by ' + state.inform_url.replace(/^https?:\/\//, '').replace(/[:/].*$/, '') : '') : 'Not adopted yet',
				h('button', {
					class: 'btn danger', disabled: !adopted,
					onclick: () => dialog({
						icon: ICON.info,
						title: 'Forget the controller?',
						body: ['This access point will drop its adoption and the configuration the controller pushed, and wait to be adopted again.', 'The controller will show it as offline until you forget it there too.'],
						actions: [{ label: 'Cancel' }, { label: 'Forget controller', class: 'danger solid', run: () => exec('/usr/bin/openuf', ['reset-inform'], 'Adoption reset.') }]
					})
				}, 'Forget controller'))
		));

		const idLocked = adopted;
		groups.push(h('div', { class: 'group card' },
			h('div', { class: 'group-title' }, 'Device'),
			idLocked ? h('div', { class: 'notice', html: ICON.info + '<span>The hardware profile and UniFi identity are locked while the device is adopted: the controller knows it by them. Forget the controller first to change them.</span>' }) : null,
			row('Hardware profile', 'How openUF reads this board: its ports, radios and status light.',
				select('modelmap', ro ? ((st.modelmap && st.modelmap.name) || 'auto') : 'auto', presetChoices(presets.modelmaps, 'Automatic' + (presets.auto ? ' (' + presets.auto + ')' : '')), idLocked || ro)),
			row('Presented as', 'The UniFi device model the controller sees.',
				select('ufmodel', ro ? ((st.identity && st.identity.name) || 'auto') : 'auto', presetChoices(presets.ufmodels, 'Automatic (profile default)'), idLocked || ro))
		));

		groups.push(h('div', { class: 'group card' },
			h('div', { class: 'group-title' }, 'Wireless'),
			row('Only broadcast UniFi networks', 'Turn off wireless networks set up on this device by hand, so only the controller\'s networks are on the air.', toggle('use_only_unifi_wlan', '1', ro), { inline: true }),
			row('Announce on the local network', 'Let UniFi Network discover this access point without typing its address.', toggle('l2_announce', '1', ro), { inline: true })
		));

		groups.push(h('div', { class: 'group card' },
			h('div', { class: 'group-title' }, 'This page'),
			row('Show this page instead of LuCI', 'When off, the device\'s address opens OpenWrt\'s LuCI interface as before.', toggle('portal', '1'), { inline: true })
		));

		groups.push(h('div', { class: 'group card' },
			h('div', { class: 'group-title' }, 'Service'),
			row('UniFi agent', running ? 'Running' : 'Stopped',
				h('button', { class: 'btn', onclick: () => exec('/etc/init.d/openuf', ['restart'], 'openUF restarted.') }, running ? 'Restart' : 'Start'), { inline: true }),
			row('Device', 'Restarts the access point. Clients reconnect within a few minutes.',
				h('button', {
					class: 'btn', onclick: () => dialog({
						icon: ICON.info, title: 'Restart the access point?',
						body: 'Wireless clients will be disconnected while it restarts.',
						actions: [{ label: 'Cancel' }, { label: 'Restart', class: 'primary', run: async () => {
							try { await ubus(sid, 'system', 'reboot', {}); toast('Restarting…'); } catch (e) { toast('Failed: ' + e.message); }
						} }]
					})
				}, 'Restart'), { inline: true })
		));

		const nopw = sessionStorage.getItem(SID_KEY + '.nopw') === '1';
		fill(root, 
			nopw ? h('div', { class: 'notice warn standalone', html: ICON.info + '<span><strong>This device has no password.</strong> Anyone who can reach it can change these settings. Set one with <code>passwd</code> over SSH, or in LuCI under System → Administration.</span>' }) : null,
			h('div', { class: 'settings-head' },
				h('div', {}, h('h2', {}, 'Local Settings'), h('p', {}, adopted
					? 'Wireless networks and radios are managed by your controller.'
					: 'Wireless networks and radios will be managed by your controller once it adopts this device.'))),
			...groups);
		renderSavebar();
	}

	let loading = false;
	async function renderSettings() {
		const root = $('#settings-root');
		if (!sid) return renderLogin(root);
		if (!settings) {
			if (loading) return;
			loading = true;
			fill(root, h('div', { class: 'group card', style: 'height:180px' }, h('div', { class: 'skeleton', style: 'height:100%' })));
			try {
				await loadSettings();
			} catch (e) {
				loading = false;
				if (e.code === -32002 || e.code === 6) return signOut('Your session expired. Sign in again.');
				fill(root, h('div', { class: 'login card' }, h('h2', {}, 'Could not load settings'), h('p', {}, e.message)));
				return;
			}
			loading = false;
		}
		renderForm(root);
	}

	// ── the way into LuCI ────────────────────────────────────────────────
	function offerLuci() {
		if (!$('#scrim').hidden) return;
		dialog({
			icon: ICON.terminal,
			title: 'Open LuCI?',
			body: [
				'LuCI is OpenWrt\'s full configuration interface. This device is managed by your UniFi controller, which may overwrite changes made there.',
				'You will need the device\'s root password. Use “Exit LuCI mode” at the top of LuCI to come back.'
			],
			actions: [{ label: 'Stay here' }, { label: 'Open LuCI', class: 'primary', run: () => { window.location.href = '/cgi-bin/luci/__openuf/unlock'; } }]
		});
	}

	const KONAMI = ['arrowup', 'arrowup', 'arrowdown', 'arrowdown', 'arrowleft', 'arrowright', 'arrowleft', 'arrowright', 'b', 'a'];
	let konami = 0;
	document.addEventListener('keydown', e => {
		if (e.target && /^(INPUT|SELECT|TEXTAREA)$/.test(e.target.tagName)) return;
		const k = (e.key || '').toLowerCase();
		konami = k === KONAMI[konami] ? konami + 1 : (k === KONAMI[0] ? 1 : 0);
		if (konami === KONAMI.length) { konami = 0; offerLuci(); }
	});
	// No arrow keys on a phone: seven quick taps on the device picture.
	let taps = 0, tapTimer;
	$('#device-art').addEventListener('click', () => {
		taps++;
		clearTimeout(tapTimer);
		tapTimer = setTimeout(() => { taps = 0; }, 1500);
		if (taps >= 7) { taps = 0; offerLuci(); }
	});

	// ── start ────────────────────────────────────────────────────────────
	const q = new URLSearchParams(location.search);
	if (q.has('locked')) toast('Back from LuCI');
	else if (q.has('expired')) toast('Your LuCI session ended');
	if (q.has('locked') || q.has('expired')) history.replaceState(null, '', location.pathname + location.hash);

	renderSession();
	selectTab(location.hash === '#settings' ? 'settings' : 'overview', false);
	refreshPublic();
	setInterval(() => { if (!document.hidden) refreshPublic(); }, POLL_MS);
	document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshPublic(); });
})();
