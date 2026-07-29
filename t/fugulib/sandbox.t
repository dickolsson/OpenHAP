#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for FuguLib::Sandbox: the no-op contract everywhere, real
# enforcement on OpenBSD. Enforcement runs in child processes because
# a pledge violation kills the violator with an uncatchable SIGABRT
# and unveil restricts the caller for good - the parent must stay
# unrestricted or it takes the rest of the suite down. Never assert in
# the children: they share the TAP stream.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);
use POSIX qw(SIGABRT);

use_ok('FuguLib::Sandbox');

my $lib = "$RealBin/../../lib";
my $dir = tempdir( CLEANUP => 1 );

# run_child($source):
#	Run perl code in a subprocess with core dumps disabled - the
#	SIGABRT from a pledge violation would otherwise drop perl.core
#	into the repository root. Returns the raw wait status.
sub run_child ($source)
{
	my $script = "$dir/child-$$-" . int( rand 10000 ) . '.pl';
	open my $fh, '>', $script or die "write $script: $!";
	print $fh $source;
	close $fh;

	system( 'sh', '-c', "ulimit -c 0; '$^X' -I'$lib' '$script'" );
	unlink $script;

	return $?;
}

subtest 'is_supported reflects the platform' => sub {
	is( !!FuguLib::Sandbox->is_supported,
		!!( $^O eq 'openbsd' ),
		'true exactly on OpenBSD' );
};

subtest 'malformed arguments die on every platform' => sub {
	ok( !eval { FuguLib::Sandbox->pledge; 1 },
		'pledge without promises dies' );
	ok( !eval { FuguLib::Sandbox->pledge( promises => '' ); 1 },
		'pledge with an empty promise set dies' );
	ok( !eval { FuguLib::Sandbox->unveil; 1 },
		'unveil without paths dies' );
	ok( !eval { FuguLib::Sandbox->unveil( paths => 'not-a-ref' ); 1 },
		'unveil with a non-arrayref dies' );
	ok( !eval { FuguLib::Sandbox->unveil( paths => [ ['/x'] ] ); 1 },
		'unveil pair without permissions dies' );
};

subtest 'no-op platforms return success from every method' => sub {
	plan skip_all => 'this platform enforces for real'
	    if FuguLib::Sandbox->is_supported;

	is( FuguLib::Sandbox->pledge( promises => 'stdio rpath' ),
		1, 'pledge is a successful no-op' );
	is( FuguLib::Sandbox->unveil( paths => [ [ $dir, 'r' ] ] ),
		1, 'unveil is a successful no-op' );
	is( FuguLib::Sandbox->unveil_lock, 1, 'lock is a successful no-op' );

	# And none of them restricted anything
	ok( open( my $fh, '<', $0 ), 'filesystem still fully visible' );
	close $fh if $fh;
};

subtest 'pledge violation aborts the violator' => sub {
	plan skip_all => 'pledge(2) only enforced on OpenBSD'
	    unless FuguLib::Sandbox->is_supported;

	my $status = run_child(<<'EOF');
use v5.36;
use FuguLib::Sandbox;
use Socket qw(AF_INET SOCK_STREAM);
use POSIX ();
FuguLib::Sandbox->pledge(promises => 'stdio');
socket(my $s, AF_INET, SOCK_STREAM, 0);
POSIX::_exit(0);    # only reachable if the pledge did not enforce
EOF
	is( $status & 127, SIGABRT,
		'socket(2) outside the promise set delivers SIGABRT' );
	unlink 'perl.core';    # belt and braces: ulimit already forbids it
};

subtest 'a bogus promise string dies rather than being accepted' => sub {
	plan skip_all => 'pledge(2) only enforced on OpenBSD'
	    unless FuguLib::Sandbox->is_supported;

	# An unknown promise fails with EINVAL before anything is
	# restricted, so this is safe in-process
	ok( !eval {
		FuguLib::Sandbox->pledge( promises => 'nosuchpromise' );
		1;
	    },
	    'unknown promise dies'
	);
	like( $@, qr/pledge\(nosuchpromise\)/, 'error names the promises' );
};

subtest 'unveil restricts the filesystem view' => sub {
	plan skip_all => 'unveil(2) only enforced on OpenBSD'
	    unless FuguLib::Sandbox->is_supported;

	my $inside = "$dir/inside.txt";
	open my $fh, '>', $inside or die "write $inside: $!";
	print $fh "visible\n";
	close $fh;

	# Exit codes pick the failing step apart: 1 = a file outside
	# the view stayed readable, 2 = the file inside did not
	my $status = run_child( <<EOF . <<'BODY' );
use v5.36;
use FuguLib::Sandbox;
use POSIX ();
my $dir = '$dir';
EOF
FuguLib::Sandbox->unveil(paths => [[$dir, 'r']]);
FuguLib::Sandbox->unveil_lock;
POSIX::_exit(1) if open(my $out, '<', '/etc/services');
POSIX::_exit(2) unless open(my $in, '<', "$dir/inside.txt");
POSIX::_exit(0);
BODY
	is( $status >> 8, 0, 'outside unreadable, inside readable' );
};

subtest 'required and optional dispositions' => sub {
	plan skip_all => 'unveil(2) only enforced on OpenBSD'
	    unless FuguLib::Sandbox->is_supported;

	# 3 = a missing required path was silently accepted,
	# 4 = a missing optional path was not skipped cleanly,
	# 5 = on_skip did not report it
	my $status = run_child( <<EOF . <<'BODY' );
use v5.36;
use FuguLib::Sandbox;
use POSIX ();
my $dir = '$dir';
EOF
my @skipped;
eval {
	FuguLib::Sandbox->unveil(
		paths   => [["$dir/no-such-entry", 'r']],
	);
	1;
} and POSIX::_exit(3);
eval {
	FuguLib::Sandbox->unveil(
		paths => [
			["$dir/no-such-entry", 'r', { optional => 1 }],
			[$dir, 'r'],
		],
		on_skip => sub ($path) { push @skipped, $path },
	);
	1;
} or POSIX::_exit(4);
POSIX::_exit(5) unless @skipped == 1;
POSIX::_exit(0);
BODY
	is( $status >> 8, 0,
		'missing required dies, missing optional is skipped and reported'
	);
};

done_testing();
