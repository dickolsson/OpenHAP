#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use_ok('FuguLib::Signal');

# Test basic object creation
{
	my $sig = FuguLib::Signal->new;
	ok( defined $sig, 'Signal handler created' );
	isa_ok( $sig, 'FuguLib::Signal' );
}

# Test interrupt flag
{
	FuguLib::Signal::reset_interrupted();
	ok( !FuguLib::Signal::check_interrupted(),
		'Not interrupted initially' );
}

# Test signal handler setup and restore
{
	my $sig = FuguLib::Signal->new;

	my $original_int = $SIG{INT} // 'DEFAULT';
	$sig->setup_interrupt_flag('INT');

	isnt( $SIG{INT}, $original_int, 'INT handler changed' );

	$sig->restore;
	my $restored = $SIG{INT} // 'DEFAULT';
	is( $restored, $original_int, 'INT handler restored' );
}

# Test interrupt flag setting
{
	FuguLib::Signal::reset_interrupted();
	my $sig = FuguLib::Signal->new;
	$sig->setup_interrupt_flag('USR1');

	ok( !FuguLib::Signal::check_interrupted(), 'Not interrupted before signal' );

	kill 'USR1', $$;
	sleep 0.1;    # Give the signal time to arrive

	ok( FuguLib::Signal::check_interrupted(), 'Interrupted after signal' );

	$sig->restore;
	FuguLib::Signal::reset_interrupted();
}

# Test cleanup handlers
{
	my $cleanup_called = 0;
	my $cleanup_signal;

	my $sig = FuguLib::Signal->new;
	$sig->add_cleanup(
		sub ($signal) {
			$cleanup_called++;
			$cleanup_signal = $signal;
		}
	);

	# Trigger the cleanup manually
	$sig->_run_cleanup_handlers('TEST');

	is( $cleanup_called, 1,      'Cleanup handler called' );
	is( $cleanup_signal, 'TEST', 'Cleanup received signal name' );
}

# Test multiple cleanup handlers
{
	my @calls;

	my $sig = FuguLib::Signal->new;
	$sig->add_cleanup( sub ($) { push @calls, 'first'; } );
	$sig->add_cleanup( sub ($) { push @calls, 'second'; } );

	$sig->_run_cleanup_handlers('TEST');

	is_deeply( \@calls, [ 'first', 'second' ],
		'Multiple cleanup handlers called in order' );
}

# Test automatic restoration on DESTROY
{
	my $original_usr1 = $SIG{USR1};

	{
		my $sig = FuguLib::Signal->new;
		$sig->setup_interrupt_flag('USR1');
		isnt( $SIG{USR1}, $original_usr1,
			'USR1 handler changed in scope' );
	}

	is( $SIG{USR1}, $original_usr1,
		'USR1 handler restored after scope exit' );
}

# Test interrupt flag with multiple signals
{
	FuguLib::Signal::reset_interrupted();
	my $sig = FuguLib::Signal->new;
	$sig->setup_interrupt_flag( 'USR1', 'USR2' );

	kill 'USR2', $$;
	sleep 0.1;

	ok( FuguLib::Signal::check_interrupted(),
		'Interrupted by second signal' );

	$sig->restore;
	FuguLib::Signal::reset_interrupted();
}

done_testing();
