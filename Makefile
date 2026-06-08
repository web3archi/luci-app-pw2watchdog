include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pw2watchdog
PKG_VERSION:=0.3.0
PKG_RELEASE:=1

PKG_MAINTAINER:=eb3archi
PKG_LICENSE:=MIT

LUCI_TITLE:=PassWall2 Watchdog
LUCI_DESCRIPTION:=LuCI application for automatic PassWall2 node monitoring and switching. \
	Measures latency for candidate nodes, switches to the best available node, \
	and activates a configurable fallback policy when all nodes fail.
LUCI_DEPENDS:=+luci-base +luci-app-passwall2

include $(TOPDIR)/feeds/luci/luci.mk

# Install shell scripts with executable bit
define Package/$(PKG_NAME)/install
	$(call Package/$(PKG_NAME)/install/default,$(1))
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/pw2watchdog.sh           $(1)/usr/bin/pw2watchdog.sh
	$(INSTALL_BIN) ./root/usr/bin/pw2watchdog-scanner.sh   $(1)/usr/bin/pw2watchdog-scanner.sh
	$(INSTALL_BIN) ./root/usr/bin/pw2watchdog-env.sh       $(1)/usr/bin/pw2watchdog-env.sh
	$(INSTALL_BIN) ./root/usr/bin/pw2watchdog-subscribe.sh $(1)/usr/bin/pw2watchdog-subscribe.sh
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/pw2watchdog           $(1)/etc/init.d/pw2watchdog
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-pw2watchdog  $(1)/etc/uci-defaults/99-pw2watchdog
endef

# $(eval $(call BuildPackage,$(PKG_NAME)))
