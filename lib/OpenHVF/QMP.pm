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

# OpenHVF::QMP - QEMU Machine Protocol client
#
# Provides programmatic control over QEMU via the QMP JSON protocol.
# Connects to QEMU's QMP socket for reliable VM lifecycle management.

package OpenHVF::QMP;

use IO::Select;
use IO::Socket::UNIX;
use JSON::XS;
use Time::HiRes qw(time);

use constant {
	CONNECT_TIMEOUT => 5,
	READ_TIMEOUT    => 10,
	READ_CHUNK      => 4096,
};

sub new ( $class, $socket_path )
{
	bless {
		socket_path => $socket_path,
		sock        => undef,
		connected   => 0,
		buffer      => '',
	}, $class;
}

sub open_connection ($self)
{
	return 1 if $self->{connected};

	my $sock = IO::Socket::UNIX->new(
		Type    => SOCK_STREAM,
		Peer    => $self->{socket_path},
		Timeout => CONNECT_TIMEOUT,
	);

	return 0 if !defined $sock;

	$self->{sock} = $sock;

	# Read greeting
	my $greeting = $self->_read_response;
	if ( !defined $greeting || !exists $greeting->{QMP} ) {
		$self->disconnect;
		return 0;
	}

	# Send qmp_capabilities to enter command mode
	my $result = $self->run_command('qmp_capabilities');
	if ( !defined $result ) {
		$self->disconnect;
		return 0;
	}

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

# $self->run_command($command, $arguments):
#	Execute a QMP command and return the result
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
		warn "QMP: Invalid JSON: $@";
		return;
	}

	return $response;
}

# $self->_read_line($timeout):
#	One line without its terminator, or undef on timeout, EOF or read
#	error. Bounded with IO::Select against a wall-clock deadline:
#	IO::Socket's timeout() governs only its own connect and accept, so a
#	bare readline here blocks forever whenever QEMU stops answering on
#	an otherwise open socket.
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

# $self->query_status:
#	Query VM running status
#	Returns hashref with 'running' and 'status' keys
sub query_status ($self)
{
	my $result = $self->run_command('query-status');
	return if !defined $result || exists $result->{error};
	return $result->{return};
}

# $self->is_running:
#	Check if VM is currently running
sub is_running ($self)
{
	my $status = $self->query_status;
	return 0 if !defined $status;
	return $status->{running} ? 1 : 0;
}

# $self->powerdown:
#	Request graceful guest shutdown via ACPI
sub powerdown ($self)
{
	my $result = $self->run_command('system_powerdown');
	return defined $result && !exists $result->{error};
}

# $self->quit:
#	Immediately terminate QEMU process
sub quit ($self)
{
	my $result = $self->run_command('quit');
	$self->disconnect;
	return defined $result && !exists $result->{error};
}

1;
