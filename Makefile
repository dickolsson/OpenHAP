.PHONY: all build check clean clean-man deps deps-develop deps-test install install-man integration lint man package prettier prettier-fix spec-coverage test tidy tidy-fix uninstall upgrade vm-provision vm-up web web-clean

# Filesystem configuration
PREFIX			?= /usr/local
BINDIR			?= $(PREFIX)/bin
LIBDIR			?= $(PREFIX)/libdata/perl5/site_perl
SHAREDIR		?= $(PREFIX)/share
MANDIR			?= $(PREFIX)/man
SYSCONFDIR		?= /etc
LOCALSTATEDIR	?= /var

# Build configuration
BUILD			= $(shell git rev-list --count HEAD)
TAG				?= b$(BUILD)
PACKAGE			= openhap-$(TAG)
TARBALL			= $(PACKAGE).tar.gz

# GitHub configuration
GITHUB_OWNER	?= dickolsson
GITHUB_REPO		?= openhap
GITHUB_RELEASE	= https://github.com/$(GITHUB_OWNER)/$(GITHUB_REPO)/releases/download/$(TAG)/$(TARBALL)

# Build tools.  mandoc renders the cat pages of the man target;
# fuguweb runs its own renderers and needs no variable here.
MANDOC			?= mandoc
PERLTIDY		= perl -MPerl::Tidy -e 'Perl::Tidy::perltidy()'
# Pin the version so that local runs and CI agree on formatting
PRETTIER		= npx prettier@3.9.6

# Every Perl source in the tree: modules by extension, executables by
# shebang.  Files in bin/ and scripts/ carry no extension, because a
# tool's name does not encode its language.  Thus the shebang identifies
# them.  Perl::Critic selects files the same way.  lint and tidy
# therefore cover the same set, with no list to keep true.
PERLSRC			= find lib bin scripts -type f \( -name '*.pm' -o \
			  -exec sh -c 'head -1 "$$1" | grep -q "^\#!.*perl"' \
			  _ {} \; \) -print

# OS detection
UNAME			!= uname
FTP				= scripts/ftp
DEPS			= scripts/deps

# Man pages
MAN5			= man/openhap/openhapd.conf.5
MAN8			= man/openhap/hapctl.8 man/openhap/openhapd.8
CATMAN5			= $(MAN5:.5=.cat5)
CATMAN8			= $(MAN8:.8=.cat8)

# Website.  .fuguwebrc describes it, and the installed fuguweb builds
# it (make deps-develop installs it).  WEBOUT stays because
# t/web/site.t and .github/workflows/web.yml both set it.
WEBOUT			?= web/build
FUGUWEB			?= fuguweb

all: deps check

build: package

# prettier stays out of check: it runs through npx, and no deps/
# manifest provides node. CI runs it in its own job.
check: lint test tidy spec-coverage

clean: clean-man web-clean
	rm -rf build
	rm -f *.tmp

clean-man:
	rm -f $(CATMAN5) $(CATMAN8)

deps:
	$(DEPS) runtime

deps-develop: deps deps-test
	$(DEPS) develop

deps-test: deps
	$(DEPS) test

