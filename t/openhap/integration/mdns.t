#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: mDNS service advertisement

use v5.36;
use Test::More tests => 9;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use IO::Socket::INET;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;

# Test 1: mdnsctl command available
my $mdnsctl_available = -x '/usr/sbin/mdnsctl' || -x '/usr/local/bin/mdnsctl';
ok($mdnsctl_available, 'mdnsctl command available');

die "mdnsctl required for mDNS integration tests\n" unless $mdnsctl_available;

# Test 2: OpenHAP daemon is running
my $daemon_running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($daemon_running, 'OpenHAP daemon is running');

# Test 3: mdnsd daemon is running (start it if needed)
unless (system('rcctl check mdnsd >/dev/null 2>&1') == 0) {
	system('rcctl enable mdnsd >/dev/null 2>&1');
	system('rcctl start mdnsd >/dev/null 2>&1');
	sleep 1;
}
my $mdnsd_available = system('rcctl check mdnsd >/dev/null 2>&1') == 0;
ok($mdnsd_available, 'mdnsd daemon is running');

die "mdnsd required for mDNS integration tests\n" unless $mdnsd_available;

# Restart openhapd so it re-registers with the running mdnsd
system('rcctl restart openhapd >/dev/null 2>&1');
sleep 2;

# Test 4: mdnsctl browse works
my $mdns_output = `timeout 5 mdnsctl browse hap tcp 2>&1 || true`;
ok(length($mdns_output) > 0, 'mdnsctl browse produces output');

# Test 5: HAP service is advertised ([HAP-mDNS §1] _hap._tcp)
sleep 1;    # Give time for registration
$mdns_output = `timeout 5 mdnsctl browse hap tcp 2>&1 || true`;
my $hap_found = $mdns_output =~ /hap.*tcp/i;
ok($hap_found, '[HAP-mDNS §1] HAP service advertised via mDNS');

# Test 6: Advertised service name matches the configured bridge name
my $hap_name = $env->get_config_value('hap_name') // 'OpenHAP';
ok($mdns_output =~ /\Q$hap_name\E/i,
   '[HAP-mDNS §4] service instance name matches configured name');

# Test 7: Daemon restart re-advertises service
system('rcctl restart openhapd >/dev/null 2>&1');
sleep 2;

$daemon_running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($daemon_running, 'daemon running after restart');

# Test 8: Service still browsable after restart ([HAP-mDNS §8])
$mdns_output = `timeout 5 mdnsctl browse hap tcp 2>&1 || true`;
ok($mdns_output =~ /hap.*tcp/i,
   '[HAP-mDNS §8] service re-advertised after daemon restart');

# Test 9: Port advertised by daemon matches configuration
my $hap_port = $env->get_config_value('hap_port')
    // OpenHAP::Test::Integration::DEFAULT_HAP_PORT;
my $lookup_output =
    `timeout 5 mdnsctl browse hap tcp 2>&1 || true`;
if ($lookup_output =~ /(\d{4,5})/) {
	ok($lookup_output =~ /\b\Q$hap_port\E\b/,
	   '[HAP-mDNS §6] advertised port matches configured hap_port');
} else {
	# browse output carries no port; verify the daemon listens on it
	my $listening = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $hap_port,
		Proto    => 'tcp',
		Timeout  => 2,
	);
	ok(defined $listening,
	   '[HAP-mDNS §6] daemon listens on the configured HAP port');
	$listening->close if defined $listening;
}

$env->teardown;
