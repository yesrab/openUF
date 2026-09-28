#
# Copyright (C) 2026 Yesrab Ali <yesrab.ali111@gmail.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for openUF (UniFi AP emulation)
LUCI_DESCRIPTION:=Overview, settings and log for openUF: adoption state, the hardware profile and UniFi identity in use, and the runtime options in /etc/config/openuf.
LUCI_DEPENDS:=+luci-base +openuf
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/yesrab/openUF

PKG_VERSION:=0.9.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Yesrab Ali <yesrab.ali111@gmail.com>

# Inside openwrt/luci this is ../../luci.mk; from any other feed, the luci
# feed's copy.
include $(if $(wildcard ../../luci.mk),../../luci.mk,$(TOPDIR)/feeds/luci/luci.mk)

# call BuildPackage - OpenWrt buildroot signature