install: install-man
	# Install binaries
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 bin/openhapd $(DESTDIR)$(BINDIR)/openhapd
	install -m 755 bin/hapctl $(DESTDIR)$(BINDIR)/hapctl
	# Install Perl libraries.  App/ is a shared parent: other
	# distributions live there too, so it is created, never removed
	install -d $(DESTDIR)$(LIBDIR)/App
	install -d $(DESTDIR)$(LIBDIR)/App/OpenHAP
	install -d $(DESTDIR)$(LIBDIR)/App/OpenHAP/Tasmota
	install -d $(DESTDIR)$(LIBDIR)/App/OpenHAP/Test
	install -m 644 lib/App/OpenHAP/*.pm $(DESTDIR)$(LIBDIR)/App/OpenHAP/
	install -m 644 lib/App/OpenHAP/*.pod $(DESTDIR)$(LIBDIR)/App/OpenHAP/
	install -m 644 lib/App/OpenHAP/Tasmota/*.pm $(DESTDIR)$(LIBDIR)/App/OpenHAP/Tasmota/
	install -m 644 lib/App/OpenHAP/Tasmota/*.pod $(DESTDIR)$(LIBDIR)/App/OpenHAP/Tasmota/
	# The glob loops accept zero, one, or many matches without stderr
	# noise, because the test helper modules are not always present
	for f in lib/App/OpenHAP/Test/*.pm lib/App/OpenHAP/Test/*.pod; do \
		[ -e "$$f" ] || continue; \
		install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/App/OpenHAP/Test/; \
	done
	# The Protocol::HAP library
	install -d $(DESTDIR)$(LIBDIR)/Protocol
	install -d $(DESTDIR)$(LIBDIR)/Protocol/HAP
	install -m 644 lib/Protocol/*.pm lib/Protocol/*.pod $(DESTDIR)$(LIBDIR)/Protocol/
	install -m 644 lib/Protocol/HAP/*.pm $(DESTDIR)$(LIBDIR)/Protocol/HAP/
	install -m 644 lib/Protocol/HAP/*.pod $(DESTDIR)$(LIBDIR)/Protocol/HAP/
	install -d $(DESTDIR)$(LIBDIR)/Protocol/HAP/Store
	install -m 644 lib/Protocol/HAP/Store/*.pm lib/Protocol/HAP/Store/*.pod \
	    $(DESTDIR)$(LIBDIR)/Protocol/HAP/Store/
	# Install rc.d script
	install -d $(DESTDIR)$(SYSCONFDIR)/rc.d
	install -m 755 etc/rc.d/openhapd $(DESTDIR)$(SYSCONFDIR)/rc.d/openhapd
	# Install example configuration
	install -d $(DESTDIR)$(SYSCONFDIR)/examples
	install -m 644 share/openhap/examples/openhapd.conf.sample $(DESTDIR)$(SYSCONFDIR)/examples/openhapd.conf
	# Create data directory
	install -d -m 700 $(DESTDIR)$(LOCALSTATEDIR)/db/openhapd

install-man:
	# Install man pages
	install -d $(DESTDIR)$(MANDIR)/man5
	install -d $(DESTDIR)$(MANDIR)/man8
	install -m 644 $(MAN5) $(DESTDIR)$(MANDIR)/man5/
	install -m 644 $(MAN8) $(DESTDIR)$(MANDIR)/man8/

integration: vm-provision
	@./scripts/integration

lint:
	@$(PERLSRC) | xargs perl -MPerl::Critic::Command -e 'Perl::Critic::Command::run()' -- --severity 4 --verbose 8

man: $(CATMAN5) $(CATMAN8)

prettier:
	@$(PRETTIER) --check --no-error-on-unmatched-pattern '**/*.md' '**/*.json' '**/*.yml' || { echo "Run 'make prettier-fix' to fix formatting"; exit 1; }

prettier-fix:
	$(PRETTIER) --write --no-error-on-unmatched-pattern '**/*.md' '**/*.json' '**/*.yml'

spec-coverage:
	@./scripts/spec-coverage --quiet

%.cat5: %.5
	$(MANDOC) -Tascii $< > $@

%.cat8: %.8
	$(MANDOC) -Tascii $< > $@

