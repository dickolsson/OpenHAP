# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2025 Dick Olsson <hi@senzilla.io>
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

package OpenHAP::Daemon;

# OpenHAP::Daemon is now a wrapper around FuguLib for backward compatibility
use FuguLib::Daemon;
use FuguLib::State;

# $class->daemonize($logfile):
#	Fork into background, detach from terminal, and redirect
#	standard file descriptors. Returns in child process only.
#	Parent process exits successfully.
sub daemonize ( $class, $logfile = '/var/log/openhapd.log' )
{
	FuguLib::Daemon->daemonize( logfile => $logfile );
	$OpenHAP::logger->debug( 'Daemonized successfully, PID: %d', $$ )
	    if $OpenHAP::logger;
	return;
}

# $class->write_pidfile($path):
#	Write current PID to file. Returns true on success.
sub write_pidfile ( $class, $path )
{
	my $state = FuguLib::State->new( pidfile => $path );
	unless ( $state->write_pid($$) ) {
		$OpenHAP::logger->error( 'Cannot write PID file %s', $path )
		    if $OpenHAP::logger;
		return;
	}
	$OpenHAP::logger->debug( 'Wrote PID %d to %s', $$, $path )
	    if $OpenHAP::logger;
	return 1;
}

# $class->read_pidfile($path):
#	Read PID from file. Returns PID or undef if file doesn't exist
#	or cannot be read.
sub read_pidfile ( $class, $path )
{
	my $state = FuguLib::State->new( pidfile => $path );
	my $pid   = $state->read_pid();
	return $pid;
}

# $class->check_running($pidfile):
#	Check if daemon is running based on PID file.
#	Returns PID if running, undef otherwise.
sub check_running ( $class, $pidfile )
{
	my $state = FuguLib::State->new($pidfile);
	return $state->is_running() ? $state->read_pid() : undef;
}

1;
