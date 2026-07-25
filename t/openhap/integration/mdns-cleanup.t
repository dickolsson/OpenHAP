#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: mDNS process cleanup on daemon shutdown

use v5.36;
use Test::More tests => 6;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;

# mdnsd must be running for openhapd to spawn mdnsctl publishers
unless (system('rcctl check mdnsd >/dev/null 2>&1') == 0) {
	system('rcctl enable mdnsd >/dev/null 2>&1');
	system('rcctl start mdnsd >/dev/null 2>&1');
	sleep 1;
}
die "mdnsd required for mDNS cleanup tests\n"
    unless system('rcctl check mdnsd >/dev/null 2>&1') == 0;

# Restart openhapd so it registers with the running mdnsd
system('rcctl restart openhapd >/dev/null 2>&1');
sleep 2;

# Test 1: Daemon is running initially
my $running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($running, 'daemon is running');

# Test 2: mdnsctl process exists while daemon is running
sleep 1;    # Allow mdnsctl to start
my $mdnsctl_count = count_mdnsctl_processes();
ok($mdnsctl_count > 0,
   "mdnsctl process running while daemon active ($mdnsctl_count found)");

# Test 3: Note the mdnsctl PID(s) for later comparison
my @initial_pids = get_mdnsctl_pids();
ok(@initial_pids > 0, 'captured mdnsctl PID(s)');

# Test 4: Stop the daemon
system('rcctl stop openhapd >/dev/null 2>&1');
sleep 2;    # Allow cleanup to complete

my $stopped = system('rcctl check openhapd >/dev/null 2>&1') != 0;
ok($stopped, 'daemon stopped successfully');

# Test 5: mdnsctl process should be terminated
$mdnsctl_count = count_mdnsctl_processes();
is($mdnsctl_count, 0, 'mdnsctl process terminated after daemon stop');

# Test 6: Verify the specific PIDs are gone
my $orphans_remaining = 0;
for my $pid (@initial_pids) {
	if (kill(0, $pid)) {
		$orphans_remaining++;
	}
}
is($orphans_remaining, 0,
   'no orphaned mdnsctl processes from initial daemon');

# Restart daemon for other tests
system('rcctl start openhapd >/dev/null 2>&1');
sleep 1;

$env->teardown;

# Helper: count mdnsctl publish processes
sub count_mdnsctl_processes
{
	my $output = `ps -axo pid,command | grep 'mdnsctl publish' | grep -v grep 2>/dev/null || true`;
	my @pids = grep { /^\s*\d+/ } split /\n/, $output;
	return scalar @pids;
}

# Helper: get mdnsctl PIDs
sub get_mdnsctl_pids
{
	my $output = `ps -axo pid,command | grep 'mdnsctl publish' | grep -v grep 2>/dev/null || true`;
	my @pids = map { /^\s*(\d+)/ ? $1 : () } split /\n/, $output;
	return @pids;
}
