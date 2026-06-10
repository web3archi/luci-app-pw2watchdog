include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pw2watchdog
PKG_VERSION:=0.3.8
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

# ─── Version bump helper ──────────────────────────────────────────────
# Usage: make bump VERSION=v0.3.9
# Updates every PW2WD_VERSION anchor across the repo and the
# PKG_VERSION in this Makefile (PKG_VERSION carries no leading 'v').
.PHONY: bump
bump:
	@if [ -z "$(VERSION)" ]; then \
		echo 'usage: make bump VERSION=vX.Y.Z'; exit 1; \
	fi
	@case "$(VERSION)" in \
		v[0-9]*) : ;; \
		*) echo 'VERSION must look like vX.Y.Z'; exit 1 ;; \
	esac
	@VER='$(VERSION)'; PKGVER=$${VER#v}; \
	echo "Bumping to $$VER (PKG_VERSION=$$PKGVER)"; \
	sed -i.bak -E "s/^PKG_VERSION:=.*/PKG_VERSION:=$$PKGVER/" Makefile; \
	grep -rEl '# PW2WD_VERSION:[[:space:]]*v[0-9]' root \
		| xargs -r sed -i.bak -E "s/^# PW2WD_VERSION:[[:space:]]*v[0-9].*/# PW2WD_VERSION: $$VER/"; \
	grep -rEl 'PW2WD_VERSION="v[0-9]' root \
		| xargs -r sed -i.bak -E "s/^PW2WD_VERSION=\"v[0-9][^\"]*\"/PW2WD_VERSION=\"$$VER\"/"; \
	grep -rEl "PW2WD_VERSION = 'v[0-9]" luasrc \
		| xargs -r sed -i.bak -E "s/PW2WD_VERSION = 'v[0-9][^']*'/PW2WD_VERSION = '$$VER'/"; \
	find . -name '*.bak' -delete; \
	echo 'Done. Verify with: make show-version'

.PHONY: show-version
show-version:
	@echo "Makefile PKG_VERSION:"; grep -E '^PKG_VERSION:=' Makefile
	@echo; echo "PW2WD_VERSION anchors:"
	@grep -rEn 'PW2WD_VERSION' Makefile root luasrc 2>/dev/null \
		| grep -E 'v[0-9]+\.[0-9]+\.[0-9]+' || true
