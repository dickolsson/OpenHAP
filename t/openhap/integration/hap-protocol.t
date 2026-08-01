#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: HAP protocol endpoints and HTTP functionality

use v5.36;
use Test::More tests => 27;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;

my $env = OpenHAP::Test::Integration->new;
$env->setup;

# Test 1: The HAP server is reachable over HTTP
my $response = $env->http_request('GET', '/');
ok(defined $response && $response =~ /^HTTP\/1\.[01]/, 'server reachable');

# Test 2: /accessories endpoint responds
$response = $env->http_request('GET', '/accessories');
my ($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status, '/accessories endpoint responds');

# Test 3: /accessories returns proper status (470 or 200)
ok($status == 470 || $status == 200,
   '/accessories returns 470 (unpaired) or 200 (paired)');

# Test 4: /accessories has correct Content-Type
my $has_content_type = $response =~ /Content-Type:\s*application\/hap\+json/i;
ok($has_content_type || $status == 470,
   '/accessories uses application/hap+json');

# Test 5: /characteristics GET endpoint responds
$response = $env->http_request('GET', '/characteristics?id=1.10');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 470 || $status == 200 || $status == 404),
   '/characteristics GET responds');

# Test 6: /characteristics PUT endpoint responds
$response = $env->http_request('PUT', '/characteristics',
	'{"characteristics":[]}',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 470 || $status == 204 || $status == 400),
   '/characteristics PUT responds');

# Test 7: /pair-setup endpoint accepts POST
$response = $env->http_request('POST', '/pair-setup', "\x00\x01\x00",
	{'Content-Type' => 'application/pairing+tlv8'});
ok(defined $response && $response =~ /HTTP\/1\.[01]\s+200/,
   '/pair-setup accepts POST');

# Test 8: /pair-setup uses correct Content-Type
$has_content_type = $response =~ /Content-Type:\s*application\/pairing\+tlv8/i;
ok($has_content_type, '/pair-setup uses application/pairing+tlv8');

# Test 9: /pair-verify endpoint accepts POST
$response = $env->http_request('POST', '/pair-verify', "\x00\x01\x00",
	{'Content-Type' => 'application/pairing+tlv8'});
ok(defined $response && $response =~ /HTTP\/1\.[01]\s+200/,
   '/pair-verify accepts POST');

# Test 10: /pair-verify uses correct Content-Type
$has_content_type = $response =~ /Content-Type:\s*application\/pairing\+tlv8/i;
ok($has_content_type, '/pair-verify uses application/pairing+tlv8');

# Test 11: Invalid endpoint returns 404 or 470
$response = $env->http_request('GET', '/invalid-endpoint-123');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok($status == 404 || $status == 470, 'invalid endpoint returns 404 or 470');

# Test 12: Server uses HTTP/1.x protocol
$response = $env->http_request('GET', '/accessories');
ok($response =~ /HTTP\/1\.[01]/, 'server uses HTTP/1.x');

# Test 13: Multiple concurrent connections work
my @sockets;
for (1..5) {
	my $sock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => $env->{hap_port},
		Proto    => 'tcp',
		Timeout  => 2,
	);
	push @sockets, $sock if defined $sock;
}
ok(@sockets >= 5, 'handles multiple concurrent connections');
$_->close for @sockets;

# Test 14: Connection persistence works
my $socket = IO::Socket::INET->new(
	PeerAddr => '127.0.0.1',
	PeerPort => $env->{hap_port},
	Proto    => 'tcp',
	Timeout  => 2,
);
ok(defined $socket, 'connection established');

# Make multiple requests on the same connection
print $socket "GET /accessories HTTP/1.1\r\n";
print $socket "Host: 127.0.0.1\r\n\r\n";
my $resp1 = '';
while (my $line = <$socket>) {
	$resp1 .= $line;
	last if $line =~ /^\r?\n$/;
}

print $socket "GET /accessories HTTP/1.1\r\n";
print $socket "Host: 127.0.0.1\r\n\r\n";
my $resp2 = '';
while (my $line = <$socket>) {
	$resp2 .= $line;
	last if $line =~ /^\r?\n$/;
}

