#
# Copyright (C) 2026 Yesrab Ali <yesrab.ali111@gmail.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# openuf-crypto: the two AES primitives openUF's inform channel needs
# (AES-128-CBC and AES-128-GCM), as a Lua 5.1 C module, one source compiled
# against whichever TLS library the box already has. OpenWrt's default
# hostapd is wpad-basic-mbedtls, so the mbedtls variant is the default
# provider; the wolfssl and openssl variants exist so a box built on one of
# those does not get a second TLS library for 20 KB of module. The fourth
# variant, openuf-crypto-luaossl, carries no code at all: it is the
# arch-independent provider for a target this feed ships no build for, and
# it simply depends on lua-openssl (the binding openUF used before).
#
# All four PROVIDE "openuf-crypto", which is what the openuf package depends
# on. The package manager settles the variant: an installed one is kept, the
# default is taken otherwise, and `openuf deps --install` swaps to the one
# matching the installed hostapd when that differs.

include $(TOPDIR)/rules.mk

PKG_NAME:=openuf-crypto
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Yesrab Ali <yesrab.ali111@gmail.com>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/openuf-crypto/default
  SECTION:=lang
  CATEGORY:=Languages
  SUBMENU:=Lua
  TITLE:=AES-128 CBC/GCM for openUF
  URL:=https://github.com/yesrab/openUF
  PROVIDES:=openuf-crypto
  DEPENDS:=+liblua
endef

define Package/openuf-crypto/default/description
  The AES-128-CBC and AES-128-GCM primitives openUF encrypts its inform
  channel with, as the Lua module "openuf_crypto". One source, built
  against the TLS library named in the variant, so no second library is
  installed beside the one hostapd already uses.
endef

define Package/openuf-crypto-openssl
  $(Package/openuf-crypto/default)
  TITLE += (openssl)
  DEPENDS += +PACKAGE_openuf-crypto-openssl:libopenssl
  VARIANT:=openssl
endef
Package/openuf-crypto-openssl/description = $(Package/openuf-crypto/default/description)

define Package/openuf-crypto-wolfssl
  $(Package/openuf-crypto/default)
  TITLE += (wolfssl)
  DEPENDS += +PACKAGE_openuf-crypto-wolfssl:libwolfssl
  CONFLICTS:=openuf-crypto-openssl
  VARIANT:=wolfssl
endef
Package/openuf-crypto-wolfssl/description = $(Package/openuf-crypto/default/description)

define Package/openuf-crypto-mbedtls
  $(Package/openuf-crypto/default)
  TITLE += (mbedtls)
  DEPENDS += +PACKAGE_openuf-crypto-mbedtls:libmbedtls
  CONFLICTS:=openuf-crypto-openssl openuf-crypto-wolfssl
  VARIANT:=mbedtls
  DEFAULT_VARIANT:=1
endef
Package/openuf-crypto-mbedtls/description = $(Package/openuf-crypto/default/description)

define Package/openuf-crypto-luaossl
  $(Package/openuf-crypto/default)
  TITLE += (via lua-openssl, no native module)
  DEPENDS += +lua-openssl
  CONFLICTS:=openuf-crypto-openssl openuf-crypto-wolfssl openuf-crypto-mbedtls
  VARIANT:=luaossl
  PKGARCH:=all
endef

define Package/openuf-crypto-luaossl/description
  Provides openuf-crypto through the lua-openssl binding instead of the
  native module: for a target this feed ships no openuf_crypto build for.
  openUF's crypto.lua falls back to lua-openssl on its own, so this
  package carries no files, only the dependency.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

TARGET_CFLAGS += $(FPIC) -std=gnu99 -Wall -Wextra

ifeq ($(BUILD_VARIANT),mbedtls)
  OPENUF_CRYPTO_DEFINE:=-DOPENUF_CRYPTO_MBEDTLS
  OPENUF_CRYPTO_LIBS:=-lmbedcrypto
endif
ifeq ($(BUILD_VARIANT),wolfssl)
  OPENUF_CRYPTO_DEFINE:=-DOPENUF_CRYPTO_WOLFSSL
  OPENUF_CRYPTO_LIBS:=-lwolfssl
endif
ifeq ($(BUILD_VARIANT),openssl)
  OPENUF_CRYPTO_DEFINE:=-DOPENUF_CRYPTO_OPENSSL
  OPENUF_CRYPTO_LIBS:=-lcrypto
endif

ifeq ($(BUILD_VARIANT),luaossl)
define Build/Compile
endef
else
define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) $(OPENUF_CRYPTO_DEFINE) -shared \
		-o $(PKG_BUILD_DIR)/openuf_crypto.so $(PKG_BUILD_DIR)/openuf_crypto.c \
		$(TARGET_LDFLAGS) $(OPENUF_CRYPTO_LIBS)
endef
endif

define Package/openuf-crypto/default/install
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf_crypto.so $(1)/usr/lib/lua/
endef
Package/openuf-crypto-mbedtls/install = $(Package/openuf-crypto/default/install)
Package/openuf-crypto-wolfssl/install = $(Package/openuf-crypto/default/install)
Package/openuf-crypto-openssl/install = $(Package/openuf-crypto/default/install)

define Package/openuf-crypto-luaossl/install
	true
endef

$(eval $(call BuildPackage,openuf-crypto-mbedtls))
$(eval $(call BuildPackage,openuf-crypto-wolfssl))
$(eval $(call BuildPackage,openuf-crypto-openssl))
$(eval $(call BuildPackage,openuf-crypto-luaossl))
