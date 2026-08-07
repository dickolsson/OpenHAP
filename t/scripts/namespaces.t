#!/usr/bin/env perl
# ex:ts=8 sw=4:
# The clean-break gate of the namespace realignment
#
# A retired name and its replacement never exist together. No other
# gate in the project detects a shim: make lint and make tidy read the
# source, and neither knows which names are dead. This test does.
#
# It reads every tracked file and fails on a retired name, in the path
# or in the content. The path matters as much as the content: a file
# at a retired path that carries only 'our @ISA = ("Fugu::Log")' names
# nothing retired inside, and it is still a shim.
#
# Each pattern rejects the retired name and lets a live name that
# contains it through, with a lookbehind. A line filter cannot do
# that: grep -v 'App::OpenHAP::' drops the whole line, so a stale name
# hides behind a live one on the same line.
#
# The test reads tracked files only. build/, web/build/ and .fuguvm/
# hold generated pages under the old names until make clean, which
# makes a plain grep -r useless as a gate.

use v5.36;
use Test::More;
use FindBin qw($RealBin);

my $ROOT = "$RealBin/../..";

# Every name that a phase of plans/008 retired. Each entry holds the
# name for the message and the pattern that finds it.
#
# A pattern for a namespace uses a lookbehind, so that the live name
# that contains it passes. A pattern for a leaf name has none: a leaf
# under the live namespace, such as App::OpenHAP::Server, is a shim as
# much as the original was.
#
# A pattern for a path anchors on lib/, and thus on the source tree.
# scripts/vm-provision purges the retired install paths on the guest
# before make install, so it names one on purpose: a warm disk that
# keeps the old modules in @INC would supply the shim that the rename
# removed.
#
# Several patterns also take the bare file name, because prose names a
# module that way: a Layout row that reads PIN.pm carries no namespace
# for a pattern to anchor on. Only a distinctive leaf gets that
# treatment. Server.pm, VM.pm, Base.pm, and Image.pm are ordinary
# words, and the first of them is a live file.
my @RETIRED = (

	# Phase 1: the FuguLib collection became Fugu. The pattern
	# ignores case, so it covers the man/fugulib/ path form too. No
	# live spelling contains it, so the gate needs no lookbehind and
	# no anchor, and it therefore also covers an install path.
	{ name => 'FuguLib', pattern => qr/fugulib/i },

	# Phase 2: the OpenHAP host moved under App::, and four modules
	# took a name that says what they do.
	{ name => 'OpenHAP::',  pattern => qr/(?<!App::)OpenHAP::/ },
	{ name => 'lib/OpenHAP', pattern => qr{lib/OpenHAP\b} },
	{
		name    => 'OpenHAP::Server',
		pattern => qr{OpenHAP(?:::|/)Server\b},
	},
	{
		name    => 'OpenHAP::Storage',
		pattern => qr{ OpenHAP (?:::|/) Storage \b
		    | \b Storage\.(?:pm|pod) }x,
	},
	{
		name    => 'OpenHAP::DeviceLoader',
		pattern => qr{ OpenHAP (?:::|/) DeviceLoader \b
		    | \b DeviceLoader\.(?:pm|pod) }x,
	},
	{
		name    => 'OpenHAP::Tasmota::Base',
		pattern => qr{OpenHAP(?:::|/)Tasmota(?:::|/)Base\b},
	},

	# Phase 3: the VM utility moved under App::, and four modules
	# took a name that says what they do.
	{ name => 'FuguVM::',    pattern => qr/(?<!App::)FuguVM::/ },
	{ name => 'lib/FuguVM',  pattern => qr{lib/FuguVM\b} },
	{ name => 'FuguVM::VM',  pattern => qr{FuguVM(?:::|/)VM\b} },
	{
		name    => 'FuguVM::Expect',
		pattern => qr{ FuguVM (?:::|/) Expect \b
		    | \b Expect\.(?:pm|pod) }x,
	},
	{
		name    => 'FuguVM::ImageCache',
		pattern => qr{ FuguVM (?:::|/) ImageCache \b
		    | \b ImageCache\.(?:pm|pod) }x,
	},
	{
		name    => 'FuguVM::Image',
		pattern => qr{FuguVM(?:::|/)Image\b},
	},

	# Phase 5: the leaf renames that no namespace move forced. Each
	# pattern also covers the 3p page and the test file name, which
	# carry the leaf and not the namespace.
	{
		name    => 'Fugu::Util',
		pattern => qr{ Fugu (?:::|/) Util \b
		    | \b Util\.(?:pm|3p) }x,
	},
	{
		# Store.pod is live: it is the persistence contract of
		# Protocol::HAP. Only the module and the 3p page are gone.
		name    => 'Fugu::Store',
		pattern => qr{ Fugu (?:::|/) Store \b
		    | \b Store\.(?:pm|3p) }x,
	},
	{
		name    => 'Fugu::MDNS',
		pattern => qr{ Fugu (?:::|/) MDNS \b
		    | \b MDNS\.(?:pm|3p) }x,
	},
	{
		name    => 'Protocol::HAP::PIN',
		pattern => qr{ Protocol (?:::|/) HAP (?:::|/) PIN \b
		    | \b PIN\.(?:pm|pod) }x,
	},
	{ name => 'normalize_pin', pattern => qr/\bnormalize_pin\b/ },
	{ name => 'validate_pin',  pattern => qr/\bvalidate_pin\b/ },
	{ name => 'INVALID_PINS',  pattern => qr/\bINVALID_PINS\b/ },

	# format_size left Fugu:: for its only caller, so the name must
	# not appear outside App::FuguVM::CLI. The private form is a
	# different name and does not match.
	{ name => 'format_size', pattern => qr/(?<!_)\bformat_size\b/ },

	# plans/009: the two web scripts and the three files they read
	# became App::FuguWeb. The same clean-break rule covers a
	# retired script: a build recipe that still calls one is a
	# recipe that silently does nothing.
	{ name => 'mkpage.sh',  pattern => qr/\bmkpage(?:\.sh)?\b/ },
	{ name => 'mkindex.sh', pattern => qr/\bmkindex(?:\.sh)?\b/ },
	{ name => 'web/head.html', pattern => qr{\bweb/head\.html\b} },
	{ name => 'web/foot.html', pattern => qr{\bweb/foot\.html\b} },
	{ name => 'web/style.css', pattern => qr{\bweb/style\.css\b} },
);

