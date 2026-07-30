#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: mDNS service advertisement

use v5.36;
use Test::More tests => 12;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use IO::Socket::INET;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;
$env->ensure_unpaired or die "Cannot reset pairing state\n";

# Test 1: mdnsd daemon is running and stays running (started if
# needed; failure emits captured diagnostics). The daemon speaks the
# mdnsd control protocol directly, so a running mdnsd is the
# precondition - not the mdnsctl binary, which openhapd never invokes.
my $mdnsd_available = $env->ensure_mdnsd_running;
ok($mdnsd_available, 'mdnsd daemon is running');

die "mdnsd required for mDNS integration tests\n" unless $mdnsd_available;

# Test 2: OpenHAP daemon is running
my $daemon_running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($daemon_running, 'OpenHAP daemon is running');

# Test 3: mdnsctl available as the browsing tool these tests observe
# advertisements with
my $mdnsctl_available = -x '/usr/sbin/mdnsctl' || -x '/usr/local/bin/mdnsctl';
ok($mdnsctl_available, 'mdnsctl browse tool available');

die "mdnsctl required to observe advertisements\n" unless $mdnsctl_available;

# Restart openhapd so it re-registers with the running mdnsd; the
# listener opens after the publish conversation, so serving means
# published
system('rcctl restart openhapd >/dev/null 2>&1');
$env->wait_for_hap_port or die "daemon not serving after restart\n";

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
$env->wait_for_hap_port;

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

# browse_txt(): resolved browse output including TXT strings
sub browse_txt
{
	return `timeout 5 mdnsctl browse -r hap tcp 2>&1 || true`;
}

# Test 10: sf=1 advertised while unpaired
my $txt_output = browse_txt();
like($txt_output, qr/sf=1/,
   '[HAP-mDNS §3.7] sf=1 advertised while unpaired');

# Test 11: after pairing, sf flips to 0 in the browsed TXT record.
# The daemon withdraws and republishes on the state change, so poll
# the browsed TXT rather than sleeping a fixed interval.
my $controller = $env->get_controller;
$controller->pair_setup
    or die 'pair-setup failed: ' . ( $controller->last_error // '?' ) . "\n";

my $deadline = time + 30;
$txt_output = browse_txt();
while ($txt_output !~ /sf=0/ && time < $deadline) {
	sleep 1;
	$txt_output = browse_txt();
}
like($txt_output, qr/sf=0/,
   '[HAP-mDNS §8] sf flips to 0 in the browsed TXT after pairing');

# Test 12: c# persists across a daemon restart
my ($config_number) = $txt_output =~ /c#=(\d+)/;
system('rcctl restart openhapd >/dev/null 2>&1');
$env->wait_for_hap_port;
$txt_output = browse_txt();
my ($config_number_after) = $txt_output =~ /c#=(\d+)/;
is($config_number_after, $config_number,
   '[HAP-mDNS §3.1] c# persisted across daemon restart');

# Teardown: unpair via state wipe (the pairing survived the restart)
$env->ensure_unpaired or die "Cannot reset pairing state\n";
$env->teardown;
