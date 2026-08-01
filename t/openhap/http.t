#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

use_ok('OpenHAP::HTTP');

# Test request parsing
my $request_data = "GET /accessories HTTP/1.1\r\n" .
                   "Host: localhost\r\n" .
                   "Content-Type: application/hap+json\r\n" .
                   "\r\n";

my $request = OpenHAP::HTTP::parse($request_data);

is($request->{method}, 'GET', 'Method parsed correctly');
is($request->{path}, '/accessories', 'Path parsed correctly');
is($request->{version}, '1.1', 'Version parsed correctly');
is($request->{headers}{'host'}, 'localhost', 'Headers parsed correctly');

# Test POST with body
my $post_data = "POST /characteristics HTTP/1.1\r\n" .
                "Content-Length: 13\r\n" .
                "\r\n" .
                '{"test":true}';

my $post = OpenHAP::HTTP::parse($post_data);
is($post->{method}, 'POST', 'POST method parsed');
is($post->{body}, '{"test":true}', 'Body parsed correctly');

# Test response building
my $response = OpenHAP::HTTP::build_response(
    status => 200,
    headers => { 'Content-Type' => 'application/hap+json' },
    body => '{"status":"ok"}',
);

like($response, qr/HTTP\/1\.1 200 OK/, 'Response has status line');
like($response, qr/Content-Type: application\/hap\+json/, 'Response has headers');
like($response, qr/Content-Length: 15/, 'Response has content-length');
like($response, qr/\{"status":"ok"\}$/, 'Response has body');

# Test that the builder adds the Connection: keep-alive header
like($response, qr/Connection: keep-alive/, 'Response has Connection: keep-alive header');

# Test 204 No Content response
my $no_content = OpenHAP::HTTP::build_response(status => 204);
like($no_content, qr/HTTP\/1\.1 204 No Content/, '204 response has correct status');
like($no_content, qr/Content-Length: 0/, '204 response has zero content-length');
like($no_content, qr/Connection: keep-alive/, '204 response has keep-alive');

# Test 207 Multi-Status response
my $multi_status = OpenHAP::HTTP::build_response(
    status => 207,
    headers => { 'Content-Type' => 'application/hap+json' },
    body => '{"characteristics":[]}',
);
like($multi_status, qr/HTTP\/1\.1 207 Multi-Status/, '207 response has correct status');

# Test that the builder does not overwrite a custom Connection header
my $custom_conn = OpenHAP::HTTP::build_response(
    status => 200,
    headers => { 'Connection' => 'close' },
    body => 'test',
);
like($custom_conn, qr/Connection: close/, 'Custom Connection header preserved');
unlike($custom_conn, qr/Connection: keep-alive/, 'Default keep-alive not added when custom set');

done_testing();
