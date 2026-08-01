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
# The module talks to the QEMU Guest Agent that runs inside the VM.
# FuguVM uses it for reliable filesystem operations before shutdown.
# These operations are freeze, thaw, and sync.

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
#	Run a QGA command. The method returns the result.
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
#	Read one line without its terminator. The method returns undef
#	on timeout, EOF, or read error. IO::Select bounds the read
#	against a wall-clock deadline. The timeout() of IO::Socket
#	governs only its own connect and accept. Thus a bare readline
#	here blocks forever when nothing answers. Nothing answers when
#	the guest runs no agent. The socket then stays open and silent,
#	because QEMU, not the guest, serves it.
#
#	Bytes after the newline stay in the buffer for the next call.
#	Thus the method does not lose a reply that arrives in the same
#	segment as the next one.
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
#	Sync the guest filesystems. The operation flushes all buffers
#	to the disk. The method returns true on success.
sub sync ($self)
{
	# The guest-sync command synchronizes the protocol, not the
	# filesystems. The module uses guest-exec to run the sync
	# command for the real filesystem sync.
	return $self->_exec_sync_command;
}

sub _exec_sync_command ($self)
{
	# Run the 'sync' command in the guest
	my $result = $self->run_command(
		'guest-exec',
		{
			path             => '/bin/sync',
			'capture-output' => JSON::XS::false,
		} );

	return 0 if !defined $result || exists $result->{error};

	my $pid = $result->{return}{pid};
	return 0 if !defined $pid;

	# Wait until the command completes
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
#	Freeze all mounted filesystems. This makes them quiescent for a
#	snapshot. The method returns the number of frozen filesystems
#	on success and undef on failure.
sub freeze_filesystems ($self)
{
	my $result = $self->run_command('guest-fsfreeze-freeze');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->thaw_filesystems:
#	Thaw all frozen filesystems. The method returns the number of
#	thawed filesystems on success and undef on failure.
sub thaw_filesystems ($self)
{
	my $result = $self->run_command('guest-fsfreeze-thaw');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->fsfreeze_status:
#	Get the current filesystem freeze status. The method returns
#	'thawed', 'frozen', or undef on error.
sub fsfreeze_status ($self)
{
	my $result = $self->run_command('guest-fsfreeze-status');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->ping:
#	Check if the guest agent responds
sub ping ($self)
{
	my $result = $self->run_command('guest-ping');
	return defined $result && !exists $result->{error};
}

# $self->shutdown($mode):
#	Ask the guest to shut down
#	$mode: 'powerdown' (default), 'halt', or 'reboot'
sub shutdown ( $self, $mode = 'powerdown' )
{
	my $result = $self->run_command( 'guest-shutdown', { mode => $mode } );

	# The guest-shutdown command returns no response on success.
	# The guest shuts down immediately.
	return 1;
}

1;
