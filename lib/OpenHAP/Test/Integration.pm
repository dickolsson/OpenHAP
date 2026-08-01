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

use constant PAIRINGS_FILE => DB_PATH . '/pairings.db';

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
	# Make sure the tests run in integration test mode
	die "OPENHAP_INTEGRATION_TEST not set\n"
	    unless $ENV{OPENHAP_INTEGRATION_TEST};

	# The controller drives the accessory's own crypto/pairing
	# library code in this process. That code logs through the
	# $OpenHAP::logger that the daemon normally installs. Give it
	# a quiet logger. Then those calls do not die on an undefined
	# logger. The unit tests set one up per file in the same way.
	$OpenHAP::logger //= FuguLib::Log->new(
		mode  => 'quiet',
		ident => 'openhap-integration'
	);

	# Verify the system prerequisites
	$self->_verify_system or die "System prerequisites not met\n";

	# Parse the configuration
	$self->_parse_config;

	# Make sure the daemon is running
	$self->ensure_daemon_running or die "Cannot start openhapd daemon\n";

	# Record the log baseline for this test
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
	$self->close_sockets;

	# Disconnect MQTT if it is connected
	if ( defined $self->{mqtt} ) {
		eval { undef $self->{mqtt}; };
	}

	return 1;
}

# $self->get_controller(%args):
#	Construct an OpenHAP::Test::Controller for the configured
#	host/port/PIN. The harness tracks the connection and closes
#	it in teardown.
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
#	Make sure the daemon is verifiably unpaired. When stored
#	pairings exist, stop the daemon, wipe the pairing state, and
#	start it again. The wipe keeps the accessory identity. A
#	POST /identify probes the post-condition. It succeeds only
#	while the daemon is unpaired (HAP-HTTP.md §3).
sub ensure_unpaired ($self)
{
	if ( $self->_has_pairings ) {
		$self->ensure_daemon_stopped or return;

		for my $file ( PAIRINGS_FILE, DB_PATH . '/auth_attempts' ) {
			next unless -e $file;
			unlink $file or do {
				warn "Cannot remove $file: $!\n";
				return;
			};
		}

		$self->ensure_daemon_running or return;
	}

	return $self->_verify_unpaired;
}

# $self->_has_pairings():
#	Return true when the pairings database holds at least one
#	entry. The daemon leaves comment headers in the file after
#	its first save. Thus a size check cannot tell paired from
#	unpaired. Parse for non-comment lines instead.
sub _has_pairings ($self)
{
	open my $fh, '<', PAIRINGS_FILE or return 0;
	while (<$fh>) {
		next if /^#/ || /^\s*$/;
		close $fh;
		return 1;
	}
	close $fh;

	return 0;
}

# $self->_verify_unpaired():
#	Probe the pairing state with POST /identify. The daemon
#	returns 204 only when unpaired. It returns 400 with
#	{"status":-70401} when still paired (HAP-HTTP.md §3). This
#	sub fails loudly on the paired answer. It closes the probe
#	socket immediately. The socket does not stay registered with
#	the daemon until teardown.
sub _verify_unpaired ($self)
{
	my $before   = scalar @{ $self->{sockets} };
	my $response = $self->http_request( 'POST', '/identify' );
	for my $socket ( splice @{ $self->{sockets} }, $before ) {
		$socket->close if defined $socket;
	}

	unless ( defined $response ) {
		warn "No response to identify probe\n";
		return;
	}

	my ($status) = parse_http_response($response);
	return 1 if defined $status && $status == 204;

	warn sprintf "Daemon not unpaired: identify returned %s\n",
	    $status // 'no status';

	return;
}

# $self->close_sockets():
#	Close and forget every raw socket that http_request opened.
#	Then a probe connection does not stay registered with the
#	daemon until teardown.
sub close_sockets ($self)
{
	for my $socket ( @{ $self->{sockets} } ) {
		$socket->close if defined $socket;
	}
	$self->{sockets} = [];

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

	# Build the request
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

	# Read the response headers
	my $response = '';
	while ( my $line = <$socket> ) {
		$response .= $line;
		last if $line =~ /^\r?\n$/;
	}

	# Read the body if the response has a Content-Length header
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
	if ( system('rcctl check openhapd >/dev/null 2>&1') != 0 ) {
		system('rcctl start openhapd >/dev/null 2>&1');
		sleep 1;
		return if system('rcctl check openhapd >/dev/null 2>&1') != 0;
	}

	# A daemon that runs per rcctl does not serve yet. At
	# startup, the daemon publishes the mDNS advertisement and
	# waits for the mdnsd replies. The HAP listener opens after
	# that. Thus wait for the port, not for a fixed sleep.
	return $self->wait_for_hap_port;
}

