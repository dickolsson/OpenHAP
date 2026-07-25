# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@ekkis.net>
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

package OpenHAP::Test::Integration;

use Exporter 'import';
use IO::Socket::INET;
use Time::HiRes qw(sleep);

use FuguLib::Log;

our @EXPORT_OK = qw(
    setup teardown
    http_request parse_http_response
    get_config_value get_device_topics
    get_controller ensure_unpaired
    clear_logs get_log_lines
    ensure_daemon_running ensure_daemon_stopped
    ensure_mqtt_running
);

use constant {
	DEFAULT_CONFIG    => '/etc/openhapd.conf',
	DEFAULT_HAP_PORT  => 51827,
	DEFAULT_HAP_PIN   => '1995-1018',
	DEFAULT_MQTT_HOST => '127.0.0.1',
	DEFAULT_MQTT_PORT => 1883,
	SYSLOG_FILE       => '/var/log/daemon',
	PIDFILE           => '/var/run/openhapd.pid',
	DB_PATH           => '/var/db/openhapd',
};

sub new ( $class, %options )
{
	my $self = bless {
		config_file  => $options{config_file} // DEFAULT_CONFIG,
		hap_port     => $options{hap_port}    // DEFAULT_HAP_PORT,
		mqtt_host    => $options{mqtt_host}   // DEFAULT_MQTT_HOST,
		mqtt_port    => $options{mqtt_port}   // DEFAULT_MQTT_PORT,
		log_baseline => 0,
		sockets      => [],
		controllers  => [],
		mqtt         => undef,
	}, $class;

	return $self;
}

sub setup ($self)
{
	# Verify we're in integration test mode
	die "OPENHAP_INTEGRATION_TEST not set\n"
	    unless $ENV{OPENHAP_INTEGRATION_TEST};

	# The controller drives the accessory's own crypto/pairing library
	# code in this process, which logs through the $OpenHAP::logger the
	# daemon normally installs. Give it a quiet logger so those calls
	# do not die on an undefined logger, matching how the unit tests
	# set one up per file.
	$OpenHAP::logger //= FuguLib::Log->new(
		mode  => 'quiet',
		ident => 'openhap-integration'
	);

	# Verify system prerequisites
	$self->_verify_system or die "System prerequisites not met\n";

	# Parse configuration
	$self->_parse_config;

	# Ensure daemon is running
	$self->ensure_daemon_running or die "Cannot start openhapd daemon\n";

	# Record log baseline for this test
	$self->{log_baseline} = $self->_count_log_lines;

	return 1;
}

sub teardown ($self)
{
	# Close any controller connections
	for my $controller ( @{ $self->{controllers} } ) {
		$controller->close if defined $controller;
	}
	$self->{controllers} = [];

	# Close any open sockets
	for my $socket ( @{ $self->{sockets} } ) {
		$socket->close if defined $socket;
	}
	$self->{sockets} = [];

	# Disconnect MQTT if connected
	if ( defined $self->{mqtt} ) {
		eval { undef $self->{mqtt}; };
	}

	return 1;
}

# $self->get_controller(%args):
#	Construct an OpenHAP::Test::Controller for the configured
#	host/port/PIN. The connection is tracked and closed in teardown.
sub get_controller ( $self, %args )
{
	require OpenHAP::Test::Controller;

	my $controller = OpenHAP::Test::Controller->new(
		host => '127.0.0.1',
		port => $self->{hap_port},
		pin  => $self->get_config_value('hap_pin') // DEFAULT_HAP_PIN,
		%args,
	);

	push @{ $self->{controllers} }, $controller;

	return $controller;
}

# $self->ensure_unpaired():
#	Guarantee the daemon starts unpaired: when stored pairings
#	exist, stop the daemon, wipe the pairing state (keeping the
#	accessory identity), and start it again.
sub ensure_unpaired ($self)
{
	my $pairings_file = DB_PATH . '/pairings';
	return 1 unless -s $pairings_file;

	$self->ensure_daemon_stopped or return;

	unlink $pairings_file
	    or do { warn "Cannot remove $pairings_file: $!\n"; return; };
	unlink DB_PATH . '/auth_attempts';

	$self->ensure_daemon_running or return;

	return 1;
}

sub http_request ( $self, $method, $path, $body = undef, $headers = {} )
{
	my $socket = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $self->{hap_port},
		Proto    => 'tcp',
		Timeout  => 2,
	);
	return unless defined $socket;

	push @{ $self->{sockets} }, $socket;

	# Build request
	print $socket "$method $path HTTP/1.1\r\n";
	print $socket "Host: 127.0.0.1:$self->{hap_port}\r\n";

	for my $header ( keys %$headers ) {
		print $socket "$header: $headers->{$header}\r\n";
	}

	if ( defined $body ) {
		print $socket "Content-Length: " . length($body) . "\r\n";
	}

	print $socket "\r\n";
	print $socket $body if defined $body;
	$socket->flush;

	# Read response headers
	my $response = '';
	while ( my $line = <$socket> ) {
		$response .= $line;
		last if $line =~ /^\r?\n$/;
	}

	# Read body if Content-Length present
	if ( $response =~ /Content-Length:\s*(\d+)/i ) {
		my $content_length = $1;
		my $response_body;
		read $socket, $response_body, $content_length;
		$response .= $response_body;
	}

	return $response;
}

