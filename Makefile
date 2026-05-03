.PHONY: install uninstall reinstall install-conf man clean test test-root

PREFIX     = /usr
SYSCONFDIR = /etc
DESTDIR    =
pkgname    = atomic-upgrade

BINDIR       = $(PREFIX)/bin
LIBDIR       = $(PREFIX)/lib/atomic
SHAREDIR     = $(PREFIX)/share
MANDIR       = $(SHAREDIR)/man
ZSH_COMPDIR  = $(SHAREDIR)/zsh/site-functions
BASH_COMPDIR = $(SHAREDIR)/bash-completion/completions
HOOKSDIR     = $(SHAREDIR)/libalpm/hooks
LICENSEDIR   = $(SHAREDIR)/licenses/$(pkgname)

MANPAGES = man/atomic-upgrade.8 man/atomic-gc.8 man/atomic.conf.5

# Generate groff from markdown (requires pandoc, run locally)
man: $(MANPAGES)

man/%.8: man/%.8.md
	pandoc -s -t man -o $@ $<

man/%.5: man/%.5.md
	pandoc -s -t man -o $@ $<

clean:
	rm -f $(MANPAGES)

UNIT_TESTS = \
	tests/test_validate.sh \
	tests/test_device.sh \
	tests/test_space.sh \
	tests/test_chroot.sh \
	tests/test_gc.sh \
	tests/test_uki.sh \
	tests/test_home.sh \
	tests/test_upgrade.sh \
	tests/test_upgrade_flow.sh \
	tests/test_rebuild_uki.sh \
	tests/test_rebuild_uki_flow.sh \
	tests/test_atomic_gc.sh

test:
	@for t in $(UNIT_TESTS); do \
		echo ""; \
		echo "━━━ $$t ━━━"; \
		bash "$$t" || exit 1; \
	done
	@echo ""
	@echo "━━━ tests/test_integration.sh ━━━"
	bash tests/test_integration.sh
	python -m pytest tests/test_fstab.py -v
	python -m pytest tests/test_rootdev.py -v
	python -m pytest tests/test_config.py -v

ROOT_TESTS = \
	tests/test_config.py::TestParseConfig::test_config_not_owned_by_root

test-root:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "SKIP: test-root requires root (run: sudo make test-root)"; \
	else \
		for t in $(ROOT_TESTS); do \
			echo ""; \
			echo "━━━ $$t ━━━"; \
			python -m pytest "$$t" -v || exit 1; \
		done; \
	fi

install:
	install -Dm755 bin/atomic-upgrade     $(DESTDIR)$(BINDIR)/atomic-upgrade
	install -Dm755 bin/atomic-gc          $(DESTDIR)$(BINDIR)/atomic-gc
	install -Dm755 bin/atomic-guard       $(DESTDIR)$(BINDIR)/atomic-guard
	install -Dm755 bin/atomic-rebuild-uki $(DESTDIR)$(BINDIR)/atomic-rebuild-uki

	install -Dm644 lib/atomic/common.sh  $(DESTDIR)$(LIBDIR)/common.sh
	install -Dm755 lib/atomic/config.py   $(DESTDIR)$(LIBDIR)/config.py
	install -Dm755 lib/atomic/fstab.py   $(DESTDIR)$(LIBDIR)/fstab.py
	install -Dm755 lib/atomic/rootdev.py $(DESTDIR)$(LIBDIR)/rootdev.py

	install -Dm644 completions/_atomic-gc \
		$(DESTDIR)$(ZSH_COMPDIR)/_atomic-gc
	install -Dm644 completions/_atomic-rebuild-uki \
		$(DESTDIR)$(ZSH_COMPDIR)/_atomic-rebuild-uki
	install -Dm644 completions/_atomic-upgrade \
		$(DESTDIR)$(ZSH_COMPDIR)/_atomic-upgrade
	install -Dm644 completions/atomic-gc.bash \
		$(DESTDIR)$(BASH_COMPDIR)/atomic-gc
	install -Dm644 completions/atomic-rebuild-uki.bash \
		$(DESTDIR)$(BASH_COMPDIR)/atomic-rebuild-uki
	install -Dm644 completions/atomic-upgrade.bash \
		$(DESTDIR)$(BASH_COMPDIR)/atomic-upgrade

	install -Dm644 hooks/00-block-direct-upgrade.hook \
		$(DESTDIR)$(HOOKSDIR)/00-block-direct-upgrade.hook

	install -Dm755 extras/pacman-wrapper $(DESTDIR)$(PREFIX)/local/bin/pacman

	install -Dm644 man/atomic-upgrade.8 $(DESTDIR)$(MANDIR)/man8/atomic-upgrade.8
	install -Dm644 man/atomic-gc.8      $(DESTDIR)$(MANDIR)/man8/atomic-gc.8
	install -Dm644 man/atomic.conf.5    $(DESTDIR)$(MANDIR)/man5/atomic.conf.5
	ln -sf atomic-upgrade.8 $(DESTDIR)$(MANDIR)/man8/atomic-rebuild-uki.8

	install -Dm644 LICENSE $(DESTDIR)$(LICENSEDIR)/LICENSE

	@if [ ! -f "$(DESTDIR)$(SYSCONFDIR)/atomic.conf" ]; then \
		install -Dm644 etc/atomic.conf "$(DESTDIR)$(SYSCONFDIR)/atomic.conf"; \
		echo "Installed default config"; \
	else \
		echo "Config exists, skipping (see etc/atomic.conf for defaults)"; \
	fi

uninstall:
	rm -f  $(DESTDIR)$(BINDIR)/atomic-upgrade
	rm -f  $(DESTDIR)$(BINDIR)/atomic-gc
	rm -f  $(DESTDIR)$(BINDIR)/atomic-guard
	rm -f  $(DESTDIR)$(BINDIR)/atomic-rebuild-uki
	rm -f  $(DESTDIR)$(LIBDIR)/config.py
	rm -rf $(DESTDIR)$(LIBDIR)/
	rm -f  $(DESTDIR)$(ZSH_COMPDIR)/_atomic-gc
	rm -f  $(DESTDIR)$(ZSH_COMPDIR)/_atomic-rebuild-uki
	rm -f  $(DESTDIR)$(ZSH_COMPDIR)/_atomic-upgrade
	rm -f  $(DESTDIR)$(BASH_COMPDIR)/atomic-gc
	rm -f  $(DESTDIR)$(BASH_COMPDIR)/atomic-rebuild-uki
	rm -f  $(DESTDIR)$(BASH_COMPDIR)/atomic-upgrade
	rm -f  $(DESTDIR)$(HOOKSDIR)/00-block-direct-upgrade.hook
	rm -f  $(DESTDIR)$(PREFIX)/local/bin/pacman
	rm -f  $(DESTDIR)$(MANDIR)/man8/atomic-upgrade.8
	rm -f  $(DESTDIR)$(MANDIR)/man8/atomic-gc.8
	rm -f  $(DESTDIR)$(MANDIR)/man8/atomic-rebuild-uki.8
	rm -f  $(DESTDIR)$(MANDIR)/man5/atomic.conf.5
	rm -rf $(DESTDIR)$(LICENSEDIR)/
	@echo "Note: $(SYSCONFDIR)/atomic.conf preserved. Remove manually if needed."

reinstall: uninstall install

install-conf:
	install -Dm644 etc/atomic.conf $(DESTDIR)$(SYSCONFDIR)/atomic.conf
	@echo "Config force-installed."
