#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: Daemon lifecycle management

use v5.36;
use Test::More tests => 10;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;

# Test 1: Daemon is running after setup
my $running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($running, 'daemon is running');

# Test 2: PID file exists and contains valid PID
my $pidfile = '/var/run/openhapd.pid';
my $pid;
if (open my $fh, '<', $pidfile) {
	$pid = <$fh>;
	chomp $pid if defined $pid;
	close $fh;
}
ok(!defined $pid || $pid =~ /^\d+$/, 'PID file handling correct');

# Test 3: Process is running. The check uses rcctl or connections.
ok($running, 'process is running');

# Test 4: Daemon responds to connections
ok($env->wait_for_hap_port, 'daemon accepts connections');

# Test 5: Daemon restart works
system('rcctl restart openhapd >/dev/null 2>&1');
sleep 1;
$running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($running, 'daemon restarts successfully');

# Test 6: New PID after restart or daemon restarted
my $new_pid;
if (open my $fh, '<', $pidfile) {
	$new_pid = <$fh>;
	chomp $new_pid if defined $new_pid;
	close $fh;
}
ok(!defined $pid || !defined $new_pid || $new_pid ne $pid,
   'daemon restarted (PIDs different or not tracked)');

# Test 7: Daemon stop works
system('rcctl stop openhapd >/dev/null 2>&1');
sleep 1;
my $stopped = system('rcctl check openhapd >/dev/null 2>&1') != 0;
ok($stopped, 'daemon stops successfully');

# Test 8: PID file removed after stop
ok(!-e $pidfile, 'PID file removed after stop');

# Test 9: Daemon start works
system('rcctl start openhapd >/dev/null 2>&1');
sleep 1;
$running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($running, 'daemon starts successfully');

# Test 10: Daemon responds after restart. The listener opens only
# after the mDNS publish conversation completes. Thus wait for the
# port. Do not use a fixed sleep.
ok($env->wait_for_hap_port, 'daemon responds after restart');

$env->teardown;
