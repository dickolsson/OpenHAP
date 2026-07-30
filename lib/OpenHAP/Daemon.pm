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
use Config;
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

# $class->unveil_paths(%args):
#	db_path     => $dir	pairing and device state (required)
#	config_file => $file	configuration file (optional on disk)
#	log_file    => $file	daemon-mode log (optional on disk)
#	script_lib  => $dir	the daemon's ../lib, included only when
#				it is a source checkout
#	perl_dirs   => \@dirs	override the perl library directories
#				(tests only)
#	The daemon's unveil(2) inventory: an ordered list of
#	[$path, $perms] pairs with per-path dispositions, for
#	FuguLib::Sandbox->unveil. Pure assembly - nothing here touches
#	the filesystem view - so it is unit-testable on any platform.
#
#	Every entry is required (absent means a broken install and
#	startup must fail naming the path) or optional (legitimately
#	absent on a working system: a fresh install has no config
#	file, -f mode never creates the log file, mdnsd may not run,
#	and the resolver files matter only when mqtt_host is a name).
#	Getting a disposition wrong turns a configuration that starts
#	today into a startup failure.
sub unveil_paths ( $class, %args )
{
	my $db_path     = $args{db_path} or die 'db_path parameter required';
	my $config_file = $args{config_file};
	my $log_file    = $args{log_file} // '/var/log/openhapd.log';

	my @paths = ( [ $db_path, 'rwc' ], [ '/dev/urandom', 'r' ], );

	# The perl library tree, read-only, for the lazy require on the
	# MQTT reconnect path. An enumerated list, never live @INC:
	# bin/openhapd prepends $RealBin/../lib, which on an installed
	# layout is /usr/local/lib - every third-party library on the
	# system, not a perl tree - and OpenHAP::MQTT unshifts a
	# directory onto @INC at connect time, so a derived set would
	# depend on whether the startup connect has run. Unveiling the
	# tree read-only is the deliberate trade: proving no module
	# ever loads late is a claim no test can hold over time, while
	# these few read-only lines cannot regress the MQTT reconnect.
	my @perl_dirs =
	    $args{perl_dirs} ? @{ $args{perl_dirs} } : _perl_lib_dirs();

	# The checkout's own lib, only when it really is one: the
	# installed layout must not pick up /usr/local/lib here
	my $script_lib = $args{script_lib};
	push @perl_dirs, $script_lib
	    if defined $script_lib && -d "$script_lib/OpenHAP";

	my %seen;
	push @paths, map { [ $_, 'r' ] } grep { !$seen{$_}++ } @perl_dirs;

	push @paths, [ $config_file, 'r', { optional => 1 } ]
	    if defined $config_file;
	push @paths,
	    [ $log_file, 'w', { optional => 1 } ],
	    [ '/var/run/mdnsd.sock', 'rw', { optional => 1 } ],
	    [ '/etc/resolv.conf',    'r',  { optional => 1 } ],
	    [ '/etc/hosts',          'r',  { optional => 1 } ],
	    [ '/etc/services',       'r',  { optional => 1 } ],
	    [ '/etc/protocols',      'r',  { optional => 1 } ],
	    [ '/etc/localtime',      'r',  { optional => 1 } ];

	return @paths;
}

# _perl_lib_dirs():
#	The perl library directories as the interpreter was built with
#	them - stable facts from %Config, not runtime @INC. The
#	literal site_perl entry is the directory OpenHAP::MQTT
#	unshifts onto @INC at connect time; on OpenBSD it equals
#	sitelibexp and dedupes away.
sub _perl_lib_dirs ()
{
	my @dirs;
	for my $key (qw(privlibexp archlibexp sitelibexp sitearchexp)) {
		my $dir = $Config{$key};
		push @dirs, $dir if defined $dir && length $dir;
	}
	push @dirs, '/usr/local/libdata/perl5/site_perl';

	return @dirs;
}

1;
