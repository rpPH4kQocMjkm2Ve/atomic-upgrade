PREFIX = /usr
SYSCONFDIR = /etc

install:
	install -Dm755 bin/atomic-upgrade     $(DESTDIR)$(PREFIX)/bin/atomic-upgrade
	install -Dm755 bin/atomic-gc          $(DESTDIR)$(PREFIX)/bin/atomic-gc
	install -Dm755 bin/atomic-guard       $(DESTDIR)$(PREFIX)/bin/atomic-guard
	install -Dm755 bin/atomic-rebuild-uki $(DESTDIR)$(PREFIX)/bin/atomic-rebuild-uki
	install -Dm644 lib/atomic/common.sh   $(DESTDIR)$(PREFIX)/lib/atomic/common.sh
	install -Dm755 lib/atomic/fstab.py    $(DESTDIR)$(PREFIX)/lib/atomic/fstab.py
	install -Dm755 lib/atomic/rootdev.py  $(DESTDIR)$(PREFIX)/lib/atomic/rootdev.py
	install -Dm644 hooks/00-block-direct-upgrade.hook \
		$(DESTDIR)$(PREFIX)/share/libalpm/hooks/00-block-direct-upgrade.hook
	install -Dm644 etc/atomic.conf $(DESTDIR)$(SYSCONFDIR)/atomic.conf
	install -Dm755 extras/pacman-wrapper $(DESTDIR)$(PREFIX)/local/bin/pacman
	install -Dm644 LICENSE $(DESTDIR)/usr/share/licenses/$(pkgname)/LICENSE

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-upgrade
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-gc
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-guard
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-rebuild-uki
	rm -rf $(DESTDIR)$(PREFIX)/lib/atomic/
	rm -f $(DESTDIR)$(PREFIX)/share/libalpm/hooks/00-block-direct-upgrade.hook
	rm -f $(DESTDIR)$(PREFIX)/local/bin/pacman
	rm -rf $(DESTDIR)$(PREFIX)/share/licenses/$(pkgname)
	@echo "Note: /etc/atomic.conf preserved. Remove manually if needed."
