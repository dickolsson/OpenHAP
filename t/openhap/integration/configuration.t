#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: Configuration loading and validation

use v5.36;
use Test::More tests => 10;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;

my $config_file = $env->{config_file};

# Test 1: Configuration file exists and is readable
ok(-f $config_file && -r $config_file, 'configuration file accessible');

# Test 2: hapctl check validates configuration
my $check_result = system("hapctl -c $config_file check >/dev/null 2>&1");
is($check_result, 0, 'configuration validates with hapctl check');

# Test 3: hapctl check reports device count
my $check_output = `hapctl -c $config_file check 2>&1`;
my $reports_devices = $check_output =~ /Configured devices:\s*\d+/;
ok($reports_devices, 'hapctl check reports device count');

# Test 4: openhapd -n validates configuration
my $daemon_check = system("openhapd -n -c $config_file >/dev/null 2>&1");
is($daemon_check, 0, 'openhapd -n validates configuration');

# Test 5: Configuration contains required HAP settings
my $hap_name = $env->get_config_value('hap_name');
my $hap_port = $env->get_config_value('hap_port');
ok(defined $hap_name, 'configuration has hap_name');
ok(defined $hap_port, 'configuration has hap_port');

# Test 6: HAP port is valid
ok($hap_port =~ /^\d+$/ && $hap_port >= 1024 && $hap_port <= 65535,
   'hap_port is valid');

# Test 7: The hapctl device count matches the parsed configuration
my ($reported_count) = $check_output =~ /Configured devices:\s*(\d+)/;
my @device_topics = $env->get_device_topics;
is($reported_count, scalar @device_topics,
   'hapctl device count matches parsed device topics');

# Test 8: Daemon still running
sleep 0.5;
my $running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($running, 'daemon still running');

# Test 9: The daemon can restart. The daemon possibly does not
# support reload.
system('rcctl restart openhapd >/dev/null 2>&1');
sleep 1;
$running = system('rcctl check openhapd >/dev/null 2>&1') == 0;
ok($running, 'daemon running after restart');

$env->teardown;
