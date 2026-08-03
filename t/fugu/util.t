#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin     qw($RealBin);
use lib "$RealBin/../../lib";
use Time::HiRes qw(time sleep);

use_ok('Fugu::Util');
use_ok('Fugu::Signal');

subtest 'bounded returns what the code returns' => sub {
	is( Fugu::Util::bounded( 5, sub { 'value' } ),
		'value', 'the return value passes through' );
	is_deeply( Fugu::Util::bounded( 5, sub { [ 1, 2 ] } ),
		[ 1, 2 ], 'a reference passes through' );
	is( Fugu::Util::bounded( 5, sub { undef } ),
		undef, 'undef passes through' );
};

subtest 'bounded stops a call that runs too long' => sub {
	my $start = time;
	my $result = Fugu::Util::bounded( 1, sub { sleep 30; 'never' } );
	my $elapsed = time - $start;

	is( $result, undef, 'a timeout gives undef' );
	ok( $elapsed < 10, 'and it returned near the deadline' )
	    or diag("took ${elapsed}s");

	# The alarm must not survive the call. A leaked alarm would kill
	# the caller some seconds later, far from the cause.
	is( alarm(0), 0, 'no alarm is left pending' );
};

subtest 'bounded lets a real error through' => sub {
	ok( !eval { Fugu::Util::bounded( 5, sub { die "real failure\n" } ); 1 },
		'a die inside the code propagates' );
	is( $@, "real failure\n", 'with its own message' );
	is( alarm(0), 0, 'and no alarm is left pending' );
};

subtest 'wait_until polls until the condition holds' => sub {
	my $calls = 0;
	my $result = Fugu::Util::wait_until( 5, 0.05, sub { ++$calls >= 3 } );

	ok( $result, 'the condition was met' );
	is( $calls, 3, 'the code ran until it returned true' );
};

subtest 'wait_until runs the code at least once' => sub {
	my $calls = 0;
	my $result = Fugu::Util::wait_until( 0, 0.05, sub { $calls++; 'now' } );

	is( $result, 'now', 'a zero timeout still asks once' );
	is( $calls,  1,     'exactly once' );
};

subtest 'wait_until gives up at the deadline' => sub {
	my $start = time;
	my $result = Fugu::Util::wait_until( 0.5, 0.05, sub { 0 } );
	my $elapsed = time - $start;

	is( $result, undef, 'a condition that never holds gives undef' );
	ok( $elapsed >= 0.4, 'it waited for the timeout' )
	    or diag("took ${elapsed}s");
	ok( $elapsed < 5, 'and no longer' ) or diag("took ${elapsed}s");
};

subtest 'wait_until stops on an interrupt' => sub {
	Fugu::Signal::reset_all_interrupted();

	my $sig = Fugu::Signal->new;
	$sig->setup_interrupt_flag('USR1');

	my $calls = 0;
	my $start = time;
	kill 'USR1', $$;
	sleep 0.05;

	my $result = Fugu::Util::wait_until( 30, 0.05,
		sub { $calls++; 0 } );
	my $elapsed = time - $start;

	is( $result, undef, 'an interrupted wait gives undef' );
	is( $calls,  0,     'and the code never ran' );
	ok( $elapsed < 5, 'it returned at once' ) or diag("took ${elapsed}s");

	$sig->restore;
	Fugu::Signal::reset_all_interrupted();
};

subtest 'format_size' => sub {
	is( Fugu::Util::format_size(0),          '0B',    'zero' );
	is( Fugu::Util::format_size(512),        '512B',  'bytes' );
	is( Fugu::Util::format_size(1023),       '1023B', 'just under 1K' );
	is( Fugu::Util::format_size(1024),       '1.0K',  'one kilobyte' );
	is( Fugu::Util::format_size(1536),       '1.5K',  'one and a half' );
	is( Fugu::Util::format_size(1024**2),    '1.0M',  'one megabyte' );
	is( Fugu::Util::format_size(1024**3),    '1.0G',  'one gigabyte' );
	is( Fugu::Util::format_size(1024**4),    '1.0T',  'one terabyte' );
	is( Fugu::Util::format_size(1024**5),    '1024.0T',
		'past the largest unit it keeps counting' );
	is( Fugu::Util::format_size(undef), '?',
		'a size nobody could measure is not a size of zero' );
};

done_testing();
