--[[
	U6 Mesh Pro (U6-Mesh-Pro) device identity.

	The WiFi 6 AP with exactly TWO RJ45 sockets: the PoE-in uplink and a
	second, bridged one (techspecs.ui.com/unifi/wifi/u6-mesh-pro). Ubiquiti's
	model code is U6MP.

	Why a fourth dual-band identity: the WiFi 6 one shipped so far, u6iw, is
	an in-wall AP with FIVE sockets, and the two-socket one, u7hd, is WiFi 5
	-- the controller offers a board under it 802.11ac modes only. A WiFi 6
	board with two sockets fits neither: under u6iw the Ports view carries
	three rows that never see a cable, under u7hd the radios are offered less
	than they can run. Meant for the OpenWrt One (modelmap/openwrt-one.lua).

	⚠️ NOT adopted by any controller yet; u6iw is the identity validated end
	to end. What the controller checks is sourced, and what it does not is
	marked as such:
	  • model / platform "U6MP": Ubiquiti's public device database, the one
	    the controller's own model list is built from
	    (static.ui.com/fingerprint/ui/public.json, fetched 2026-11-18), has
	    the "Access Point U6 Mesh Pro" as model "U6MP", sysid a6a1, and the
	    firmware catalog files its firmware under the same code --
	      fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware
	        &filter=eq~~platform~~U6MP&filter=eq~~channel~~release
	    Do not confuse it with UAP6MP: that is the U6 Pro, one socket.
	  • fw.ver: that catalog's release entry, v8.8.14+20179 of 2026-11-12 --
	    the build u6iw.lua is on. The controller compares the inform's
	    `version` to its catalog entry with a strict string equality
	    (PROTOCOL-VALIDATION.md, "Why version must be bare"), so this is the
	    bare M.m.p.build form. It is only the starting value: a controller
	    firmware update is accepted virtually (inform.lua) and the offered
	    version is reported from then on.
	  • fw.buildtime, fw.factoryver: cosmetic, they reach only the L2
	    discovery TLVs (announce.lua). buildtime is the build stamp in the
	    catalog entry's own tag (ubnt_version
	    "BZ.ipq50xx_8.8.14+20179.261030.1304"); factoryver is the oldest
	    release the catalog lists for the platform, v7.0.53 of 2024-05-15,
	    not read off a unit.
	  • Copied from u6iw, unverified for this model: fw.pre follows the model
	    code (a real unit's string carries its platform prefix, BZ.ipq50xx,
	    which the controller does not check), required_version and the empty
	    bootver. The database gives Network 8.1.127 as the oldest controller
	    that adopts this model: an older one has no U6MP in its model list,
	    and for that one u6iw is the identity to use.
	  • What the database says about the sockets: numberOfPorts 2, GbE, and
	    deviceCapabilities ACCESS_POINT / HAS_CLIENTS / VPORT. The U6-InWall
	    carries ACCESS_POINT_SWITCH and "hybrid": "uap+usw" on top of those;
	    the U6 Mesh Pro does not.
	  • NOT known: what that difference does to the wire. openUF sends the
	    same port_table and the same switch capability (fw_caps
	    hasOWRTSwitch) under every identity. Port count and the switch
	    feature decide whether the controller processes port_table at all
	    (Device.isSwitch(); PROTOCOL-VALIDATION.md, "port_table[] entry"),
	    so under this identity the controller may list the second socket's
	    wired hosts and offer no per-port settings (a Native VLAN on a
	    port), or ignore the table. An adoption with a wired host on the
	    second socket settles it. If a controller balks, or the per-port
	    settings are wanted, the fallback is one line in the modelmap:
	    ufmodel = "u6iw". The map keeps reporting its two real sockets; the
	    registry's three extra rows simply never link up.

	Streams and speeds are not this file's business: the controller takes
	nss and rates from radio_table (measured, per radio), and port_table
	reports each socket's negotiated speed, so a 2.5 GbE socket under this
	GbE identity is reported as what it linked at.
]]--

local uap = {}

uap = {
	platform		= "U6MP",
	model			= "U6MP",
	fw				= {
		pre			= "U6MP.",
		ver			= "8.8.14.20179",	-- format M.m.p.build -- bare, see header
		buildtime	= "261030.1304",	-- format YYMMDD.HHMM (the catalog tag's build stamp)
		factoryver	= "7.0.53"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version (as u6iw)
}

return uap
