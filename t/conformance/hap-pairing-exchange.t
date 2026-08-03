#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Full pair-setup and pair-verify exchanges for spec/HAP-Pairing.md.
# OpenHAP::Test::Controller connects in-process to an OpenHAP::HAP
# instance. The tests do not mock the crypto. The accessory is really
# paired when these tests end.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use FuguLib::TestLog;
use File::Temp qw(tempdir);

BEGIN {
	eval {
		require Math::BigInt;
		require Crypt::Ed25519;
		require Crypt::Curve25519;
		require Crypt::AuthEnc::ChaCha20Poly1305;
		require JSON::XS;
	};
	if ($@) {
		plan skip_all => 'Crypto dependencies not available';
	}
}

use_ok('OpenHAP::HAP');
use_ok('FuguLib::HTTP');
use_ok('Protocol::HAP::Session');
use_ok('Protocol::HAP::Pairing');
use_ok('OpenHAP::Test::Controller');

my $PIN = '123-45-678';

# Wire a controller to a fresh OpenHAP::HAP instance through an
# in-process transport. The transport parses and dispatches requests
# directly. Each controller connection gets one accessory-side
# session.
sub make_pair ( %controller_args )
{

	my $hap = OpenHAP::HAP->new(
		port         => 51827,
		pin          => $PIN,
		name         => 'Exchange Bridge',
		storage_path => tempdir( CLEANUP => 1 ),
	);
	$hap->{pairing}->reset_auth_attempts;

	# Mirror _handle_client: dispatch just enabled encryption, but
	# the transport sends the pair-verify M4 response in the clear
	my $session   = Protocol::HAP::Session->new( id => 9001 );
	my $transport = sub ($request_bytes) {
		my $was_encrypted = $session->is_encrypted;
		my $plain =
		    $was_encrypted
		    ? $session->decrypt($request_bytes)
		    : $request_bytes;
		return unless defined $plain;
		my $request  = FuguLib::HTTP::parse_request($plain);
		my $response = $hap->_dispatch( $request, $session );
		return $was_encrypted
		    ? $session->encrypt($response)
		    : $response;
	};

	my $controller = OpenHAP::Test::Controller->new(
		pin       => $PIN,
		transport => $transport,
		%controller_args,
	);

	return ( $controller, $hap, $session );
}

subtest '[HAP-Pairing §2.2][HAP-Pairing §2.8] full pair-setup M1-M6' =>
    sub {
	my ( $controller, $hap ) = make_pair();

	ok( $controller->pair_setup, 'pair-setup completes with real PIN' );
	is( $controller->last_error, undef, 'no error recorded' );

	ok( defined $controller->{accessory_ltpk},
		'accessory LTPK stored on the controller' );
	is( length( $controller->{accessory_ltpk} ),
		32, 'accessory LTPK is a 32-byte Ed25519 key' );

	# The accessory is paired now
	ok( $hap->is_paired, 'accessory is paired after M6' );
	my $pairings = $hap->{storage}->load_pairings;
	ok( exists $pairings->{'openhap-test-ctrl'},
		'controller identifier persisted' );
	is( $pairings->{'openhap-test-ctrl'}{permissions},
		1, 'initial controller is admin' );

};

subtest '[HAP-Pairing §2.6][HAP-Pairing §8] wrong PIN rejected' => sub {
	my ( $controller, $hap ) = make_pair( pin => '876-54-321' );

	ok( !$controller->pair_setup, 'pair-setup fails with wrong PIN' );
	is( $controller->last_error,
		Protocol::HAP::Pairing::kTLVError_Authentication(),
		'M4 carries kTLVError_Authentication (0x02)' );
	ok( !$hap->is_paired, 'accessory remains unpaired' );
	is( $hap->{pairing}->get_failed_attempts,
		1, 'attempt counter incremented' );
	is( $hap->{storage}->get_auth_attempts,
		1, 'attempt counter persisted' );

};

subtest '[HAP-Pairing §2.4] already-paired M2 error' => sub {
	my ( $controller, $hap, $session ) = make_pair();
	ok( $controller->pair_setup, 'first pairing succeeds' );

	# The accessory refuses a second controller on a fresh connection
	my $session2   = Protocol::HAP::Session->new( id => 9002 );
	my $transport2 = sub ($request_bytes) {
		my $request = FuguLib::HTTP::parse_request($request_bytes);
		return $hap->_dispatch( $request, $session2 );
	};
	my $second = OpenHAP::Test::Controller->new(
		pin           => $PIN,
		transport     => $transport2,
		controller_id => 'second-ctrl',
	);
	ok( !$second->pair_setup, 'second pair-setup refused' );
	is( $second->last_error,
		Protocol::HAP::Pairing::kTLVError_Unavailable(),
		'M2 carries kTLVError_Unavailable (0x06)' );

};

subtest '[HAP-Pairing §3] pair-verify and key derivation' => sub {
	my ( $controller, $hap, $session ) = make_pair();
	ok( $controller->pair_setup,  'pair-setup completes' );
	ok( $controller->pair_verify, 'pair-verify completes' );
	is( $controller->last_error, undef, 'no error recorded' );

	ok( $controller->is_encrypted, 'controller session encrypted' );
	ok( $session->is_encrypted,    'accessory session encrypted' );
	ok( $session->is_verified,     'accessory session verified' );
	is( $session->controller_id, 'openhap-test-ctrl',
		'accessory knows the controller identity' );

	# The derived keys interoperate. The authenticated request
	# succeeds.
	my $response = $controller->request( 'GET', '/accessories' );
	ok( defined $response, 'encrypted request round-trips' );
	is( $response->{status}, 200,
		'paired GET /accessories returns 200' );
	like( $response->{body}, qr/"accessories"/,
		'accessory database returned over the encrypted session' );

};

subtest '[HAP-Pairing §7.2] remove-pairing and last-admin behavior' =>
    sub {
	my ( $controller, $hap, $session ) = make_pair();
	ok( $controller->pair_setup,  'pair-setup completes' );
	ok( $controller->pair_verify, 'pair-verify completes' );

	# Add a second non-admin pairing. Then list both pairings.
	ok( $controller->add_pairing( 'user-ctrl', 'U' x 32, 0 ),
		'[HAP-Pairing §7.1] admin adds a second pairing' );
	my $pairings = $controller->list_pairings;
	is( scalar @$pairings, 2, '[HAP-Pairing §7.3] two pairings listed' );

	# The removal of a pairing that does not exist returns success
	ok( $controller->remove_pairing('ghost-ctrl'),
		'removing nonexistent pairing succeeds' );

	# The removal of the last admin clears all pairings
	my $old_ltpk = $hap->{accessory_ltpk};
	ok( $controller->remove_pairing, 'admin removes itself' );
	ok( !$hap->is_paired, 'all pairings removed with the last admin' );
	isnt( $hap->{accessory_ltpk}, $old_ltpk,
		'accessory identity regenerated after last admin removal' );

};

subtest '[HAP-Pairing §2.4] re-pair after remove' => sub {
	my ( $controller, $hap, $session ) = make_pair();
	ok( $controller->pair_setup, 'first pairing' );

	# Unpair directly through storage. The encrypted session died
	# when the previous flow regenerated the identity.
	$hap->{storage}->remove_all_pairings;
	ok( !$hap->is_paired, 'unpaired again' );

	my ( $controller2, $hap2 ) = make_pair();
	ok( $controller2->pair_setup, 'pair-setup succeeds after unpair' );

};

done_testing();
