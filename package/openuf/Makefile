#
# Copyright (C) 2026 Yesrab Ali <yesrab.ali111@gmail.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=openuf
PKG_VERSION:=0.9.0
PKG_RELEASE:=1

# The release archive tools/release-archive.sh produces from a tag: the
# comment-stripped tree tools/dist.sh --verify proved bytecode-identical to the
# source, under a single openuf-<version>/ directory. The release workflow
# substitutes PKG_VERSION and PKG_HASH from the tag it is building; a feed
# submission carries the real hash.
PKG_SOURCE:=openuf-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/yesrab/openUF/releases/download/v$(PKG_VERSION)/
PKG_HASH:=skip

PKG_MAINTAINER:=Yesrab Ali <yesrab.ali111@gmail.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/openuf
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Wireless
  TITLE:=UniFi access point emulation
  URL:=https://github.com/yesrab/openUF
  DEPENDS:=+lua +luabitop +lua-cjson +libuci-lua +lua-openssl +lldpd
  PKGARCH:=all
endef

define Package/openuf/description
  Makes an OpenWrt access point appear to a UniFi Network Application as a
  Ubiquiti AP (a U6-InWall by default): L2 and L3 adoption, controller-pushed
  SSID and radio settings, client, radio and port statistics.

  Configuration is /etc/config/openuf (a hardware profile from the shipped
  presets or a custom one, the identity to present, the inform URL). The web
  front end is luci-app-openuf.

  Optional features need packages this one does not depend on, since each is
  larger than openUF itself: nftables and kmod-nft-bridge (client blocking,
  the broadcast filter, L2 hardening), tc-tiny and kmod-sched-act-police
  (WiFi speed limits), usteer and a full wpad build (band steering, roaming
  assistant). openUF logs which are missing.
endef

define Package/openuf/conffiles
/etc/config/openuf
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/openuf/install
	$(INSTALL_DIR) $(1)/usr/lib/openuf
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/*.lua $(1)/usr/lib/openuf/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/BUILD $(1)/usr/lib/openuf/
	echo "$(PKG_VERSION)" > $(1)/usr/lib/openuf/VERSION
	$(INSTALL_DIR) $(1)/usr/lib/openuf/lib
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/lib/*.lua $(1)/usr/lib/openuf/lib/
	$(INSTALL_DIR) $(1)/usr/lib/openuf/modelmap
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/modelmap/*.lua $(1)/usr/lib/openuf/modelmap/
	$(INSTALL_DIR) $(1)/usr/lib/openuf/ufmodel
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/ufmodel/*.lua $(1)/usr/lib/openuf/ufmodel/
	$(INSTALL_DIR) $(1)/usr/lib/openuf/hook
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/hook/*.lua $(1)/usr/lib/openuf/hook/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf/hook/*.sh $(1)/usr/lib/openuf/hook/
	$(INSTALL_DIR) $(1)/usr/bin
	$(LN) ../lib/openuf/hook/syswrapper.sh $(1)/usr/bin/syswrapper.sh
	$(LN) ../lib/openuf/hook/openuf-cli.sh $(1)/usr/bin/openuf
	$(INSTALL_DIR) $(1)/usr/sbin
	$(LN) ../lib/openuf/hook/openuf-convert.sh $(1)/usr/sbin/openuf-convert
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf/etc/init.d/openuf $(1)/etc/init.d/openuf
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/openuf.config $(1)/etc/config/openuf
	$(INSTALL_DIR) $(1)/etc/openuf
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/openuf.upgrade $(1)/lib/upgrade/keep.d/openuf
endef

$(eval $(call BuildPackage,openuf))