$socket->close;

# Test 15: Both requests succeed
ok($resp1 =~ /HTTP/ && $resp2 =~ /HTTP/,
   'connection persistence works');

# Test 16: /identify endpoint responds to POST
$response = $env->http_request('POST', '/identify', '',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 204 || $status == 470 || $status == 400),
   '/identify endpoint responds');

# Test 17: /pairings endpoint responds to POST (requires authentication)
$response = $env->http_request('POST', '/pairings', "\x00\x01\x01",
	{'Content-Type' => 'application/pairing+tlv8'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 470 || $status == 200 || $status == 400),
   '/pairings endpoint responds');

# Test 18: /prepare endpoint responds to PUT (timed write support)
$response = $env->http_request('PUT', '/prepare',
	'{"ttl":5000,"pid":1}',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 200 || $status == 470 || $status == 400),
   '/prepare endpoint responds');

# Test 19: Connection: keep-alive header in responses
$response = $env->http_request('GET', '/accessories');
my $has_keepalive = $response =~ /Connection:\s*keep-alive/i;
ok($has_keepalive, 'response includes Connection: keep-alive header');

# Test 20: Server answers GET /characteristics with meta/perms/type/ev params
$response = $env->http_request('GET', '/characteristics?id=1.10&meta=1&perms=1&type=1&ev=1');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 200 || $status == 470 || $status == 404 || $status == 207),
   '/characteristics GET with meta/perms/type/ev responds');

# Test 21: Server returns proper error for invalid characteristic id format
$response = $env->http_request('GET', '/characteristics?id=invalid');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 400 || $status == 422 || $status == 470),
   '/characteristics GET with invalid id returns error');

# Test 22: PUT /characteristics with invalid data returns error
$response = $env->http_request('PUT', '/characteristics',
	'{"characteristics":[{"aid":999,"iid":999,"value":true}]}',
	{'Content-Type' => 'application/hap+json'});
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 207 || $status == 470 || $status == 204 || $status == 400),
   '/characteristics PUT with invalid data returns appropriate status');

# Test 23: HTTP responses use HTTP/1.1
$response = $env->http_request('GET', '/accessories');
ok($response =~ /HTTP\/1\.1/, 'server uses HTTP/1.1 specifically');

# Test 24: /pair-setup returns TLV response
$response = $env->http_request('POST', '/pair-setup', "\x00\x01\x00",
	{'Content-Type' => 'application/pairing+tlv8'});
# TLV responses are binary. Check for Content-Length.
my ($content_length) = $response =~ /Content-Length:\s*(\d+)/i;
ok(defined $content_length && $content_length > 0,
   '/pair-setup returns non-empty TLV response');

# Test 25: /pair-verify step 1 returns proper response
# Send a minimal step 1: kTLVType_State=1, kTLVType_PublicKey=<32 bytes>
my $fake_public_key = 'A' x 32;
my $step1_request = "\x00\x01\x01" . "\x03\x20" . $fake_public_key;
$response = $env->http_request('POST', '/pair-verify', $step1_request,
	{'Content-Type' => 'application/pairing+tlv8'});
ok(defined $response && $response =~ /HTTP\/1\.1\s+200/,
   '/pair-verify step 1 returns HTTP 200');

# Test 26: Error responses use application/hap+json
$response = $env->http_request('PUT', '/characteristics',
	'invalid json',
	{'Content-Type' => 'application/hap+json'});
# Check if the response has a content-type header
my $error_content_type = $response =~ /Content-Type:\s*application\/(hap\+)?json/i;
# Either proper error content-type or 470 unpaired
ok($error_content_type || $response =~ /470/,
   'error responses use appropriate content type');

# Test 27: Server responds to HEAD requests
$response = $env->http_request('HEAD', '/accessories');
($status) = OpenHAP::Test::Integration::parse_http_response($response);
ok(defined $status && ($status == 200 || $status == 405 || $status == 470),
   'server handles HEAD requests');

$env->teardown;
