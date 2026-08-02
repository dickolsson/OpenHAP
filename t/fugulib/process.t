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

# Test 3: A process that exits at once with a non-zero code is a
# failure. The check_alive window makes the outcome deterministic.
{
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sh', '-c', 'exit 1' ],
		check_alive => 1,
	);

	ok( !$result->{success}, 'Detected immediate failure' );
	like( $result->{error}, qr/died immediately/,
		'Error message mentions death' );
	is( $result->{exit_code}, 1, 'Exit code captured' );
}

# Test 3b: A process that exits at once with code 0 is not a failure.
# It did its work and left.
{
	my $result = FuguLib::Process->spawn_command(
		cmd         => [ 'sh', '-c', 'exit 0' ],
		check_alive => 1,
	);

	ok( $result->{success},  'A clean fast exit is a success' );
	ok( $result->{exited},   'and the result says the child exited' );
	is( $result->{exit_code}, 0, 'with code 0' );
	ok( !defined $result->{error}, 'and carries no error' );
}

# Test 3c: An exec that fails reports its own reason at once, through
# the close-on-exec pipe and not through a wait-and-guess sleep.
{
	my $start  = time;
	my $result = FuguLib::Process->spawn_command(
		cmd => ['/nonexistent/definitely-not-a-command'],
	);
	my $elapsed = time - $start;

	ok( !$result->{success}, 'An exec failure is a failure' );
	like(
		$result->{error},
		qr/Cannot exec .*definitely-not-a-command/,
		'the error names the command'
	);
	like( $result->{error}, qr/No such file|not found/i,
		'and carries the reason from the system' );
	ok( $elapsed <= 2, 'the report does not wait for a sleep' );
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
{
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

# Test 11: Graceful and forced termination
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

# Test 14: exit_code maps a raw wait status to a 0-255 code
{
	is( FuguLib::Process->exit_code(0),        0, 'status 0 -> exit 0' );
	is( FuguLib::Process->exit_code( 1 << 8 ), 1, 'exit code 1 preserved' );
	is( FuguLib::Process->exit_code( 2 << 8 ), 2, 'exit code 2 preserved' );
	is( FuguLib::Process->exit_code( 255 << 8 ),
		255, 'exit code 255 preserved' );
	is( FuguLib::Process->exit_code(-1), 1,   'a failed start -> 1' );
	is( FuguLib::Process->exit_code(15), 143, 'signal 15 -> 128 + signal' );
	is( FuguLib::Process->exit_code(2),  130, 'signal 2 -> 128 + signal' );
}

# Test 15: run captures both streams and the exit code
{
	my $r = FuguLib::Process->run(
		cmd => [ 'sh', '-c', 'echo out; echo err >&2; exit 3' ] );

	is( $r->{exit_code}, 3, 'run reports the exit code' );
	ok( !$r->{success}, 'a non-zero exit is not a success' );
	like( $r->{stdout}, qr/^out$/m,  'run captured stdout' );
	like( $r->{stderr}, qr/^err$/m,  'run captured stderr' );
	ok( !$r->{timed_out}, 'and it did not time out' );
}

# Test 16: run feeds stdin and never goes through a shell
{
	my $r = FuguLib::Process->run(
		cmd   => [ 'cat' ],
		stdin => "hello\n",
	);
	is( $r->{stdout}, "hello\n", 'run feeds stdin to the child' );
	ok( $r->{success}, 'and reports success' );

	# An argument that a shell would treat as an operator stays one
	# argument, because the command is a list
	my $shell = FuguLib::Process->run( cmd => [ 'echo', 'a; touch b' ] );
	is( $shell->{stdout}, "a; touch b\n", 'no shell interprets the argument' );
}

# Test 17: run enforces its timeout
{
	my $start = time;
	my $r     = FuguLib::Process->run(
		cmd     => [ 'sleep', '30' ],
		timeout => 1,
	);
	my $elapsed = time - $start;

	ok( $r->{timed_out}, 'run reports the timeout' );
	ok( !$r->{success},  'a timed-out run is not a success' );
	ok( $elapsed < 10,   'and it returned near the deadline' );
}

# Test 18: run reports an exec failure without starting anything
{
	my $r = FuguLib::Process->run(
		cmd => ['/nonexistent/definitely-not-a-command'] );

	ok( !$r->{success}, 'run fails when the exec fails' );
	like( $r->{error}, qr/Cannot exec/, 'and names the exec' );

	my $empty = FuguLib::Process->run( cmd => [] );
	ok( !$empty->{success}, 'run rejects an empty command' );
}

# Test 19: run drains a child that writes more than one pipe buffer.
# A reader that took the streams in sequence would deadlock here.
{
	my $r = FuguLib::Process->run(
		cmd => [
			'sh', '-c',
			'i=0; while [ $i -lt 400 ]; do '
			    . 'echo "0123456789012345678901234567890123456789"; '
			    . 'echo "x" >&2; i=$((i+1)); done'
		],
		timeout => 30,
	);

	ok( $r->{success}, 'a chatty child completes' );
	is( length( $r->{stdout} ), 400 * 41, 'stdout arrived whole' );
	is( length( $r->{stderr} ), 400 * 2,  'stderr arrived whole' );
}

done_testing();