sub parse_http_response ($response)
{
	return unless defined $response;

	my ( $headers_text, $body ) = split /\r?\n\r?\n/, $response, 2;
	my @lines = split /\r?\n/, $headers_text;

	my $status_line = shift @lines;
	my ($status) = $status_line =~ /HTTP\/1\.[01]\s+(\d+)/;

	my %headers;
	for my $line (@lines) {
		if ( $line =~ /^([^:]+):\s*(.*)/ ) {
			$headers{ lc $1 } = $2;
		}
	}

	return ( $status, \%headers, $body // '' );
}

sub get_config_value ( $self, $key )
{
	return $self->{config}{$key};
}

sub get_device_topics ($self)
{
	return @{ $self->{device_topics} // [] };
}

# $self->get_devices():
#	Return the configured device records as a list of hashes with
#	type, subtype, id, name, and topic.
sub get_devices ($self)
{
	return @{ $self->{devices} // [] };
}

sub ensure_daemon_running ($self)
{
	# Check if already running
	return 1 if system('rcctl check openhapd >/dev/null 2>&1') == 0;

	# Attempt to start
	system('rcctl start openhapd >/dev/null 2>&1');
	sleep 1;

	# Verify it started
	return system('rcctl check openhapd >/dev/null 2>&1') == 0;
}

sub ensure_daemon_stopped ($self)
{
	return 1 if system('rcctl check openhapd >/dev/null 2>&1') != 0;

	system('rcctl stop openhapd >/dev/null 2>&1');
	sleep 1;

	return system('rcctl check openhapd >/dev/null 2>&1') != 0;
}

sub ensure_mqtt_running ($self)
{
	# Check if already running
	return 1 if system('rcctl check mosquitto >/dev/null 2>&1') == 0;

	# Attempt to start
	system('rcctl start mosquitto >/dev/null 2>&1');
	sleep 1;

	# Verify it started
	return system('rcctl check mosquitto >/dev/null 2>&1') == 0;
}

sub clear_logs ($self)
{
	return unless -w SYSLOG_FILE;

	# Truncate would require root, so we just record a new baseline
	$self->{log_baseline} = $self->_count_log_lines;

	return 1;
}

sub get_log_lines ( $self, $pattern = undef )
{
	return () unless -r SYSLOG_FILE;

	my @lines;
	open my $fh, '<', SYSLOG_FILE or return ();

	my $line_num = 0;
	while (<$fh>) {
		$line_num++;
		next if $line_num <= $self->{log_baseline};
		next unless /openhapd/;
		next if defined $pattern && !/$pattern/;
		push @lines, $_;
	}
	close $fh;

	return @lines;
}

sub get_mqtt ($self)
{
	return $self->{mqtt} if defined $self->{mqtt};

	# Require Net::MQTT::Simple
	eval { require Net::MQTT::Simple; };
	return if $@;

	# Ensure broker is running
	return unless $self->ensure_mqtt_running;

	# Create connection
	eval {
		$self->{mqtt} = Net::MQTT::Simple->new(
			"$self->{mqtt_host}:$self->{mqtt_port}");
	};

	return $self->{mqtt};
}

sub _verify_system ($self)
{
	# Check required binaries
	return unless -x '/usr/sbin/rcctl';
	return unless -x '/usr/local/bin/openhapd';
	return unless -x '/usr/local/bin/hapctl';

	# Check configuration exists
	return unless -f $self->{config_file};
	return unless -r $self->{config_file};

	# Check system user exists
	return unless system('id _openhap >/dev/null 2>&1') == 0;

	# Check data directory exists
	return unless -d '/var/db/openhapd';

	return 1;
}

sub _parse_config ($self)
{
	open my $fh, '<', $self->{config_file} or return;

	my %config;
	my @device_topics;
	my @devices;
	my $device;

	while (<$fh>) {

		# Skip comments and empty lines
		next if /^\s*#/ || /^\s*$/;

		# Device blocks: device <type> <subtype> <id> {
		if (/^\s*device\s+(\w+)\s+(\w+)\s+(\w+)/) {
			$device = {
				type    => $1,
				subtype => $2,
				id      => $3,
			};
			next;
		}
		if (/^\s*\}/) {
			push @devices, $device if defined $device;
			$device = undef;
			next;
		}

		# Simple key = value
		if (/^\s*(\w+)\s*=\s*(.+)/) {
			my ( $key, $value ) = ( $1, $2 );
			$value =~ s/^"(.*)"$/$1/;    # Remove quotes

			if ( defined $device ) {
				$device->{$key} = $value;
				push @device_topics, $value
				    if $key eq 'topic';
				next;
			}

			$config{$key} = $value;

			# Update hap_port if configured
			$self->{hap_port} = $value if $key eq 'hap_port';
		}
	}
	close $fh;

	$self->{config}        = \%config;
	$self->{device_topics} = \@device_topics;
	$self->{devices}       = \@devices;

	return 1;
}

sub _count_log_lines ($self)
{
	return 0 unless -r SYSLOG_FILE;

	my $count = 0;
	if ( open my $fh, '<', SYSLOG_FILE ) {
		while (<$fh>) {
			$count++ if /openhapd/;
		}
		close $fh;
	}

	return $count;
}

1;