# The vocabulary gate. The project has no users, so no code path stays
# for an old consumer, and no prose apologizes for one. A line that
# reaches for this vocabulary marks a shim, an alias, or a kept old
# path, and those go outright.
#
# The gate reads line by line, so a phrase split across a comment wrap
# escapes it. Accepted: the gate catches vocabulary, review catches
# intent. The bare word "legacy" is not banned: the Tasmota and HAP
# specs use it as a term of art, and a conformance test quotes a spec
# table.
my @BANNED = (
	{ name => 'deprecation', pattern => qr/\bdeprecat/i },
	{
		name    => 'backward compatibility',
		pattern => qr/backwards?[ -]compat/i,
	},
	{
		name    => 'for compatibility',
		pattern => qr/for compatibility/i,
	},
	{
		name    => 'compatibility shim',
		pattern => qr/compatibility (?:shim|layer|alias|wrapper|path)/i,
	},
);

# plans/001 to plans/008 record what was true when they were written.
# Do not rewrite them.
my $SKIP_DIR = qr{\A plans/ }x;

# The banned-vocabulary sweep also skips spec/: the specs quote other
# projects' deprecations, and spec/MQTT-Transport.md recommends
# defaults with the banned phrase. The retired-name sweep keeps
# reading spec/, so this skip applies to @BANNED only.
my $SKIP_SPEC = qr{\A spec/ }x;

# This file lists the retired names, so it names them by definition.
my %SKIP_FILE = ( 't/scripts/namespaces.t' => 1 );

chdir $ROOT or die "Cannot chdir to $ROOT: $!";

# tracked():
#	Return every tracked path, or the empty list when git cannot
#	answer.
sub tracked ()
{
	open my $fh, '-|', 'git', 'ls-files', '-z' or return;
	my $out = do { local $/; <$fh> };
	close $fh or return;
	return split /\0/, ( $out // '' );
}

my @tracked = tracked();
plan skip_all => 'git ls-files gave no file list' unless @tracked;

# Each pattern must match the name it is named after. A lookbehind
# with a typo matches nothing, and a phase would add a dead entry
# without one assertion failing.
for my $retired (@RETIRED) {
	like( $retired->{name}, $retired->{pattern},
		"the $retired->{name} pattern matches its own name" );
}
for my $banned (@BANNED) {
	like( $banned->{name}, $banned->{pattern},
		"the $banned->{name} pattern matches its own name" );
}

my @files = grep { !/$SKIP_DIR/ && !$SKIP_FILE{$_} } @tracked;

# The sweep must really sweep. A path filter that matched everything
# would leave an empty list and pass this file while proving nothing.
cmp_ok( scalar @files, '>', 50, 'the sweep reads the whole tree' );

my @violations;
for my $file (@files) {

	# git ls-files answers from the index. A rename in progress
	# leaves a tracked path with no file behind it, and that path is
	# on its way out, so it is not a shim.
	next unless -f $file;

	for my $retired (@RETIRED) {
		push @violations, "$file: the path names $retired->{name}"
		    if $file =~ $retired->{pattern};
	}

	open my $fh, '<', $file or do {
		push @violations, "$file: cannot read: $!";
		next;
	};
	my $sweep_banned = $file !~ $SKIP_SPEC;
	while ( my $line = <$fh> ) {
		for my $retired (@RETIRED) {
			next unless $line =~ $retired->{pattern};
			push @violations, "$file:$.: names $retired->{name}";
		}
		next unless $sweep_banned;
		for my $banned (@BANNED) {
			next unless $line =~ $banned->{pattern};
			push @violations,
			    "$file:$.: uses the banned vocabulary"
			    . " '$banned->{name}'";
		}
	}
	close $fh;
}

is( scalar @violations, 0, 'no retired name survives' )
    or diag( join "\n", @violations );

done_testing();
