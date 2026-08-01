# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@senzilla.io>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use v5.36;

package FuguLib::Process;

use POSIX qw(setsid WNOHANG);

# FuguLib::Process - Robust process management
#
# The module does forking, exec, PID tracking, signal handling, and
# zombie reaping. It adds proper error detection and logging
# integration.

# $class->spawn_command(%args):
#	Fork and execute a command. Optionally run it as a daemon.
#	The method returns a hashref: {pid => $pid, success => 1} on
#	success, or {success => 0, error => $msg} on failure.
#
#	%args:
#		cmd       => \@command  # Required: the command to execute
#		daemonize => 0|1        # Optional: detach from the terminal
#		stdout    => $path|undef # Optional: redirect stdout (default: /dev/null)
#		stderr    => $path|undef # Optional: redirect stderr (default: /dev/null)
#		stdin     => $path|undef # Optional: redirect stdin (default: /dev/null)
#		on_error  => sub($err)  # Optional: error callback
#		on_success => sub($pid) # Optional: success callback
#		check_alive => $seconds # Optional: wait, then make sure the process is alive
sub spawn_command ( $class, %args )
{
	my $cmd = $args{cmd}
	    or return { success => 0, error => 'No command specified' };
	my $daemonize   = $args{daemonize} // 0;
	my $stdout      = $args{stdout}    // '/dev/null';
	my $stderr      = $args{stderr}    // '/dev/null';
	my $stdin       = $args{stdin}     // '/dev/null';
	my $on_error    = $args{on_error};
	my $on_success  = $args{on_success};
	my $check_alive = $args{check_alive} // 1;

	unless ( ref $cmd eq 'ARRAY' && @$cmd > 0 ) {
		my $err = 'Command must be non-empty arrayref';
		$on_error->($err) if $on_error;
		return { success => 0, error => $err };
	}

	# Fork
	my $pid = fork;
	unless ( defined $pid ) {
		my $err = "Cannot fork: $!";
		$on_error->($err) if $on_error;
		return { success => 0, error => $err };
	}

	if ( $pid == 0 ) {

		# Child process
		$DB::inhibit_exit = 0;

		if ($daemonize) {

			# Become the session leader
			setsid() or exit 1;
		}

		# Redirect the file descriptors
		if ( !open STDIN, '<', $stdin ) {
			warn "Cannot redirect stdin: $!";
			exit 1;
		}
		if ( !open STDOUT, '>', $stdout ) {
			warn "Cannot redirect stdout: $!";
			exit 1;
		}
		if ( !open STDERR, '>', $stderr ) {
			warn "Cannot redirect stderr: $!";
			exit 1;
		}

		# Execute the command
		exec @$cmd or exit 1;
	}

	# Parent process
	if ($check_alive) {

		# Give the process time to start
		sleep $check_alive;

		# Try to reap the zombie without blocking. is_alive
		# would do this too.
		my $reaped = waitpid( $pid, WNOHANG );

		# If waitpid reaped the process, the process died
		if ( $reaped == $pid ) {
			my $exit_status = $? >> 8;
			my $err =
			    $exit_status == 0
			    ? "Process $pid completed immediately (may be expected)"
			    : "Process $pid died immediately with exit code $exit_status";
			$on_error->($err) if $on_error;
			return {
				success   => 0,
				error     => $err,
				pid       => $pid,
				exit_code => $exit_status
			};
		}

		# Check again with kill(0) to make sure the process is
		# alive
		unless ( kill( 0, $pid ) ) {
			my $err =
"Process $pid is not alive (not reaped, possible race)";
			$on_error->($err) if $on_error;
			return {
				success   => 0,
				error     => $err,
				pid       => $pid,
				exit_code => -1
			};
		}
	}

	$on_success->($pid) if $on_success;
	return { success => 1, pid => $pid };
}

# $class->is_alive($pid):
#	Check if the process is alive (not dead, not a zombie).
#	The method returns 1 if the process is alive. It returns 0 if
#	the process is dead, a zombie, or does not exist.
sub is_alive ( $class, $pid )
{
	return 0 unless defined $pid;
	return 0 unless $pid =~ /^\d+$/;

	# First check if the process exists
	return 0 unless kill( 0, $pid );

	# Do not try to wait on the current process
	return 1 if $pid == $$;

	# Try to reap zombies without blocking
	my $result = waitpid( $pid, WNOHANG );

	# If waitpid returns the PID, the process was a zombie.
	# waitpid has now reaped it.
	return 0 if $result == $pid;

	# If waitpid returns -1, there is no such child. The process
	# is not a child of the current process, but it is still alive.
	#return 0 if $result == -1;

	# Otherwise, the process is alive
	return 1;
}

