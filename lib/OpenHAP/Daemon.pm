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
use FuguLib::Pidfile;
use FuguLib::Sandbox;

# $class->daemonize($logfile):
#	Fork into the background. Detach from the terminal. Redirect
#	the standard file descriptors. The method returns in the
#	child process only. The parent process exits successfully.
sub daemonize ( $class, $logfile = '/var/log/openhapd.log' )
{
	FuguLib::Daemon->daemonize( logfile => $logfile );
	$OpenHAP::logger->debug( 'Daemonized successfully, PID: %d', $$ )
	    if $OpenHAP::logger;
	return;
}

# $class->write_pidfile($path):
#	Write the current PID to the file. The method returns true
#	on success.
sub write_pidfile ( $class, $path )
{
	my $pidfile = FuguLib::Pidfile->new( path => $path );
	unless ( $pidfile->write_pid($$) ) {
		$OpenHAP::logger->error( 'Cannot write PID file %s', $path )
		    if $OpenHAP::logger;
		return;
	}
	$OpenHAP::logger->debug( 'Wrote PID %d to %s', $$, $path )
	    if $OpenHAP::logger;
	return 1;
}

# $class->read_pidfile($path):
#	Read the PID from the file. The method returns the PID. It
#	returns undef if the file does not exist or is not readable.
sub read_pidfile ( $class, $path )
{
	my $pidfile = FuguLib::Pidfile->new( path => $path );
	return $pidfile->read_pid;
}

# $class->check_running($pidfile):
#	Check if the daemon runs. The check uses the PID file.
#	The method returns the PID if the daemon runs. Otherwise,
#	it returns undef.
sub check_running ( $class, $path )
{
	my $pidfile = FuguLib::Pidfile->new( path => $path );
	return $pidfile->is_running;
}

# $class->unveil_paths(%args):
#	db_path     => $dir	pairing and device state (required)
#	config_file => $file	configuration file (optional on disk)
#	log_file    => $file	daemon-mode log (optional on disk)
#	script_lib  => $dir	the daemon's ../lib, included only when
#				it is a source checkout
#	perl_dirs   => \@dirs	override the perl library directories
#				(tests only)
#	The method returns the unveil(2) inventory of the daemon.
#	The inventory is an ordered list of [$path, $perms] pairs
#	for FuguLib::Sandbox->unveil. Each path has its own
#	disposition. The method only assembles data. Nothing here
#	touches the filesystem view. Thus unit tests can run on
#	all platforms.
#
#	Each entry is required or optional. If a required entry is
#	absent, the install is broken. Then startup must fail and
#	name the path. An optional entry can be legitimately absent
#	on a working system. A fresh install has no config file.
#	The -f mode never creates the log file. The mdnsd daemon
#	does not always run. The resolver files matter only when
#	mqtt_host is a name. A wrong disposition turns a
#	configuration that starts today into a startup failure.
sub unveil_paths ( $class, %args )
{
	my $db_path     = $args{db_path} or die 'db_path parameter required';
	my $config_file = $args{config_file};
	my $log_file    = $args{log_file} // '/var/log/openhapd.log';

	my @paths = ( [ $db_path, 'rwc' ] );

	# Unveil the perl library tree read-only for the lazy require
	# on the MQTT reconnect path. Use an enumerated list, never
	# the live @INC. Two reasons apply. First, bin/openhapd
	# prepends $RealBin/../lib. On an installed layout, that is
	# /usr/local/lib. That directory holds every third-party
	# library on the system, not a perl tree. Second,
	# OpenHAP::MQTT unshifts a directory onto @INC at connect
	# time. Thus a derived set would depend on whether the
	# startup connect has run. The read-only unveil of the tree
	# is a deliberate trade. No test can prove over time that no
	# module loads late. But these few read-only lines cannot
	# regress the MQTT reconnect.
	my @perl_dirs =
	    $args{perl_dirs}
	    ? @{ $args{perl_dirs} }
	    : FuguLib::Sandbox->perl_lib_dirs;

	# Add the checkout's own lib directory, but only when it
	# really is a checkout. The installed layout must not pick
	# up /usr/local/lib here.
	my $script_lib = $args{script_lib};
	push @perl_dirs, $script_lib
	    if defined $script_lib && -d "$script_lib/OpenHAP";

	my %seen;
	push @paths, map { [ $_, 'r' ] } grep { !$seen{$_}++ } @perl_dirs;

	push @paths, [ $config_file, 'r', { optional => 1 } ]
	    if defined $config_file;
	push @paths,
	    [ $log_file, 'w', { optional => 1 } ],
	    [ '/var/run/mdnsd.sock', 'rw', { optional => 1 } ];

	# The resolver files, the service tables, the time zone and the
	# random device are the same for every daemon. FuguLib::Sandbox
	# holds that list.
	push @paths, FuguLib::Sandbox->system_paths;

	return @paths;
}

1;
