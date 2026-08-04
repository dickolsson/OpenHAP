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

# Man pages.  Fugu sources drop the Fugu:: prefix because a colon
# cannot appear in a make target.  install-man puts it back.
MAN1			= man/fuguvm/fuguvm.1
MAN3P			= man/fugu/CLI.3p man/fugu/Config.3p \
			  man/fugu/Control.3p man/fugu/Daemon.3p \
			  man/fugu/EventLoop.3p man/fugu/File.3p \
			  man/fugu/Imsg.3p \
			  man/fugu/JSONSocket.3p man/fugu/Log.3p \
			  man/fugu/Mdnsd.3p man/fugu/MQTT.3p \
			  man/fugu/Pidfile.3p man/fugu/Privdrop.3p \
			  man/fugu/Process.3p man/fugu/Proxy.3p \
			  man/fugu/Random.3p man/fugu/SSH.3p \
			  man/fugu/Sandbox.3p man/fugu/Signal.3p \
			  man/fugu/StateFile.3p man/fugu/Timeout.3p
MAN5			= man/openhap/openhapd.conf.5
MAN8			= man/openhap/hapctl.8 man/openhap/openhapd.8
CATMAN1			= $(MAN1:.1=.cat1)
CATMAN3P		= $(MAN3P:.3p=.cat3p)
CATMAN5			= $(MAN5:.5=.cat5)
CATMAN8			= $(MAN8:.8=.cat8)

