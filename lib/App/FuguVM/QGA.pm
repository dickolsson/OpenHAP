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

package App::FuguVM::QGA;

use Fugu::JSONSocket;
use Fugu::Util;
use JSON::PP ();

# App::FuguVM::QGA - the QEMU Guest Agent command set.
#
# The transport is Fugu::JSONSocket. This file holds only what is
# true of the guest agent: it sends no greeting, and its commands are
# the filesystem operations that a clean shutdown needs.

use constant {
	READ_TIMEOUT => 30,
	EXEC_TIMEOUT => 10,
};

sub new ( $class, $socket_path )
{
	return bless {
		socket => Fugu::JSONSocket->new(
			path    => $socket_path,
			timeout => READ_TIMEOUT,
		),
	}, $class;
}

sub socket_path ($self)
{
	return $self->{socket}->path;
}

# $self->is_available:
#	Report if the socket file is there.
sub is_available ($self)
{
	return $self->{socket}->exists;
}

# $self->open_connection:
#	Connect. The agent sends no greeting, so there is nothing to
#	read before the first command. The method returns 1 on success
#	and 0 on failure.
sub open_connection ($self)
{
	return 1 if $self->{socket}->is_connected;

	return $self->{socket}->connect ? 1 : 0;
}

sub disconnect ($self)
{
	$self->{socket}->disconnect;
	return $self;
}

# $self->run_command($command, $arguments):
#	Run one guest-agent command and return the whole reply.
sub run_command ( $self, $command, $arguments = undef )
{
	my %message = ( execute => $command );
	$message{arguments} = $arguments if defined $arguments;

	return $self->{socket}->request( \%message );
}

# $self->sync:
#	Sync the guest filesystems, so that every buffer reaches the
#	disk. The method returns true on success.
#
#	guest-sync synchronizes the protocol, not the filesystems.
#	Thus the real sync goes through guest-exec.
sub sync ($self)
{
	my $result = $self->run_command(
		'guest-exec',
		{
			path             => '/bin/sync',
			'capture-output' => JSON::PP::false,
		} );
	return 0 if !defined $result || exists $result->{error};

	my $pid = $result->{return}{pid};
	return 0 if !defined $pid;

	# Wait for the command to finish. A guest that never answers
	# must not hold the caller for ever.
	my $exit = Fugu::Util::wait_until(
		EXEC_TIMEOUT,
		0.1,
		sub {
			my $status = $self->run_command( 'guest-exec-status',
				{ pid => $pid } );
			return 'failed'
			    if !defined $status || exists $status->{error};
			return unless $status->{return}{exited};
			return $status->{return}{exitcode} == 0
			    ? 'ok'
			    : 'failed';
		} );

	return defined $exit && $exit eq 'ok' ? 1 : 0;
}

# $self->freeze_filesystems:
#	Freeze all mounted filesystems, so a snapshot sees them
#	quiescent. The method returns the number of frozen filesystems,
#	or undef on failure.
sub freeze_filesystems ($self)
{
	my $result = $self->run_command('guest-fsfreeze-freeze');
	return if !defined $result || exists $result->{error};

	return $result->{return};
}

# $self->thaw_filesystems:
#	Thaw all frozen filesystems. The method returns the number of
#	thawed filesystems, or undef on failure.
sub thaw_filesystems ($self)
{
	my $result = $self->run_command('guest-fsfreeze-thaw');
	return if !defined $result || exists $result->{error};

	return $result->{return};
}

# $self->fsfreeze_status:
#	Return 'thawed', 'frozen', or undef on failure.
sub fsfreeze_status ($self)
{
	my $result = $self->run_command('guest-fsfreeze-status');
	return if !defined $result || exists $result->{error};

	return $result->{return};
}

# $self->ping:
#	Check if the guest agent answers
sub ping ($self)
{
	my $result = $self->run_command('guest-ping');

	return defined $result && !exists $result->{error};
}

# $self->shutdown($mode):
#	Ask the guest to shut down. $mode is 'powerdown' (the default),
#	'halt' or 'reboot'.
#
#	The command sends no reply: the guest goes down at once. Thus
#	the method reports success as soon as the request is away.
sub shutdown ( $self, $mode = 'powerdown' )
{
	$self->{socket}->send_message(
		{ execute => 'guest-shutdown', arguments => { mode => $mode } }
	);

	return 1;
}

1;