package: clean
	mkdir -p build/$(PACKAGE)/bin
	mkdir -p build/$(PACKAGE)/lib/App/OpenHAP/Tasmota
	mkdir -p build/$(PACKAGE)/lib/App/OpenHAP/Test
	mkdir -p build/$(PACKAGE)/lib/Protocol/HAP
	mkdir -p build/$(PACKAGE)/etc/rc.d
	mkdir -p build/$(PACKAGE)/share/openhap/examples
	mkdir -p build/$(PACKAGE)/man/openhap
	mkdir -p build/$(PACKAGE)/scripts
	mkdir -p build/$(PACKAGE)/deps
	# Binaries
	cp bin/openhapd bin/hapctl build/$(PACKAGE)/bin/
	# Perl libraries
	cp lib/App/OpenHAP/*.pm lib/App/OpenHAP/*.pod build/$(PACKAGE)/lib/App/OpenHAP/
	cp lib/App/OpenHAP/Tasmota/*.pm lib/App/OpenHAP/Tasmota/*.pod build/$(PACKAGE)/lib/App/OpenHAP/Tasmota/
	cp lib/App/OpenHAP/Test/*.pm lib/App/OpenHAP/Test/*.pod build/$(PACKAGE)/lib/App/OpenHAP/Test/
	cp lib/Protocol/*.pm lib/Protocol/*.pod build/$(PACKAGE)/lib/Protocol/
	cp lib/Protocol/HAP/*.pm lib/Protocol/HAP/*.pod build/$(PACKAGE)/lib/Protocol/HAP/
	mkdir -p build/$(PACKAGE)/lib/Protocol/HAP/Store
	cp lib/Protocol/HAP/Store/*.pm lib/Protocol/HAP/Store/*.pod \
	    build/$(PACKAGE)/lib/Protocol/HAP/Store/
	# rc.d script
	cp etc/rc.d/openhapd build/$(PACKAGE)/etc/rc.d/
	# Example configuration
	cp share/openhap/examples/openhapd.conf.sample build/$(PACKAGE)/share/openhap/examples/
	# Man pages
	cp $(MAN5) $(MAN8) build/$(PACKAGE)/man/openhap/
	# Scripts for dependency management
	cp scripts/ftp scripts/deps build/$(PACKAGE)/scripts/
	chmod +x build/$(PACKAGE)/scripts/*
	# Dependency files
	cp deps/*.txt build/$(PACKAGE)/deps/
	# Makefile and cpanfile for installation
	cp Makefile cpanfile build/$(PACKAGE)/
	# Documentation
	cp README.md INSTALL.md LICENSE build/$(PACKAGE)/
	cd build && tar -czvf $(TARBALL) $(PACKAGE)
	rm -rf build/$(PACKAGE)

test:
	prove -l -v t/protocol/*.t
	prove -l -v t/openhap/*.t
	prove -l -v t/conformance/*.t
	prove -l -v t/scripts/*.t
	prove -l -v t/web/*.t
	prove -l -v t/ci/*.t

tidy:
	@$(PERLSRC) | while read f; do \
		$(PERLTIDY) -- --standard-output "$$f" | diff -q "$$f" - >/dev/null 2>&1 || echo "$$f"; \
	done | grep . && echo "Run 'make tidy-fix' to fix formatting" && exit 1 || echo "All files formatted correctly"

tidy-fix:
	@$(PERLSRC) | while read f; do \
		$(PERLTIDY) -- -b -bext='/' "$$f"; \
	done

uninstall:
	# Remove binaries
	rm -f $(DESTDIR)$(BINDIR)/openhapd
	rm -f $(DESTDIR)$(BINDIR)/hapctl
	# Remove Perl libraries.  App/ and Protocol/ are shared parents:
	# App::cpanminus and any other Protocol:: distribution live
	# beside ours.  Remove what this project owns, then rmdir the
	# parent, which fails harmlessly when it still holds something
	rm -rf $(DESTDIR)$(LIBDIR)/App/OpenHAP
	rm -rf $(DESTDIR)$(LIBDIR)/Protocol/HAP
	# The loop derives the list from the source tree.  A new
	# top-level Protocol:: module is thus removed with no second
	# place to keep true
	for f in lib/Protocol/*.pm lib/Protocol/*.pod; do \
		rm -f "$(DESTDIR)$(LIBDIR)/Protocol/$${f##*/}"; \
	done
	-rmdir $(DESTDIR)$(LIBDIR)/App 2>/dev/null
	-rmdir $(DESTDIR)$(LIBDIR)/Protocol 2>/dev/null
	# Remove man pages
	rm -f $(DESTDIR)$(MANDIR)/man5/openhapd.conf.5
	rm -f $(DESTDIR)$(MANDIR)/man8/openhapd.8
	rm -f $(DESTDIR)$(MANDIR)/man8/hapctl.8
	# Remove rc.d script
	rm -f $(DESTDIR)$(SYSCONFDIR)/rc.d/openhapd
	# Remove example configuration
	rm -f $(DESTDIR)$(SYSCONFDIR)/examples/openhapd.conf
	# Note: the uninstall keeps /etc/openhapd.conf and /var/db/openhapd

upgrade:
	@echo "==> Downloading $(TARBALL)"
	$(FTP) ../$(TARBALL) $(GITHUB_RELEASE)
	cd .. && tar -xzf $(TARBALL)
	@echo "==> Upgrade by running:\n    make uninstall\n    cd ../$(PACKAGE)\n    make install"

vm-provision: vm-up
	@./scripts/vm-provision

vm-up:
	@./scripts/vm-up

web:
	@$(FUGUWEB) build --out $(WEBOUT)

# A tree without the installed fuguweb falls back to a plain removal.
# fuguweb refuses a directory that no build made; the fallback is only
# reached where there is no site to protect.
web-clean:
	@if command -v $(FUGUWEB) >/dev/null 2>&1; then \
		$(FUGUWEB) clean --out $(WEBOUT); \
	else \
		rm -rf $(WEBOUT); \
	fi
