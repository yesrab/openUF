--[[
	UAP-IW-HD (UniFi In-Wall HD) device identity.

	The WiFi 5 in-wall AP: 802.11ac Wave 2, 4x4 on 5 GHz (1.7 Gbps at 80 MHz)
	and 2x2 on 2.4 GHz (300 Mbps at 40 MHz), one GbE PoE-in uplink and a
	built-in four-port GbE switch with one PoE-out socket -- five RJ45 sockets
	in all (techspecs.ui.com/unifi/wifi/uap-iw-hd). Ubiquiti's model code is
	UHDIW.

	Why a second in-wall identity: u6iw is 802.11ax, so a controller talking to
	it offers WiFi 6 modes (11nahe80 and up) that an 802.11n/ac board can never
	run and openUF has to clamp on every push (ucihelper.clamp_htmode). An
	802.11ac Wave 2 identity keeps the controller's own menus inside what the
	board can do, while the five-socket geometry -- the reason U6IW fits a
	4-LAN + WAN router -- stays the same. Meant for the Archer A7/C7 class of
	hardware (modelmap/archer-a7-v5.lua).

	⚠️ NOT yet validated against a live controller; u6iw is. What the
	controller checks is sourced, and what it does not is marked as such:
	  • model / platform "UHDIW": the controller's own firmware catalog files
	    this AP under that code --
	      fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware
	        &filter=eq~~platform~~UHDIW&filter=eq~~channel~~release
	    and Ubiquiti's 6.7.x AP release notes list "IW-HD" in the
	    nanoHD/FlexHD/BeaconHD group.
	  • fw.ver: that catalog's release entry, v6.7.57+15670, published
	    2026-09-03. The controller compares the inform's `version` to its
	    catalog entry with a strict, unnormalized string equality
	    (PROTOCOL-VALIDATION.md, "Why version must be bare"), so this MUST be
	    the bare M.m.p.build form and has to track the catalog: a stale value
	    shows a permanent "Update Available" for a fake AP with no firmware to
	    install. Re-read the URL above when the banner appears.
	  • fw.buildtime, fw.factoryver: cosmetic. They reach only the L2
	    discovery TLVs (announce.lua), never the inform. buildtime is the
	    catalog's publish timestamp, not a captured build stamp; factoryver is
	    the 4.0 firmware line these units shipped with, not read off a unit.
	  • Copied from u6iw, unverified for this model: fw.pre follows the model
	    code (a real unit's discovery string carries its MT7621 platform
	    prefix instead; the controller does not check it), required_version
	    and the empty bootver.
	  • NOT known: whether the model registry gives UHDIW the same 5-port
	    switch feature it gives U6IW -- it must, for wired clients and the
	    Ports view to exist at all (PROTOCOL-VALIDATION.md, "port_table[]
	    entry") -- and whether any WLAN feature (WPA3, Band Steering) is
	    gated per model. The tech specs describe a five-port device with a
	    built-in switch, which is what the registry encodes for U6IW; the
	    first adoption under this identity settles it. If a controller
	    balks, the fallback is one line in the modelmap: ufmodel = "u6iw".
]]--

local uap = {}

uap = {
	platform		= "UHDIW",
	model			= "UHDIW",
	fw				= {
		pre			= "UHDIW.",
		ver			= "6.7.57.15670",	-- format M.m.p.build -- bare, see header
		buildtime	= "260903.1127",	-- format YYMMDD.HHMM (catalog publish time)
		factoryver	= "4.0.80"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version (as u6iw)
}

return uap
