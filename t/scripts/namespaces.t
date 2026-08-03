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
my @RETIRED = (

	# Phase 1: the FuguLib collection became Fugu. The pattern
	# ignores case, so it covers the man/fugulib/ path form too.
	{ name => 'FuguLib', pattern => qr/fugulib/i },
);

# plans/001 to plans/008 record what was true when they were written.
# Do not rewrite them.
my $SKIP_DIR = qr{\A plans/ }x;

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

my @files = grep { !/$SKIP_DIR/ && !$SKIP_FILE{$_} } @tracked;

# The sweep must really sweep. A path filter that matched everything
# would leave an empty list and pass this file while proving nothing.
cmp_ok( scalar @files, '>', 50, 'the sweep reads the whole tree' );

my @violations;
for my $file (@files) {
	for my $retired (@RETIRED) {
		push @violations, "$file: the path names $retired->{name}"
		    if $file =~ $retired->{pattern};
	}

	open my $fh, '<', $file or do {
		push @violations, "$file: cannot read: $!";
		next;
	};
	while ( my $line = <$fh> ) {
		for my $retired (@RETIRED) {
			next unless $line =~ $retired->{pattern};
			push @violations, "$file:$.: names $retired->{name}";
		}
	}
	close $fh;
}

is( scalar @violations, 0, 'no retired name survives' )
    or diag( join "\n", @violations );

done_testing();