# $self->wait_for_hap_port($timeout):
#	Wait until the HAP port accepts connections. Poll every
#	quarter second, up to $timeout seconds. The default is 30
#	seconds, which is generous for TCG emulation. Return 1 when
#	the daemon serves. Return undef on the deadline.
sub wait_for_hap_port ( $self, $timeout = 30 )
{
	my $port     = $self->get_config_value('hap_port') // DEFAULT_HAP_PORT;
	my $deadline = time + $timeout;

	while ( time < $deadline ) {
		my $socket = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => 2,
		);
		if ( defined $socket ) {
			$socket->close;
			return 1;
		}
		sleep 0.25;
	}

	return;
}

sub ensure_daemon_stopped ($self)
{
	return 1 if system('rcctl check openhapd >/dev/null 2>&1') != 0;

	system('rcctl stop openhapd >/dev/null 2>&1');
	sleep 1;

	return system('rcctl check openhapd >/dev/null 2>&1') != 0;
}

# $self->ensure_mdnsd_running():
#	Make sure that mdnsd runs and continues to run. Start it if
#	necessary. Then check again across a settle window. A
#	point-in-time probe races green when mdnsd starts and then
#	exits shortly after. On failure, emit the captured
#	diagnostics. Then a dead mdnsd is diagnosable from the test
#	output, and the sub does not fail bare.
sub ensure_mdnsd_running ($self)
{
	my $check = 'rcctl check mdnsd >/dev/null 2>&1';

	unless ( system($check) == 0 ) {
		system('rcctl enable mdnsd >/dev/null 2>&1');
		system('rcctl start mdnsd >/dev/null 2>&1');
	}

	for my $probe ( 1 .. 3 ) {
		sleep 1;
		next if system($check) == 0;
		$self->_warn_mdnsd_diagnostics(
			"mdnsd not running at settle probe $probe/3");
		return;
	}

	return 1;
}

# $self->_warn_mdnsd_diagnostics($reason):
#	Emit the captured mdnsd state as warnings for the failure
#	diagnostics. The state holds the rcctl views, the process
#	list, and recent syslog lines.
sub _warn_mdnsd_diagnostics ( $self, $reason )
{
	my $syslog = SYSLOG_FILE;

	warn "$reason\n";
	warn 'rcctl get mdnsd: ' . `rcctl get mdnsd 2>&1`;
	warn 'mdnsd processes: '
	    . ( `ps -axo pid,command 2>/dev/null | grep -w mdnsd | grep -v grep`
		    || "none\n" );
	warn "recent mdnsd syslog lines:\n"
	    . (        `tail -200 $syslog 2>/dev/null | grep mdnsd | tail -20`
		    || "none\n" );

	return;
}

sub ensure_mqtt_running ($self)
{
	# Check if the broker is already running
	return 1 if system('rcctl check mosquitto >/dev/null 2>&1') == 0;

	# Try to start the broker
	system('rcctl start mosquitto >/dev/null 2>&1');
	sleep 1;

	# Make sure the broker started
	return system('rcctl check mosquitto >/dev/null 2>&1') == 0;
}

sub clear_logs ($self)
{
	return unless -w SYSLOG_FILE;

	# A truncate requires root. Thus record a new baseline instead.
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

	# Make sure the broker is running
	return unless $self->ensure_mqtt_running;

	# Create the connection
	eval {
		$self->{mqtt} = Net::MQTT::Simple->new(
			"$self->{mqtt_host}:$self->{mqtt_port}");
	};

	return $self->{mqtt};
}

sub _verify_system ($self)
{
	# Check the required binaries
	return unless -x '/usr/sbin/rcctl';
	return unless -x '/usr/local/bin/openhapd';
	return unless -x '/usr/local/bin/hapctl';

	# Check that the configuration exists
	return unless -f $self->{config_file};
	return unless -r $self->{config_file};

	# Check that the system user exists
	return unless system('id _openhap >/dev/null 2>&1') == 0;

	# Check that the data directory exists
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
			$value =~ s/^"(.*)"$/$1/;    # Remove the quotes

			if ( defined $device ) {
				$device->{$key} = $value;
				push @device_topics, $value
				    if $key eq 'topic';
				next;
			}

			$config{$key} = $value;

			# Update hap_port if the config sets it
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
