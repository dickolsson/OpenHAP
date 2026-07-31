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

package FuguVM::SSH;

use Net::SSH2;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_TRUNC);
use FuguLib::Signal;

use constant {
	EXIT_SUCCESS    => 0,
	EXIT_ERROR      => 1,
	DEFAULT_TIMEOUT => 10,
	BUFFER_SIZE     => 32768,
};

sub new ( $class, %args )
{
	my $self = bless {
		host     => $args{host} // '127.0.0.1',
		port     => $args{port} // 22,
		user     => $args{user} // 'root',
		password => $args{password},
		timeout  => $args{timeout} // DEFAULT_TIMEOUT,
	}, $class;

	return $self;
}

# $self->_connect:
#	Establish SSH connection and authenticate using SSH agent
#	or password fallback. Returns Net::SSH2 object on success.
sub _connect ($self)
{
	my $ssh2 = Net::SSH2->new;
	$ssh2->timeout( $self->{timeout} * 1000 );    # milliseconds

	if ( !$ssh2->connect( $self->{host}, $self->{port} ) ) {
		return;
	}

	# Try SSH agent authentication first if SSH_AUTH_SOCK is set
	if ( defined $ENV{SSH_AUTH_SOCK} ) {
		if ( $ssh2->auth_agent( $self->{user} ) ) {
			return $ssh2;
		}
	}

	# Fallback to password authentication if provided
	if ( defined $self->{password} ) {
		if ( $ssh2->auth_password( $self->{user}, $self->{password} ) )
		{
			return $ssh2;
		}
	}

	$ssh2->disconnect;
	return;
}

sub wait_available ( $self, $timeout = 120, $sig = undef )
{
	my $start = time;

	while ( time - $start < $timeout ) {

		# Check for interrupt if signal handler provided
		if ( defined $sig && FuguLib::Signal::check_interrupted() ) {
			return 0;
		}

		my $ssh2 = $self->_connect;
		if ( defined $ssh2 ) {
			$ssh2->disconnect;
			return 1;
		}
		sleep 2;
	}

	return 0;
}

sub run_command ( $self, $command )
{
	my $ssh2 = $self->_connect;
	if ( !defined $ssh2 ) {
		return {
			stdout    => '',
			stderr    => 'Failed to connect',
			exit_code => 1,
		};
	}

	my $channel = $ssh2->channel;
	if ( !defined $channel ) {
		$ssh2->disconnect;
		return {
			stdout    => '',
			stderr    => 'Failed to open channel',
			exit_code => 1,
		};
	}

	$channel->exec($command);

	my $stdout = '';
	my $stderr = '';

	# Read stdout
	while ( !$channel->eof ) {
		my $buf;
		my $len = $channel->read( $buf, BUFFER_SIZE );
		last if !defined $len || $len <= 0;
		$stdout .= $buf;
	}

	# Read stderr
	while (1) {
		my $buf;
		my $len =
		    $channel->read( $buf, BUFFER_SIZE, 1 );   # ext=1 for stderr
		last if !defined $len || $len <= 0;
		$stderr .= $buf;
	}

	$channel->wait_closed;
	my $exit_code = $channel->exit_status // 255;

	$channel->close;
	$ssh2->disconnect;

	return {
		stdout    => $stdout,
		stderr    => $stderr,
		exit_code => $exit_code,
	};
}

sub interactive ($self)
{
	# For interactive sessions, fall back to system ssh command
	# Net::SSH2 doesn't provide proper TTY handling for interactive use
	my @cmd = (
		'ssh',
		'-o',
		'StrictHostKeyChecking=no',
		'-o',
		'UserKnownHostsFile=/dev/null',
		'-o',
		'LogLevel=ERROR',
		'-p',
		$self->{port},
		"$self->{user}\@$self->{host}",
	);

	# Return the child's exit code, not the raw wait status: callers
	# (and ultimately the fuguvm exit status) expect a 0-255 code. A
	# raw status of, say, 256 for a remote exit code of 1 would become
	# exit(256) -> 0, silently turning a failed remote command (e.g. a
	# failing `prove` run driven over stdin) into success.
	return _exit_code( system(@cmd) );
}

# _exit_code($status):
#	Map a raw system()/$? wait status to a 0-255 exit code: the low
#	byte encodes the terminating signal, the high byte the exit code.
#	system() returns -1 when the child could not be run at all.
sub _exit_code ($status)
{
	return EXIT_ERROR               if $status == -1;
	return 128 + ( $status & 0x7f ) if $status & 0x7f;
	return $status >> 8;
}

# $self->write_file($remote_path, $content, $mode):
#	Write content directly to a remote file via SFTP
sub write_file ( $self, $remote_path, $content, $mode = 0644 )
{
	my $ssh2 = $self->_connect;
	if ( !defined $ssh2 ) {
		return EXIT_ERROR;
	}

	my $sftp = $ssh2->sftp;
	if ( !defined $sftp ) {
		$ssh2->disconnect;
		return EXIT_ERROR;
	}

	my $remote_fh =
	    $sftp->open( $remote_path, O_WRONLY | O_CREAT | O_TRUNC, $mode );

	if ( !defined $remote_fh ) {
		$ssh2->disconnect;
		return EXIT_ERROR;
	}

	$remote_fh->write($content);
	undef $remote_fh;    # Close file handle
	$ssh2->disconnect;

	return EXIT_SUCCESS;
}

# $self->make_remote_dir($remote_path, $mode):
#	Create a remote directory
sub make_remote_dir ( $self, $remote_path, $mode = 0755 )
{
	my $ssh2 = $self->_connect;
	if ( !defined $ssh2 ) {
		return EXIT_ERROR;
	}

	my $sftp = $ssh2->sftp;
	if ( !defined $sftp ) {
		$ssh2->disconnect;
		return EXIT_ERROR;
	}

	my $result = $sftp->mkdir( $remote_path, $mode );
	$ssh2->disconnect;

	return $result ? EXIT_SUCCESS : EXIT_ERROR;
}

sub is_available ($self)
{
	my $ssh2 = $self->_connect;
	if ( !defined $ssh2 ) {
		return 0;
	}
	$ssh2->disconnect;
	return 1;
}

1;
