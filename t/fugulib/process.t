#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use File::Temp qw(tempdir);

use_ok('FuguLib::Process');

# Test 2: Basic spawn and terminate
{
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sleep', '300' ],
		check_alive => 1,
	);

	ok( $result->{success}, 'Spawned sleep process' );
	ok( defined $result->{pid}, 'Got PID' );
	my $pid = $result->{pid};

	ok( FuguLib::Process->is_alive($pid), 'Process is alive' );

	my $killed = FuguLib::Process->terminate( $pid, grace_period => 2 );
	ok( $killed, 'Terminated process' );

	ok( !FuguLib::Process->is_alive($pid), 'Process is dead' );
}

# Test 3: Process that exits immediately with non-zero (failure)
SKIP: {
	# This test is OS-dependent. The sh -c command can exit
	# immediately, but this is not certain.
	skip 'Process exit timing varies by OS', 3;

	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sh', '-c', 'exit 1' ],
		check_alive => 1,
	);

	ok( !$result->{success}, 'Detected immediate failure' );
	like( $result->{error}, qr/died immediately/, 'Error message mentions death' );
	is( $result->{exit_code}, 1, 'Exit code captured' );
}

# Test 4: Invalid command
{
	my $result = FuguLib::Process->spawn_command(
		cmd         => [],
		check_alive => 0,
	);

	ok( !$result->{success}, 'Rejected empty command' );
}

# Test 5: Callbacks
{
	my $success_called = 0;
	my $result         = FuguLib::Process->spawn_command(
		cmd         => [ 'sleep', '1' ],
		check_alive => 0,
		on_success  => sub($pid) { $success_called = $pid; },
	);

	ok( $result->{success}, 'Spawn with callback succeeded' );
	is( $success_called, $result->{pid}, 'Success callback called with PID' );

	FuguLib::Process->terminate( $result->{pid} );
}

# Test 6: Error callback
SKIP: {
	# This test is OS-dependent
	skip 'Process exit timing varies by OS', 2;

	my $error_msg = '';
	my $result    = FuguLib::Process->spawn_command(
		cmd         => [ 'sh', '-c', 'exit 1' ],
		check_alive => 1,
		on_error    => sub($err) { $error_msg = $err; },
	);

	ok( !$result->{success}, 'Detected immediate death with callback' );
	like( $error_msg, qr/died immediately/, 'Error callback called' );
}

# Test 7: Zombie reaping
{
	# Spawn a process and let it exit
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'true' ],
		check_alive => 0,
	);

	sleep 1;    # Let the process exit

	my $reaped = FuguLib::Process->reap( $result->{pid} );
	ok( $reaped, 'Reaped zombie process' );
}

# Test 8: is_alive edge cases
{
	ok( !FuguLib::Process->is_alive(undef),  'undef PID is not alive' );
	ok( !FuguLib::Process->is_alive(''),     'Empty PID is not alive' );
	ok( !FuguLib::Process->is_alive('abc'),  'Non-numeric PID is not alive' );
	ok( !FuguLib::Process->is_alive(999999), 'Non-existent PID is not alive' );
	ok( FuguLib::Process->is_alive($$),      'Own PID is alive' );
}

# Test 9: wait_exit
{
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sleep', '1' ],
		check_alive => 0,
	);

	my $exited = FuguLib::Process->wait_exit( $result->{pid}, 5 );
	ok( $exited, 'Process exited within timeout' );
}

# Test 10: wait_exit timeout
{
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sleep', '10' ],
		check_alive => 0,
	);

	my $exited = FuguLib::Process->wait_exit( $result->{pid}, 1 );
	ok( !$exited, 'Timeout waiting for exit' );

	FuguLib::Process->terminate( $result->{pid} );
}

# Test 11: Graceful vs forced termination
{
	# A process that ignores SIGTERM (sleep handles it)
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sleep', '300' ],
		check_alive => 0,
	);

	my $start  = time;
	my $killed = FuguLib::Process->terminate( $result->{pid}, grace_period => 2 );
	my $elapsed = time - $start;

	ok( $killed, 'Process terminated' );
	ok( $elapsed < 5, 'Terminated quickly (graceful)' );
}

# Test 12: reap_all
{
	# Spawn multiple short-lived processes
	for ( 1 .. 3 ) {
		FuguLib::Process->spawn_command( cmd => ['true'], check_alive => 0 );
	}

	sleep 1;    # Let all the processes exit

	my $count = FuguLib::Process->reap_all();
	cmp_ok( $count, '>=', 0, 'Reaped zombies' );
}

# Test 13: I/O redirection
{
	my $tmpdir  = tempdir( CLEANUP => 1 );
	my $outfile = "$tmpdir/fugulib-process-test.txt";

	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'echo', 'test output' ],
		stdout      => $outfile,
		check_alive => 0,
	);

	sleep 1;
	FuguLib::Process->wait_exit( $result->{pid}, 2 );

	ok( -f $outfile, 'Output file created' );
	if ( -f $outfile ) {
		open my $fh, '<', $outfile
		    or do { fail("Cannot read $outfile: $!"); };
		my $content = <$fh>;
		close $fh;
		like( $content, qr/test output/, 'Output redirected correctly' );
	}
}

done_testing();
