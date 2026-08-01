#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: Accessory endpoints gate on pairing state

use v5.36;
use Test::More tests => 8;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;

my $env = OpenHAP::Test::Integration->new;
$env->setup;

my $config_file = $env->{config_file};

# Test 1: hapctl devices shows configured devices
my $devices_output = `hapctl -c $config_file devices 2>&1`;
my $devices_works = $? == 0;
ok($devices_works, 'hapctl devices command works');

# Test 2: Device count matches configuration
my ($config_count) = $devices_output =~ /Configured devices:\s*(\d+)/;
my @device_topics = $env->get_device_topics;
is($config_count // 0, scalar @device_topics,
   'device count matches configuration');

# The daemon starts unpaired, because the integration files own their
# pairing lifecycle. Thus the data-plane endpoints must return HTTP
# 470. The file t/openhap/integration/characteristics.t covers paired
# access.

# Test 3: GET /accessories requires pairing
my $response = $env->http_request('GET', '/accessories');
my ($status) = OpenHAP::Test::Integration::parse_http_response($response);
is($status, 470,
   '[HAP-HTTP §7] GET /accessories returns 470 when unpaired');

# Test 4: GET /characteristics requires pairing
$response = $env->http_request('GET', '/characteristics?id=1.10,1.20');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
is($status, 470,
   '[HAP-HTTP §8] GET /characteristics returns 470 when unpaired');

# Test 5: Repeated characteristic queries stay gated and responsive
my $multiple_ok = 1;
for my $aid (1..3) {
	$response = $env->http_request('GET', "/characteristics?id=$aid.10");
	($status) = OpenHAP::Test::Integration::parse_http_response($response);
	$multiple_ok = 0 unless defined $status && $status == 470;
}
ok($multiple_ok, 'repeated unpaired characteristic queries return 470');

# Test 6: PUT to characteristics requires pairing
$response = $env->http_request('PUT', '/characteristics',
	'{"characteristics":[{"aid":1,"iid":10,"value":1}]}',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
is($status, 470,
   '[HAP-HTTP §9] PUT /characteristics returns 470 when unpaired');

# Test 7: An invalid characteristic id still returns 470 when unpaired
$response = $env->http_request('GET', '/characteristics?id=999.999');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
is($status, 470,
   'invalid characteristic request returns 470 when unpaired');

# Test 8: Daemon responsive after gated requests
$response = $env->http_request('GET', '/accessories');
ok(defined $response, 'daemon responsive after gated requests');

$env->teardown;