# $class->terminate($pid, %args):
#	Stop a process gracefully. Use force if necessary.
#	The method returns 1 if the process is killed or dead. It
#	returns 0 on failure.
#
#	%args:
#		grace_period => $seconds # Time to wait after TERM before KILL (default: 5)
#		on_kill      => sub()    # Runs after a successful kill
sub terminate ( $class, $pid, %args )
{
	return 1 unless defined $pid;
	return 1 unless $class->is_alive($pid);

	my $grace_period = $args{grace_period} // 5;
	my $on_kill      = $args{on_kill};

	# Send SIGTERM
	my $killed = kill 'TERM', $pid;
	unless ($killed) {

		# The process is already dead, or there is no
		# permission
		return $class->is_alive($pid) ? 0 : 1;
	}

	# Wait for the process to exit
	my $waited = 0;
	while ( $waited < $grace_period && $class->is_alive($pid) ) {
		sleep 1;
		$waited++;

		# Try to reap
		waitpid( $pid, WNOHANG );
	}

	# If the process is still alive, kill it with force
	if ( $class->is_alive($pid) ) {
		kill 'KILL', $pid;
		sleep 1;
		waitpid( $pid, WNOHANG );

		# Final check
		return 0 if $class->is_alive($pid);
	}

	# Reap the zombie
	waitpid( $pid, WNOHANG );

	$on_kill->() if $on_kill;
	return 1;
}

# $class->reap($pid):
#	Try to reap a zombie process.
#	The method returns 1 if the process is reaped or does not
#	exist. It returns 0 if the process still runs.
sub reap ( $class, $pid )
{
	return 1 unless defined $pid;
	return 1 unless $pid =~ /^\d+$/;

	my $result = waitpid( $pid, WNOHANG );

	# $result > 0: waitpid reaped the child
	# $result == -1: there is no such child
	# $result == 0: the child still runs
	return $result != 0;
}

# $class->reap_all():
#	Reap all zombie children without blocking.
#	The method returns the count of reaped children.
sub reap_all ($class)
{
	my $count = 0;
	while ( waitpid( -1, WNOHANG ) > 0 ) {
		$count++;
	}
	return $count;
}

# $class->wait_exit($pid, $timeout):
#	Wait for the process to exit.
#	The method returns 1 if the process exits. It returns 0 on
#	timeout.
sub wait_exit ( $class, $pid, $timeout = 30 )
{
	my $start = time;
	while ( time - $start < $timeout ) {
		return 1 unless $class->is_alive($pid);
		select undef, undef, undef, 0.1;    # Sleep 100ms
	}

	# Final check
	return $class->is_alive($pid) ? 0 : 1;
}

# $class->spawn_perl(%args):
#	Spawn a Perl subprocess that inherits the parent's @INC paths.
#	This is a convenience wrapper around spawn_command() to run
#	Perl code.
#
#	%args:
#		code      => $string    # Required: the Perl code to execute
#		args      => \@args     # Optional: arguments for the code
#		The method passes all other args to spawn_command().
#
#	Example:
#		FuguLib::Process->spawn_perl(
#			code => 'use MyModule; MyModule->run(@ARGV)',
#			args => [$port, $dir],
#			daemonize => 1,
#		);
sub spawn_perl ( $class, %args )
{
	my $code = delete $args{code}
	    or return { success => 0, error => 'No code specified' };
	my $extra_args = delete $args{args} // [];

	# Build the -I flags for all non-default @INC paths
	my @inc_flags = map { "-I$_" } _custom_inc_paths();

	$args{cmd} = [ $^X, @inc_flags, '-e', $code, @$extra_args ];

	return $class->spawn_command(%args);
}

# _custom_inc_paths:
#	Get the @INC paths that are not part of Perl's default
#	installation. These paths usually come from -I, use lib, or
#	PERL5LIB.
sub _custom_inc_paths()
{
	require Config;

	# Build the set of default Perl lib paths
	my %default_paths;
	for my $key (qw(privlib archlib sitelib sitearch vendorlib vendorarch))
	{
		my $path = $Config::Config{$key};
		$default_paths{$path} = 1 if defined $path && length $path;
	}

	# Return the @INC paths that are not in the default set.
	# Skip '.' and CODE refs.
	my @custom;
	for my $inc (@INC) {
		next if ref $inc;               # Skip CODE refs
		next if $inc eq '.';            # Skip the current directory
		next if $default_paths{$inc};
		push @custom, $inc;
	}

	return @custom;
}

1;
