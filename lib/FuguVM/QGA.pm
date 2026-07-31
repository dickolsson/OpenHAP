# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2024 Dick Olsson <hi@senzilla.io>
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

# FuguVM::QGA - QEMU Guest Agent client
#
# Provides communication with QEMU Guest Agent running inside the VM.
# Used for reliable filesystem operations (freeze/thaw/sync) before shutdown.

package FuguVM::QGA;

use IO::Select;
use IO::Socket::UNIX;
use JSON::XS;
use Time::HiRes qw(time);

use constant {
	CONNECT_TIMEOUT => 5,
	READ_TIMEOUT    => 30,
	READ_CHUNK      => 4096,
};

sub new ( $class, $socket_path )
{
	bless {
		socket_path => $socket_path,
		sock        => undef,
		connected   => 0,
		sync_id     => 0,
		buffer      => '',
	}, $class;
}

sub socket_path ($self) { $self->{socket_path} }

sub open_connection ($self)
{
	return 1 if $self->{connected};

	my $sock = IO::Socket::UNIX->new(
		Type    => SOCK_STREAM,
		Peer    => $self->{socket_path},
		Timeout => CONNECT_TIMEOUT,
	);

	if ( !defined $sock ) {
		return 0;
	}

	$self->{sock}      = $sock;
	$self->{connected} = 1;

	return 1;
}

sub disconnect ($self)
{
	if ( $self->{sock} ) {
		close $self->{sock};
		$self->{sock} = undef;
	}
	$self->{connected} = 0;
	$self->{buffer}    = '';
	return $self;
}

sub is_available ($self)
{
	return -S $self->{socket_path};
}

# $self->run_command($command, $arguments):
#	Execute a QGA command and return the result
sub run_command ( $self, $command, $arguments = undef )
{
	return if !$self->{sock};

	my $cmd = { execute => $command };
	$cmd->{arguments} = $arguments if defined $arguments;

	my $json = encode_json($cmd) . "\n";
	my $sock = $self->{sock};

	print $sock $json or return;

	return $self->_read_response;
}

sub _read_response ($self)
{
	my $line = $self->_read_line(READ_TIMEOUT);
	return if !defined $line || $line eq '';

	my $response;
	eval { $response = decode_json($line); };
	if ($@) {
		warn "QGA: Invalid JSON: $@";
		return;
	}

	return $response;
}

# $self->_read_line($timeout):
#	One line without its terminator, or undef on timeout, EOF or read
#	error. Bounded with IO::Select against a wall-clock deadline:
#	IO::Socket's timeout() governs only its own connect and accept, so a
#	bare readline here blocks forever whenever nothing answers - and
#	nothing answers whenever the guest runs no agent, which leaves the
#	socket open and silent because QEMU, not the guest, serves it.
#
#	Bytes past the newline stay buffered for the next call, so a reply
#	that arrives in the same segment as the following one is not lost.
sub _read_line ( $self, $timeout )
{
	my $sock = $self->{sock};
	return if !$sock;

	my $deadline = time + $timeout;
	my $select   = IO::Select->new($sock);

	while (1) {
		my $nl = index $self->{buffer}, "\n";
		if ( $nl >= 0 ) {
			my $line = substr $self->{buffer}, 0, $nl;
			substr $self->{buffer}, 0, $nl + 1, '';
			return $line;
		}

		my $remaining = $deadline - time;
		return if $remaining <= 0;
		return if !$select->can_read($remaining);

		my $chunk = '';
		my $read  = sysread $sock, $chunk, READ_CHUNK;
		return if !defined $read || $read == 0;

		$self->{buffer} .= $chunk;
	}
}

# High-level commands

# $self->sync:
#	Sync guest filesystems (flush all buffers to disk)
#	Returns true on success
sub sync ($self)
{
	# guest-sync is used to synchronize the protocol, not filesystems
	# We use guest-exec to run sync command for actual filesystem sync
	return $self->_exec_sync_command;
}

sub _exec_sync_command ($self)
{
	# Execute 'sync' command in guest
	my $result = $self->run_command(
		'guest-exec',
		{
			path             => '/bin/sync',
			'capture-output' => JSON::XS::false,
		} );

	return 0 if !defined $result || exists $result->{error};

	my $pid = $result->{return}{pid};
	return 0 if !defined $pid;

	# Wait for completion
	my $start = time;
	while ( time - $start < 10 ) {
		my $status =
		    $self->run_command( 'guest-exec-status', { pid => $pid } );
		return 0 if !defined $status || exists $status->{error};

		if ( $status->{return}{exited} ) {
			return $status->{return}{exitcode} == 0;
		}
		select( undef, undef, undef, 0.1 );
	}

	return 0;    # Timeout
}

# $self->freeze_filesystems:
#	Freeze all mounted filesystems (quiesce for snapshot)
#	Returns number of frozen filesystems on success, undef on failure
sub freeze_filesystems ($self)
{
	my $result = $self->run_command('guest-fsfreeze-freeze');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->thaw_filesystems:
#	Thaw all frozen filesystems
#	Returns number of thawed filesystems on success, undef on failure
sub thaw_filesystems ($self)
{
	my $result = $self->run_command('guest-fsfreeze-thaw');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->fsfreeze_status:
#	Get current filesystem freeze status
#	Returns 'thawed', 'frozen', or undef on error
sub fsfreeze_status ($self)
{
	my $result = $self->run_command('guest-fsfreeze-status');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->ping:
#	Check if guest agent is responsive
sub ping ($self)
{
	my $result = $self->run_command('guest-ping');
	return defined $result && !exists $result->{error};
}

# $self->shutdown($mode):
#	Request guest to shutdown
#	$mode: 'powerdown' (default), 'halt', or 'reboot'
sub shutdown ( $self, $mode = 'powerdown' )
{
	my $result = $self->run_command( 'guest-shutdown', { mode => $mode } );

	# guest-shutdown doesn't return a response on success
	# (the guest shuts down immediately)
	return 1;
}

1;
