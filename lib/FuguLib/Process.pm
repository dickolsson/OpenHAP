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
# Handles forking, exec, PID tracking, signal handling, and zombie reaping
# with proper error detection and logging integration.

# $class->spawn_command(%args):
#	Fork and execute a command, optionally as a daemon
#	Returns hashref with {pid => $pid, success => 1} on success,
#	or {success => 0, error => $msg} on failure
#
#	%args:
#		cmd       => \@command  # Required: command to execute
#		daemonize => 0|1        # Optional: detach from terminal
#		stdout    => $path|undef # Optional: redirect stdout (default: /dev/null)
#		stderr    => $path|undef # Optional: redirect stderr (default: /dev/null)
#		stdin     => $path|undef # Optional: redirect stdin (default: /dev/null)
#		on_error  => sub($err)  # Optional: error callback
#		on_success => sub($pid) # Optional: success callback
#		check_alive => $seconds # Optional: wait and verify process is alive
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

			# Become session leader
			setsid() or exit 1;
		}

		# Redirect file descriptors
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

		# Execute command
		exec @$cmd or exit 1;
	}

	# Parent process
	if ($check_alive) {

		# Give process time to start
		sleep $check_alive;

	      # Try to reap zombie without blocking (is_alive would do this too)
		my $reaped = waitpid( $pid, WNOHANG );

		# If we reaped the process, it died
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

		# Double-check with kill(0) to ensure process is alive
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
#	Check if process is alive (not dead, not zombie)
#	Returns 1 if alive, 0 if dead or doesn't exist or zombie
sub is_alive ( $class, $pid )
{
	return 0 unless defined $pid;
	return 0 unless $pid =~ /^\d+$/;

	# First check if process exists
	return 0 unless kill( 0, $pid );

	# Don't try to wait on ourselves
	return 1 if $pid == $$;

	# Try to reap zombies without blocking
	my $result = waitpid( $pid, WNOHANG );

	# If waitpid returned the PID, it was a zombie and is now reaped
	return 0 if $result == $pid;

	# If waitpid returned -1, no such child (not our child, but still alive)
	#return 0 if $result == -1;

	# Otherwise, process is alive
	return 1;
}

# $class->terminate($pid, %args):
#	Terminate a process gracefully, with force if needed
#	Returns 1 if process was killed or is dead, 0 on failure
#
#	%args:
#		grace_period => $seconds # Time to wait after TERM before KILL (default: 5)
#		on_kill      => sub()    # Called after successful kill
sub terminate ( $class, $pid, %args )
{
	return 1 unless defined $pid;
	return 1 unless $class->is_alive($pid);

	my $grace_period = $args{grace_period} // 5;
	my $on_kill      = $args{on_kill};

	# Send SIGTERM
	my $killed = kill 'TERM', $pid;
	unless ($killed) {

		# Process already dead or no permission
		return $class->is_alive($pid) ? 0 : 1;
	}

	# Wait for process to exit
	my $waited = 0;
	while ( $waited < $grace_period && $class->is_alive($pid) ) {
		sleep 1;
		$waited++;

		# Try to reap
		waitpid( $pid, WNOHANG );
	}

	# If still alive, force kill
	if ( $class->is_alive($pid) ) {
		kill 'KILL', $pid;
		sleep 1;
		waitpid( $pid, WNOHANG );

		# Final check
		return 0 if $class->is_alive($pid);
	}

	# Reap zombie
	waitpid( $pid, WNOHANG );

	$on_kill->() if $on_kill;
	return 1;
}

# $class->reap($pid):
#	Attempt to reap a zombie process
#	Returns 1 if process was reaped or doesn't exist, 0 if still running
sub reap ( $class, $pid )
{
	return 1 unless defined $pid;
	return 1 unless $pid =~ /^\d+$/;

	my $result = waitpid( $pid, WNOHANG );

	# $result > 0: child was reaped
	# $result == -1: no such child
	# $result == 0: child still running
	return $result != 0;
}

# $class->reap_all():
#	Reap all zombie children (non-blocking)
#	Returns count of children reaped
sub reap_all ($class)
{
	my $count = 0;
	while ( waitpid( -1, WNOHANG ) > 0 ) {
		$count++;
	}
	return $count;
}

# $class->wait_exit($pid, $timeout):
#	Wait for process to exit
#	Returns 1 if process exited, 0 if timeout
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
#	Spawn a Perl subprocess with the parent's @INC paths inherited
#	This is a convenience wrapper around spawn_command() for running Perl code
#
#	%args:
#		code      => $string    # Required: Perl code to execute
#		args      => \@args     # Optional: arguments passed to the code
#		All other args are passed to spawn_command()
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

	# Build -I flags for all non-default @INC paths
	my @inc_flags = map { "-I$_" } _custom_inc_paths();

	$args{cmd} = [ $^X, @inc_flags, '-e', $code, @$extra_args ];

	return $class->spawn_command(%args);
}

# _custom_inc_paths:
#	Get @INC paths that are not part of Perl's default installation
#	These are typically paths added via -I, use lib, or PERL5LIB
sub _custom_inc_paths()
{
	require Config;

	# Build set of default Perl lib paths
	my %default_paths;
	for my $key (qw(privlib archlib sitelib sitearch vendorlib vendorarch))
	{
		my $path = $Config::Config{$key};
		$default_paths{$path} = 1 if defined $path && length $path;
	}

	# Return @INC paths not in the default set (excluding '.' and CODE refs)
	my @custom;
	for my $inc (@INC) {
		next if ref $inc;               # Skip CODE refs
		next if $inc eq '.';            # Skip current directory
		next if $default_paths{$inc};
		push @custom, $inc;
	}

	return @custom;
}

1;
