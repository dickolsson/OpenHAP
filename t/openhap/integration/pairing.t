#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: HAP pairing workflow

use v5.36;
use Test::More tests => 15;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;

my $env = OpenHAP::Test::Integration->new;
$env->setup;

# Test 1: Pairing data directory exists
my $storage_dir = '/var/db/openhapd';
ok(-d $storage_dir, 'pairing storage directory exists');

# Test 2: Storage directory is readable
ok(-r $storage_dir, 'storage directory is readable');

# Test 3: hapctl status shows pairing information
my $config_file = $env->{config_file};
my $status_output = `hapctl -c $config_file status 2>&1`;
my $has_pairing_info = $status_output =~ /(Pairing status|not paired|paired|not initialized|openhapd)/i;
ok($has_pairing_info, 'hapctl status shows pairing state');

# Test 4: Pair-setup M1: Client sends Start Request
my $response = $env->http_request('POST', '/pair-setup',
	"\x06\x01\x01\x00\x01\x00",  # State=M1 (0x06,0x01,0x01), Method=PairSetup (0x00,0x01,0x00)
	{'Content-Type' => 'application/pairing+tlv8'});
my ($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok($status == 200, 'pair-setup M1 accepted');

# Test 5: Pair-setup M1 response contains TLV8 data
my (undef, undef, $body) = OpenHAP::Test::Integration::parse_http_response($response);
ok(length($body) > 0, 'pair-setup M1 returns data');

# Test 5b: Pair-setup M2 response doesn't contain ASCII '0x' prefix in public key
# This was a bug where Math::BigInt->as_hex() returned "0x..." which was incorrectly packed
my $hex = unpack('H*', $body);
unlike($hex, qr/03..0130783078/,
    '[HAP-Pairing §2.4] M2 public key does not contain ASCII "0x" prefix');

# Test 6: Pair-setup responds with proper Content-Type
ok($response =~ /Content-Type:\s*application\/pairing\+tlv8/i,
   '[HAP-HTTP §2] pair-setup uses application/pairing+tlv8');

# Test 7: Pair-verify endpoint available
$response = $env->http_request('POST', '/pair-verify',
	"\x06\x01\x01",  # State=M1
	{'Content-Type' => 'application/pairing+tlv8'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok($status == 200, 'pair-verify endpoint available');

# Test 8: Pair-verify returns TLV8 data
(undef, undef, $body) = OpenHAP::Test::Integration::parse_http_response($response);
ok(length($body) > 0, 'pair-verify returns data');

# Test 9: Repeated pair-setup attempts don't crash daemon
for (1..3) {
	$response = $env->http_request('POST', '/pair-setup',
		"\x06\x01\x01\x00\x01\x00",
		{'Content-Type' => 'application/pairing+tlv8'});
	($status) = OpenHAP::Test::Integration::parse_http_response($response);
	last unless $status == 200;
}
ok($status == 200, 'repeated pair-setup attempts handled');

# Test 10: Daemon still responsive after pairing attempts
$response = $env->http_request('GET', '/accessories');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status, 'daemon responsive after pairing attempts');

# Test 11: Invalid pairing method returns error TLV
$response = $env->http_request('POST', '/pair-setup',
	"\x06\x01\x01\x00\x01\x63",  # State=M1, Method=0x63 (invalid)
	{'Content-Type' => 'application/pairing+tlv8'});
($status, undef, $body) = OpenHAP::Test::Integration::parse_http_response($response);
# Response should contain error TLV with kTLVError_Unknown (0x01)
my $has_error = $body =~ /\x07\x01\x01/;  # Error type (0x07), length 1, value 1
ok($status == 200 && $has_error,
   '[HAP-TLV8 §6] invalid method returns kTLVError_Unknown');

# Test 12: /prepare accepts POST method
$response = $env->http_request('POST', '/prepare',
	'{"ttl":10000,"pid":1}',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
# Returns 470 (unauthorized) since not paired, but endpoint is reachable
is($status, 470, '[HAP-HTTP §10] unpaired /prepare POST returns 470');

# Test 13: /prepare also accepts PUT method (spec shows both)
$response = $env->http_request('PUT', '/prepare',
	'{"ttl":10000,"pid":1}',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
is($status, 470, '[HAP-HTTP §10] unpaired /prepare PUT returns 470');

# Test 14: Rapid sequential pair-setup attempts are handled
# Note: This is tricky to test in integration - we test that rapid requests work
for (1..5) {
	$response = $env->http_request('POST', '/pair-setup',
		"\x06\x01\x01\x00\x01\x00",
		{'Content-Type' => 'application/pairing+tlv8'});
	($status) = OpenHAP::Test::Integration::parse_http_response($response);
}
ok($status == 200, 'rapid pair-setup attempts handled gracefully');

$env->teardown;
