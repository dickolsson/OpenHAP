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

# Build tools
LOWDOWN			?= lowdown
MANDOC			?= mandoc
POD2MAN			?= pod2man
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

# Man pages.  FuguLib sources drop the FuguLib:: prefix because a colon
# cannot appear in a make target.  install-man puts it back.
MAN1			= man/fuguvm/fuguvm.1
MAN3P			= man/fugulib/CLI.3p man/fugulib/Config.3p \
			  man/fugulib/Control.3p man/fugulib/Daemon.3p \
			  man/fugulib/EventLoop.3p man/fugulib/File.3p \
			  man/fugulib/Imsg.3p \
			  man/fugulib/JSONSocket.3p man/fugulib/Log.3p \
			  man/fugulib/MDNS.3p man/fugulib/MQTT.3p \
			  man/fugulib/Pidfile.3p man/fugulib/Privdrop.3p \
			  man/fugulib/Process.3p man/fugulib/Proxy.3p \
			  man/fugulib/Random.3p man/fugulib/SSH.3p \
			  man/fugulib/Sandbox.3p man/fugulib/Signal.3p \
			  man/fugulib/Store.3p man/fugulib/Util.3p
MAN5			= man/openhap/openhapd.conf.5
MAN8			= man/openhap/hapctl.8 man/openhap/openhapd.8
CATMAN1			= $(MAN1:.1=.cat1)
CATMAN3P		= $(MAN3P:.3p=.cat3p)
CATMAN5			= $(MAN5:.5=.cat5)
CATMAN8			= $(MAN8:.8=.cat8)

# Website
WEBOUT			?= web/build
WEBMAN			= $(WEBOUT)/.man
MKPAGE			= web/mkpage.sh
MKINDEX			= web/mkindex.sh
# The Makefile finds the .pod sidecars and never lists them.  Otherwise
# a sidecar without its own Makefile line would never reach the site.
# An exclusion list would be one more thing to keep true.  LC_ALL=C
# makes sure the order of the index does not depend on the builder's
# locale.
FINDPOD			= find lib -name '*.pod' | LC_ALL=C sort
# mandoc resolves .Xr against the working directory.  A page named %N.%S
# there becomes a local link.  Anything else goes to man.openbsd.org.
# The './' matters.  A module page is FuguLib::Daemon.3p.html.  The
# browser reads a relative URL whose first segment holds a colon as a
# scheme instead.
# -I os= pins the footer so the site does not vary with the build host.
MANHTML			= -Thtml -I os=OpenBSD \
			  -O fragment,man='./%N.%S.html;https://man.openbsd.org/%N.%S'

all: deps check

build: package

check: lint test tidy

clean: clean-man web-clean
	rm -rf build
	rm -f *.tmp

clean-man:
	rm -f $(CATMAN1) $(CATMAN3P) $(CATMAN5) $(CATMAN8)

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
	# Install Perl libraries
	install -d $(DESTDIR)$(LIBDIR)/OpenHAP
	install -d $(DESTDIR)$(LIBDIR)/OpenHAP/Tasmota
	install -d $(DESTDIR)$(LIBDIR)/OpenHAP/Test
	install -d $(DESTDIR)$(LIBDIR)/OpenHAP/Test/Controller
	install -d $(DESTDIR)$(LIBDIR)/FuguLib
	install -m 644 lib/OpenHAP/*.pm $(DESTDIR)$(LIBDIR)/OpenHAP/
	install -m 644 lib/OpenHAP/*.pod $(DESTDIR)$(LIBDIR)/OpenHAP/
	install -m 644 lib/OpenHAP/Tasmota/*.pm $(DESTDIR)$(LIBDIR)/OpenHAP/Tasmota/
	install -m 644 lib/OpenHAP/Tasmota/*.pod $(DESTDIR)$(LIBDIR)/OpenHAP/Tasmota/
	# The glob loops accept zero, one, or many matches without stderr
	# noise, because the test helper modules are not always present
	for f in lib/OpenHAP/Test/*.pm lib/OpenHAP/Test/*.pod; do \
		[ -e "$$f" ] || continue; \
		install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/OpenHAP/Test/; \
	done
	for f in lib/OpenHAP/Test/Controller/*.pm lib/OpenHAP/Test/Controller/*.pod; do \
		[ -e "$$f" ] || continue; \
		install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/OpenHAP/Test/Controller/; \
	done
	# FuguLib's API documentation lives in man3p, not in sidecars
	install -m 644 lib/FuguLib/*.pm $(DESTDIR)$(LIBDIR)/FuguLib/
	# The Protocol::HAP library. The Store/ loop accepts zero
	# matches, because the subdirectory arrives in a later phase
	install -d $(DESTDIR)$(LIBDIR)/Protocol
	install -d $(DESTDIR)$(LIBDIR)/Protocol/HAP
	install -m 644 lib/Protocol/*.pm lib/Protocol/*.pod $(DESTDIR)$(LIBDIR)/Protocol/
	install -m 644 lib/Protocol/HAP/*.pm $(DESTDIR)$(LIBDIR)/Protocol/HAP/
	install -m 644 lib/Protocol/HAP/*.pod $(DESTDIR)$(LIBDIR)/Protocol/HAP/
	for f in lib/Protocol/HAP/Store/*.pm lib/Protocol/HAP/Store/*.pod; do \
		[ -e "$$f" ] || continue; \
		install -d $(DESTDIR)$(LIBDIR)/Protocol/HAP/Store; \
		install -m 644 "$$f" $(DESTDIR)$(LIBDIR)/Protocol/HAP/Store/; \
	done
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
	install -d $(DESTDIR)$(MANDIR)/man3p
	install -d $(DESTDIR)$(MANDIR)/man5
	install -d $(DESTDIR)$(MANDIR)/man8
	# The rename cannot be a glob.  'man FuguLib::Daemon' looks for a
	# file of that name.  make cannot have that name as a target
	for f in $(MAN3P); do \
		install -m 644 "$$f" \
		    "$(DESTDIR)$(MANDIR)/man3p/FuguLib::$${f##*/}"; \
	done
	install -m 644 $(MAN5) $(DESTDIR)$(MANDIR)/man5/
	install -m 644 $(MAN8) $(DESTDIR)$(MANDIR)/man8/

