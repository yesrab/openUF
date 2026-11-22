--[[
	JioRouter AX6000 JIDU6J11 family hardware profile.

	Qualcomm IPQ9554 / qualcommbe-ipq95xx, with two ath11k radios. The
	community snapshot reports jiorouter,ax6000-jidu6j11. The six SKU
	DTS files in OpenWrt PR #26498 have distinct compatibles but share
	ipq9554-jiorouter-ax6000-jidu6j11.dtsi and the same 02_network layout:
	https://github.com/openwrt/openwrt/pull/26498

	Verified on a running JIDU6J11 snapshot: br-lan, all five netdevs,
	radio0 = 2.4 GHz, radio1 = 5 GHz, and the status LED aliases. Port
	indices follow the DTS labels. Individual SKU hardware and controller
	provisioning have not been tested with this profile.
]]--

local dev = {}

-- Keep the compatibles on one line for setup.sh's map_boards().
dev.openwrt_boards = {"jiorouter,ax6000-jidu6j11", "jiorouter,ax6000-jidu6111", "jiorouter,ax6000-jidu6411", "jiorouter,ax6000-jidu6611", "jiorouter,ax6000-jidu6711", "jiorouter,ax6000-jidu6811", "jiorouter,ax6000-jidu6911"}

dev.conf = {
	net = {
		lan_name = "lan",
		-- The management address, adoption MAC and VLAN trunk use the bridge.
		lan_cpueth = "br-lan",
		lan_vlanid = 1,
		wan_cpueth = "wan",
		ports = {
			{idx = 1, ifname = "lan1"},
			{idx = 2, ifname = "lan2"},
			{idx = 3, ifname = "lan3"},
			{idx = 4, ifname = "lan4"},
			{idx = 5, ifname = "wan"},
		},
		uplink_detect = "fdb",
	},
	-- OpenWrt assigns red to boot/failsafe, green to running, and blue to
	-- upgrade. Leave Locate disabled so it does not take over a system LED.
}

dev.openuf = {
	uap = {
		ufmodel = "u6iw",
		hwassign = {"radio0", "radio1"},
	},
}

return dev
