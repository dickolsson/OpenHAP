#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for OpenHAP::Test::Controller: constructor, transport
# injection and error paths. Full protocol exchanges are covered by
# t/conformance/hap-pairing-exchange.t.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new( mode => 'quiet', ident => 'test' );

BEGIN {
	eval {
		require Math::BigInt;
		require Crypt::Ed25519;
		require Crypt::Curve25519;
		require Crypt::AuthEnc::ChaCha20Poly1305;
	};
	if ($@) {
		plan skip_all => 'Crypto dependencies not available';
	}
}

use_ok('OpenHAP::Test::Controller');
use_ok('OpenHAP::Test::Controller::SRP');
use_ok('OpenHAP::TLV');
use_ok('OpenHAP::Pairing');

# Constructor defaults and identity generation
{
	my $controller = OpenHAP::Test::Controller->new;

	ok( defined $controller, 'controller created with defaults' );
	is( $controller->{host}, '127.0.0.1', 'default host' );
	is( $controller->{port}, 51827,       'default port' );
	ok( defined $controller->{ltsk}, 'controller LTSK generated' );
	is( length( $controller->{ltpk} ), 32, 'LTPK is 32 bytes' );
	ok( !$controller->is_encrypted, 'session starts unencrypted' );
	is( $controller->last_error, undef, 'no error initially' );
}

# Transport injection: requests flow through the code ref
{
	my $seen;
	my $transport = sub ($request) {
		$seen = $request;
		return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
	};
	my $controller =
	    OpenHAP::Test::Controller->new( transport => $transport );

	my $response = $controller->request( 'GET', '/accessories' );
	like( $seen, qr{^GET /accessories HTTP/1\.1\r\n},
		'request bytes passed to the transport' );
	is( $response->{status}, 200,  'status parsed' );
	is( $response->{body},   'hi', 'body parsed' );
	is( $response->{headers}{'content-length'},
		2, 'headers parsed and lowercased' );
}

# Connection refused: pair_setup fails with last_error set
{
	my $controller = OpenHAP::Test::Controller->new(
		host    => '127.0.0.1',
		port    => 1,      # nothing listens here
		timeout => 1,
	);

	ok( !$controller->pair_setup, 'pair_setup fails without server' );
	ok( defined $controller->last_error, 'last_error set' );
	like( $controller->last_error, qr/connect|no response/,
		'error mentions the connection failure' );
}

# Malformed TLV response: error recorded, no crash
{
	my $transport = sub ($request) {
		my $body = "\x06\xFF\x01";    # length past end of buffer
		return
		      "HTTP/1.1 200 OK\r\n"
		    . 'Content-Length: '
		    . length($body)
		    . "\r\n\r\n"
		    . $body;
	};
	my $controller =
	    OpenHAP::Test::Controller->new( transport => $transport );

	ok( !$controller->pair_setup, 'malformed TLV response fails' );
	ok( defined $controller->last_error, 'last_error set' );
}

# TLV error response: the error code is exposed via last_error
{
	my $transport = sub ($request) {
		my $body = OpenHAP::TLV::encode(
			OpenHAP::Pairing::kTLVType_State() => pack( 'C', 2 ),
			OpenHAP::Pairing::kTLVType_Error() => pack(
				'C', OpenHAP::Pairing::kTLVError_MaxTries()
			),
		);
		return
		      "HTTP/1.1 200 OK\r\n"
		    . 'Content-Length: '
		    . length($body)
		    . "\r\n\r\n"
		    . $body;
	};
	my $controller =
	    OpenHAP::Test::Controller->new( transport => $transport );

	ok( !$controller->pair_setup, 'error TLV fails the exchange' );
	is( $controller->last_error,
		OpenHAP::Pairing::kTLVError_MaxTries(),
		'TLV error code exposed through last_error' );
}

# Non-200 HTTP status is an error
{
	my $transport = sub ($request) {
		return "HTTP/1.1 470 Connection Authorization Required\r\n"
		    . "Content-Length: 0\r\n\r\n";
	};
	my $controller =
	    OpenHAP::Test::Controller->new( transport => $transport );

	ok( !$controller->pair_setup, 'non-200 status fails' );
	is( $controller->last_error, 'HTTP 470', 'status in last_error' );
}

# Client SRP dies on out-of-order calls
{
	my $srp =
	    OpenHAP::Test::Controller::SRP->new( password => '123-45-678' );

	eval { $srp->compute_proof( 'salt', 'B' ) };
	like( $@, qr/compute_public not called/,
		'compute_proof before compute_public dies' );

	eval { $srp->verify_server_proof('M2') };
	like( $@, qr/compute_proof not called/,
		'verify_server_proof before compute_proof dies' );
}

# Client SRP rejects a bogus server public key
{
	my $srp =
	    OpenHAP::Test::Controller::SRP->new( password => '123-45-678' );
	$srp->compute_public;

	my $M1 = $srp->compute_proof( 'x' x 16, "\x00" x 384 );
	ok( !defined $M1, 'B mod N == 0 rejected' );
}

done_testing();