integration: vm-provision
	@./scripts/integration

lint:
	@$(PERLSRC) | xargs perl -MPerl::Critic::Command -e 'Perl::Critic::Command::run()' -- --severity 4 --verbose 8

man: $(CATMAN1) $(CATMAN3P) $(CATMAN5) $(CATMAN8)

prettier:
	@$(PRETTIER) --check '**/*.md' '**/*.json' '**/*.yml' || { echo "Run 'make prettier-fix' to fix formatting"; exit 1; }

prettier-fix:
	$(PRETTIER) --write '**/*.md' '**/*.json' '**/*.yml'

spec-coverage:
	@./scripts/spec-coverage --quiet

%.cat1: %.1
	$(MANDOC) -Tascii $< > $@

%.cat3p: %.3p
	$(MANDOC) -Tascii $< > $@

%.cat5: %.5
	$(MANDOC) -Tascii $< > $@

%.cat8: %.8
	$(MANDOC) -Tascii $< > $@

package: clean
	mkdir -p build/$(PACKAGE)/bin
	mkdir -p build/$(PACKAGE)/lib/OpenHAP/Tasmota
	mkdir -p build/$(PACKAGE)/lib/OpenHAP/Test/Controller
	mkdir -p build/$(PACKAGE)/lib/FuguLib
	mkdir -p build/$(PACKAGE)/lib/Protocol/HAP
	mkdir -p build/$(PACKAGE)/etc/rc.d
	mkdir -p build/$(PACKAGE)/share/openhap/examples
	mkdir -p build/$(PACKAGE)/man/fugulib
	mkdir -p build/$(PACKAGE)/man/openhap
	mkdir -p build/$(PACKAGE)/scripts
	mkdir -p build/$(PACKAGE)/deps
	# Binaries
	cp bin/openhapd bin/hapctl build/$(PACKAGE)/bin/
	# Perl libraries
	cp lib/OpenHAP/*.pm lib/OpenHAP/*.pod build/$(PACKAGE)/lib/OpenHAP/
	cp lib/OpenHAP/Tasmota/*.pm lib/OpenHAP/Tasmota/*.pod build/$(PACKAGE)/lib/OpenHAP/Tasmota/
	cp lib/OpenHAP/Test/*.pm lib/OpenHAP/Test/*.pod build/$(PACKAGE)/lib/OpenHAP/Test/
	cp lib/OpenHAP/Test/Controller/*.pm lib/OpenHAP/Test/Controller/*.pod build/$(PACKAGE)/lib/OpenHAP/Test/Controller/
	cp lib/FuguLib/*.pm build/$(PACKAGE)/lib/FuguLib/
	cp lib/Protocol/*.pm lib/Protocol/*.pod build/$(PACKAGE)/lib/Protocol/
	cp lib/Protocol/HAP/*.pm lib/Protocol/HAP/*.pod build/$(PACKAGE)/lib/Protocol/HAP/
	# The Store/ loop accepts zero matches, because the
	# subdirectory arrives in a later phase
	for f in lib/Protocol/HAP/Store/*.pm lib/Protocol/HAP/Store/*.pod; do \
		[ -e "$$f" ] || continue; \
		mkdir -p build/$(PACKAGE)/lib/Protocol/HAP/Store; \
		cp "$$f" build/$(PACKAGE)/lib/Protocol/HAP/Store/; \
	done
	# rc.d script
	cp etc/rc.d/openhapd build/$(PACKAGE)/etc/rc.d/
	# Example configuration
	cp share/openhap/examples/openhapd.conf.sample build/$(PACKAGE)/share/openhap/examples/
	# Man pages
	cp $(MAN3P) build/$(PACKAGE)/man/fugulib/
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
	prove -l -v t/fuguvm/*.t
	prove -l -v t/fugulib/*.t
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
	# Remove Perl libraries
	rm -rf $(DESTDIR)$(LIBDIR)/OpenHAP
	rm -rf $(DESTDIR)$(LIBDIR)/FuguLib
	rm -rf $(DESTDIR)$(LIBDIR)/Protocol
	# Remove man pages
	for f in $(MAN3P); do \
		rm -f "$(DESTDIR)$(MANDIR)/man3p/FuguLib::$${f##*/}"; \
	done
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
	@command -v $(LOWDOWN) >/dev/null 2>&1 || \
	    { echo "$(LOWDOWN) not found; run 'make deps-develop'" >&2; exit 1; }
	@command -v $(MANDOC) >/dev/null 2>&1 || \
	    { echo "$(MANDOC) not found; run 'make deps-develop'" >&2; exit 1; }
	@command -v $(POD2MAN) >/dev/null 2>&1 || \
	    { echo "$(POD2MAN) not found; it ships with Perl" >&2; exit 1; }
	# A malformed page must fail the build, not render badly
	$(MANDOC) -Tlint -W warning $(MAN1) $(MAN3P) $(MAN5) $(MAN8)
	# Put every mdoc source in one directory.  Then mandoc can tell a
	# local cross-reference from one that belongs on man.openbsd.org.
	# Stage the FuguLib pages under the name that .Xr refers to them by.
	mkdir -p $(WEBMAN)
	cp $(MAN1) $(MAN5) $(MAN8) $(WEBMAN)/
	for f in $(MAN3P); do \
		cp "$$f" "$(WEBMAN)/FuguLib::$${f##*/}"; \
	done
	cp web/style.css $(WEBOUT)/style.css
	cp web/robots.txt $(WEBOUT)/robots.txt
	# The custom domain is a repository setting.  The deploy artifact
	# carries it too.  Thus a rebuild can never drop it
	cp web/CNAME $(WEBOUT)/CNAME
	$(MKPAGE) 'HomeKit Accessory Protocol for OpenBSD' \
	    < web/index.body.html > $(WEBOUT)/index.html
	$(MKPAGE) 'Not found' < web/404.body.html > $(WEBOUT)/404.html
	$(LOWDOWN) -Thtml INSTALL.md | \
	    $(MKPAGE) 'Install' > $(WEBOUT)/install.html
	$(MKINDEX) $(MAN1) $(MAN3P) $(MAN5) $(MAN8) `$(FINDPOD)` | \
	    $(MKPAGE) 'Manuals' > $(WEBOUT)/manuals.html
	$(MKPAGE) 'FuguVM' < web/fuguvm.body.html > $(WEBOUT)/fuguvm.html
	$(MKPAGE) 'FuguLib' < web/fugulib.body.html > $(WEBOUT)/fugulib.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) openhapd.8 ) | \
	    $(MKPAGE) 'openhapd(8)' > $(WEBOUT)/openhapd.8.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) hapctl.8 ) | \
	    $(MKPAGE) 'hapctl(8)' > $(WEBOUT)/hapctl.8.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) openhapd.conf.5 ) | \
	    $(MKPAGE) 'openhapd.conf(5)' > $(WEBOUT)/openhapd.conf.5.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) fuguvm.1 ) | \
	    $(MKPAGE) 'fuguvm(1)' > $(WEBOUT)/fuguvm.1.html
	for f in $(MAN3P); do \
		n="FuguLib::$${f##*/}"; n="$${n%.3p}"; \
		( cd $(WEBMAN) && $(MANDOC) $(MANHTML) "$$n.3p" ) | \
		    $(MKPAGE) "$$n(3p)" > "$(WEBOUT)/$$n.3p.html"; \
	done
	# One page per .pod sidecar.  The recipe gives --name, --center
	# and --release so the chrome matches the mdoc pages.  The date
	# comes from the checkout, not from file mtimes.  git does not
	# preserve mtimes.
	d=`git log -1 --format=%cs 2>/dev/null || date +%F`; \
	$(FINDPOD) | while read -r p; do \
		n="$${p#lib/}"; n="$${n%.pod}"; \
		n=`echo "$$n" | sed 's|/|::|g'`; \
		$(POD2MAN) --section=3p --name="$$n" --date="$$d" \
		    --center='Perl Library Manual' --release='OpenBSD' \
		    "$$p" | \
		    $(MANDOC) $(MANHTML) | \
		    $(MKPAGE) "$$n(3p)" > "$(WEBOUT)/$$n.3p.html"; \
	done
	# Staging is a build detail and never part of the published tree
	rm -rf $(WEBMAN)

web-clean:
	rm -rf $(WEBOUT)
