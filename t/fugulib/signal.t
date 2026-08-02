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
	FuguLib::Signal::reset_all_interrupted();
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
	FuguLib::Signal::reset_all_interrupted();
	my $sig = FuguLib::Signal->new;
	$sig->setup_interrupt_flag('USR1');

	ok( !$sig->interrupted, 'Not interrupted before signal' );

	kill 'USR1', $$;
	sleep 0.1;    # Give the signal time to arrive

	ok( $sig->interrupted, 'Interrupted after signal' );
	ok( FuguLib::Signal::check_interrupted(),
		'The package function sees it too' );

	$sig->reset_interrupted;
	ok( !$sig->interrupted, 'reset_interrupted clears the flag' );

	$sig->restore;
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
	FuguLib::Signal::reset_all_interrupted();
	my $sig = FuguLib::Signal->new;
	$sig->setup_interrupt_flag( 'USR1', 'USR2' );

	kill 'USR2', $$;
	sleep 0.1;

	ok( $sig->interrupted, 'Interrupted by second signal' );

	$sig->restore;
	FuguLib::Signal::reset_all_interrupted();
}

# Two managers do not share state. Each one owns its cleanups and its
# interrupt flag.
{
	FuguLib::Signal::reset_all_interrupted();

	my @ran;
	my $first  = FuguLib::Signal->new;
	my $second = FuguLib::Signal->new;
	$first->add_cleanup( sub ($) { push @ran, 'first' } );
	$second->add_cleanup( sub ($) { push @ran, 'second' } );

	$first->_run_cleanup_handlers('TEST');
	is_deeply( \@ran, ['first'], 'a manager runs only its own cleanups' );

	@ran = ();
	$second->_run_cleanup_handlers('TEST');
	is_deeply( \@ran, ['second'], 'and the other one runs only its own' );

	$first->setup_interrupt_flag('USR1');
	kill 'USR1', $$;
	sleep 0.1;

	ok( $first->interrupted,   'the manager that caught it is interrupted' );
	ok( !$second->interrupted, 'the other manager is not' );

	$first->restore;
	FuguLib::Signal::reset_all_interrupted();
}

# The cleanup list survives its run. A second signal during a shutdown
# must find the same handlers.
{
	my $runs = 0;
	my $sig  = FuguLib::Signal->new;
	$sig->add_cleanup( sub ($) { $runs++ } );

	$sig->_run_cleanup_handlers('TERM');
	$sig->_run_cleanup_handlers('TERM');

	is( $runs, 2, 'the cleanups run again on a second signal' );
}

# A cleanup that dies does not stop the ones after it
{
	my @ran;
	my $sig = FuguLib::Signal->new;
	$sig->add_cleanup( sub ($) { die "cleanup failed\n" } );
	$sig->add_cleanup( sub ($) { push @ran, 'after' } );

	$sig->_run_cleanup_handlers('TERM');
	is_deeply( \@ran, ['after'], 'a dying cleanup does not stop the rest' );
}

# The exit status of a graceful exit is configurable
{
	is( FuguLib::Signal->new->{exit_status}, 130, 'the default is 130' );
	is( FuguLib::Signal->new( exit_status => 143 )->{exit_status},
		143, 'exit_status overrides it' );
}

# A destroyed manager leaves no entry behind for check_interrupted
{
	FuguLib::Signal::reset_all_interrupted();
	{
		my $sig = FuguLib::Signal->new;
		$sig->setup_interrupt_flag('USR2');
		kill 'USR2', $$;
		sleep 0.1;
		ok( FuguLib::Signal::check_interrupted(), 'the flag is set' );
		$sig->restore;
	}
	ok( !FuguLib::Signal::check_interrupted(),
		'the flag goes with the manager' );
}

done_testing();