# Website
WEBOUT			?= web/build
WEBMAN			= $(WEBOUT)/.man
FUGUWEB			?= bin/fuguweb
MKINDEX			= web/mkindex.sh
# The Makefile finds the .pod sidecars and never lists them.  Otherwise
# a sidecar without its own Makefile line would never reach the site.
# An exclusion list would be one more thing to keep true.  LC_ALL=C
# makes sure the order of the index does not depend on the builder's
# locale.
FINDPOD			= find lib -name '*.pod' | LC_ALL=C sort
# mandoc resolves .Xr against the working directory.  A page named %N.%S
# there becomes a local link.  Anything else goes to man.openbsd.org.
# The './' matters.  A module page is Fugu::Daemon.3p.html.  The
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
	# Install Perl libraries.  App/ is a shared parent: other
	# distributions live there too, so it is created, never removed
	install -d $(DESTDIR)$(LIBDIR)/App
	install -d $(DESTDIR)$(LIBDIR)/App/OpenHAP
	install -d $(DESTDIR)$(LIBDIR)/App/OpenHAP/Tasmota
	install -d $(DESTDIR)$(LIBDIR)/App/OpenHAP/Test
	install -d $(DESTDIR)$(LIBDIR)/Fugu
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
	# Fugu's API documentation lives in man3p, not in sidecars
	install -m 644 lib/Fugu/*.pm $(DESTDIR)$(LIBDIR)/Fugu/
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
	install -d $(DESTDIR)$(MANDIR)/man3p
	install -d $(DESTDIR)$(MANDIR)/man5
	install -d $(DESTDIR)$(MANDIR)/man8
	# The rename cannot be a glob.  'man Fugu::Daemon' looks for a
	# file of that name.  make cannot have that name as a target
	for f in $(MAN3P); do \
		install -m 644 "$$f" \
		    "$(DESTDIR)$(MANDIR)/man3p/Fugu::$${f##*/}"; \
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
	mkdir -p build/$(PACKAGE)/lib/App/OpenHAP/Tasmota
	mkdir -p build/$(PACKAGE)/lib/App/OpenHAP/Test
	mkdir -p build/$(PACKAGE)/lib/Fugu
	mkdir -p build/$(PACKAGE)/lib/Protocol/HAP
	mkdir -p build/$(PACKAGE)/etc/rc.d
	mkdir -p build/$(PACKAGE)/share/openhap/examples
	mkdir -p build/$(PACKAGE)/man/fugu
	mkdir -p build/$(PACKAGE)/man/openhap
	mkdir -p build/$(PACKAGE)/scripts
	mkdir -p build/$(PACKAGE)/deps
	# Binaries
	cp bin/openhapd bin/hapctl build/$(PACKAGE)/bin/
	# Perl libraries
	cp lib/App/OpenHAP/*.pm lib/App/OpenHAP/*.pod build/$(PACKAGE)/lib/App/OpenHAP/
	cp lib/App/OpenHAP/Tasmota/*.pm lib/App/OpenHAP/Tasmota/*.pod build/$(PACKAGE)/lib/App/OpenHAP/Tasmota/
	cp lib/App/OpenHAP/Test/*.pm lib/App/OpenHAP/Test/*.pod build/$(PACKAGE)/lib/App/OpenHAP/Test/
	cp lib/Fugu/*.pm build/$(PACKAGE)/lib/Fugu/
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
	cp $(MAN3P) build/$(PACKAGE)/man/fugu/
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
	prove -l -v t/fuguweb/*.t
	prove -l -v t/fugu/*.t
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
	rm -rf $(DESTDIR)$(LIBDIR)/Fugu
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
	for f in $(MAN3P); do \
		rm -f "$(DESTDIR)$(MANDIR)/man3p/Fugu::$${f##*/}"; \
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
	# Stage the Fugu pages under the name that .Xr refers to them by.
	mkdir -p $(WEBMAN)
	cp $(MAN1) $(MAN5) $(MAN8) $(WEBMAN)/
	for f in $(MAN3P); do \
		cp "$$f" "$(WEBMAN)/Fugu::$${f##*/}"; \
	done
	cp web/style.css $(WEBOUT)/style.css
	cp web/robots.txt $(WEBOUT)/robots.txt
	# The custom domain is a repository setting.  The deploy artifact
	# carries it too.  Thus a rebuild can never drop it
	cp web/CNAME $(WEBOUT)/CNAME
	$(FUGUWEB) page 'HomeKit Accessory Protocol for OpenBSD' \
	    < web/index.body.html > $(WEBOUT)/index.html
	$(FUGUWEB) page 'Not found' < web/404.body.html > $(WEBOUT)/404.html
	$(LOWDOWN) -Thtml INSTALL.md | \
	    $(FUGUWEB) page 'Install' > $(WEBOUT)/install.html
	$(MKINDEX) $(MAN1) $(MAN3P) $(MAN5) $(MAN8) `$(FINDPOD)` | \
	    $(FUGUWEB) page 'Manuals' > $(WEBOUT)/manuals.html
	$(FUGUWEB) page 'FuguVM' < web/fuguvm.body.html > $(WEBOUT)/fuguvm.html
	$(FUGUWEB) page 'Fugu' < web/fugu.body.html > $(WEBOUT)/fugu.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) openhapd.8 ) | \
	    $(FUGUWEB) page 'openhapd(8)' > $(WEBOUT)/openhapd.8.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) hapctl.8 ) | \
	    $(FUGUWEB) page 'hapctl(8)' > $(WEBOUT)/hapctl.8.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) openhapd.conf.5 ) | \
	    $(FUGUWEB) page 'openhapd.conf(5)' > $(WEBOUT)/openhapd.conf.5.html
	( cd $(WEBMAN) && $(MANDOC) $(MANHTML) fuguvm.1 ) | \
	    $(FUGUWEB) page 'fuguvm(1)' > $(WEBOUT)/fuguvm.1.html
	for f in $(MAN3P); do \
		n="Fugu::$${f##*/}"; n="$${n%.3p}"; \
		( cd $(WEBMAN) && $(MANDOC) $(MANHTML) "$$n.3p" ) | \
		    $(FUGUWEB) page "$$n(3p)" > "$(WEBOUT)/$$n.3p.html"; \
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
		    $(FUGUWEB) page "$$n(3p)" > "$(WEBOUT)/$$n.3p.html"; \
	done
	# Staging is a build detail and never part of the published tree
	rm -rf $(WEBMAN)

web-clean:
	rm -rf $(WEBOUT)
