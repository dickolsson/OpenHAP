# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2025 OpenHAP Contributors
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

package OpenHAP::MDNS;

use FuguLib::Process;

# OpenHAP::MDNS - mDNS service registration wrapper for mdnsctl(8)
#
# This module wraps OpenBSD's mdnsctl(8) command to register HAP services
# with mdnsd(8) for Bonjour/mDNS service discovery.

sub new ( $class, %args )
{
	my $self = bless {
		service_name => $args{service_name} // 'OpenHAP Bridge',
		port         => $args{port}         // 51827,
		txt_records  => $args{txt_records}  // {},
		registered   => 0,
		mdnsctl      => $args{mdnsctl} // scalar _find_mdnsctl(),
		log_dir      => $args{log_dir} // '/var/db/openhapd',
		pid          => undef,
	}, $class;

	return $self;
}

# _find_mdnsctl():
#	Locate mdnsctl binary in common paths
#	Returns path to mdnsctl or undef if not found
sub _find_mdnsctl()
{
	my @paths = qw(
	    /usr/local/bin/mdnsctl
	    /usr/sbin/mdnsctl
	    /usr/bin/mdnsctl
	);

	for my $path (@paths) {
		return $path if -x $path;
	}

	return;
}

# $self->register_service():
#	Register the HAP service with mdnsd via mdnsctl
#	Forks a background process to keep the service registered
#	Returns 1 on success, undef on failure (logs warning)
sub register_service ($self)
{
	return if $self->{registered};

	if ( !defined $self->{mdnsctl} ) {
		$OpenHAP::logger->warning(
'mdnsctl not found - mDNS service registration unavailable'
		);
		return;
	}

    # Build the mdnsctl command
    # Format: mdnsctl publish "Service Name" _hap tcp port "key1=val1.key2=val2"
    #
    # mdnsd uses dot (.) as the delimiter between TXT record strings.
    # serialize_dname() in mdnsd/packet.c splits on '.' and creates
    # length-prefixed character-strings per RFC 6763.

	# Combine TXT records into single dot-separated string
	my $txt_string = join( '.',
		map { "$_=$self->{txt_records}{$_}" }
		sort keys %{ $self->{txt_records} } );

	# mdnsctl requires root/wheel access to /var/run/mdnsd.sock
	# openhapd must start as root and call this before dropping privileges
	my @cmd = (
		$self->{mdnsctl}, 'publish',
		$self->{service_name}, 'hap', 'tcp', $self->{port}, $txt_string,
	);

	$OpenHAP::logger->debug( 'Registering mDNS service: %s',
		join( ' ', @cmd ) );

	# mdnsctl publish outputs status messages to stdout and stays running
	# It exits immediately if stdout is /dev/null, so redirect to a log file
	# Use /var/db/openhapd which is owned by _openhap after privilege drop
	my $log_dir  = $self->{log_dir};
	my $mdns_log = "$log_dir/mdnsctl.log";

     # Ensure the log directory exists (defensive: should be created by Storage)
	if ( !-d $log_dir ) {
		require File::Path;
		File::Path::make_path($log_dir)
		    or do {
			$OpenHAP::logger->warning(
				'Cannot create mdns log directory: %s', $! );
			return;
		    };
	}

	# Spawn mdnsctl process using FuguLib::Process
	my $result = FuguLib::Process->spawn_command(
		cmd         => \@cmd,
		check_alive => 1,
		stdout      => $mdns_log,
		stderr      => $mdns_log,
		on_success  => sub ($pid) {
			$OpenHAP::logger->info(
'Registered mDNS service: %s._hap._tcp port %d (PID: %d)',
				$self->{service_name}, $self->{port}, $pid );
		},
		on_error => sub ($err) {
			$OpenHAP::logger->warning(
				'mDNS registration failed: %s', $err );
		},
	);

	unless ( $result->{success} ) {
		return;
	}

	$self->{pid}        = $result->{pid};
	$self->{registered} = 1;

	return 1;
}

# $self->unregister_service():
#	Unregister the HAP service by killing the mdnsctl process
#	Returns 1 on success
sub unregister_service ($self)
{
	return if !$self->{registered};

	# Kill the mdnsctl process if it's still running
	if ( defined $self->{pid} ) {
		my $killed = FuguLib::Process->terminate(
			$self->{pid},
			on_kill => sub() {
				$OpenHAP::logger->info(
'Killed mdnsctl process (PID: %d) for service: %s._hap._tcp',
					$self->{pid}, $self->{service_name} );
			} );

		if ( !$killed ) {
			$OpenHAP::logger->warning(
				'Failed to kill mdnsctl process (PID: %d)',
				$self->{pid} );
		}

		$self->{pid} = undef;
	}

	$self->{registered} = 0;

	return 1;
}

# $self->update_txt_records($records):
#	Replace the TXT records and re-register the service so the
#	advertisement reflects state changes (HAP-mDNS.md §8)
sub update_txt_records ( $self, $records )
{
	$self->{txt_records} = $records;

	return 1 unless $self->{registered};

	$self->unregister_service;
	return $self->register_service;
}

# $self->is_registered():
#	Check if service is currently registered
sub is_registered ($self)
{
	return $self->{registered};
}

1;
