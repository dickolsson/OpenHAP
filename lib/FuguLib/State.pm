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

package FuguLib::State;

use Fcntl qw(:flock);
use FuguLib::Process;

# FuguLib::State - Simple PID file management
#
# Provides safe PID file reading/writing with locking and stale PID detection.

sub new ( $class, $pidfile )
{
	return unless defined $pidfile;

	bless {
		pidfile => $pidfile,
		locked  => 0,
	}, $class;
}

# $self->write_pid($pid):
#	Write PID to file with exclusive lock
#	Returns 1 on success, 0 on failure
sub write_pid ( $self, $pid = $$ )
{
	my $pidfile = $self->{pidfile};

	open my $fh, '>', $pidfile or return 0;
	flock( $fh, LOCK_EX ) or do {
		close $fh;
		return 0;
	};

	print $fh "$pid\n";
	close $fh;
	return 1;
}

# $self->read_pid():
#	Read PID from file
#	Returns PID or undef if not found or invalid
sub read_pid ($self)
{
	my $pidfile = $self->{pidfile};
	return unless -f $pidfile;

	open my $fh, '<', $pidfile or return;
	my $pid = <$fh>;
	close $fh;

	return unless defined $pid;
	chomp $pid;
	return unless $pid =~ /^\d+$/;
	return $pid;
}

# $self->remove():
#	Remove PID file
sub remove ($self)
{
	my $pidfile = $self->{pidfile};
	return 1 unless -f $pidfile;
	return unlink $pidfile;
}

# $self->is_running():
#	Check if process from PID file is running
#	Returns PID if running, undef otherwise
sub is_running ($self)
{
	my $pid = $self->read_pid;
	return unless defined $pid;
	return unless FuguLib::Process->is_alive($pid);
	return $pid;
}

# $self->is_stale():
#	Check if PID file is stale (process not running)
sub is_stale ($self)
{
	my $pid = $self->read_pid;
	return 0 unless defined $pid;
	return !FuguLib::Process->is_alive($pid);
}

1;
