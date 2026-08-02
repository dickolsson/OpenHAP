#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Session-framing assertions for spec/HAP-Encryption.md.
# OpenHAP::Test::Controller makes a real verified in-process session.
# The tests assert on the frames of that session.

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
use_ok('OpenHAP::Session');
use_ok('OpenHAP::Pairing');
use_ok('OpenHAP::Test::Controller');

my $PIN = '123-45-678';

# The transport records the raw encrypted bytes in both directions
my @wire;

sub make_verified_pair ()
{
	OpenHAP::Pairing->clear_pairing_state();

	my $hap = OpenHAP::HAP->new(
		port         => 51827,
		pin          => $PIN,
		name         => 'Frame Bridge',
		storage_path => tempdir( CLEANUP => 1 ),
	);
	$hap->{pairing}->reset_auth_attempts;

	my $session   = OpenHAP::Session->new( socket => 'in-process' );
	my $transport = sub ($request_bytes) {
		my $was_encrypted = $session->is_encrypted;
		push @wire,
		    {
			direction => 'c2a',
			encrypted => $was_encrypted,
			bytes     => $request_bytes
		    };
		my $plain =
		    $was_encrypted
		    ? $session->decrypt($request_bytes)
		    : $request_bytes;
		return unless defined $plain;
		my $request  = FuguLib::HTTP::parse_request($plain);
		my $response = $hap->_dispatch( $request, $session );
		$response = $session->encrypt($response) if $was_encrypted;
		push @wire,
		    {
			direction => 'a2c',
			encrypted => $was_encrypted,
			bytes     => $response
		    };
		return $response;
	};

	my $controller = OpenHAP::Test::Controller->new(
		pin       => $PIN,
		transport => $transport,
	);

	ok( $controller->pair_setup,  'pair-setup completes' );
	ok( $controller->pair_verify, 'pair-verify completes' );
	@wire = ();

	return ( $controller, $hap, $session );
}

sub frame_lengths ($bytes)
{
	my @lengths;
	my $pos = 0;
	while ( $pos + 2 <= length($bytes) ) {
		my $length = unpack( 'v', substr( $bytes, $pos, 2 ) );
		push @lengths, $length;
		$pos += 2 + $length + 16;
	}
	return ( \@lengths, $pos == length($bytes) );
}

subtest '[HAP-Encryption §2][HAP-Encryption §3] frame layout both '
    . 'directions' => sub {
	my ( $controller, $hap, $session ) = make_verified_pair();

	my $response = $controller->request( 'GET', '/accessories' );
	is( $response->{status}, 200, 'encrypted request succeeded' );

	my ($c2a) = grep { $_->{direction} eq 'c2a' } @wire;
	my ($a2c) = grep { $_->{direction} eq 'a2c' } @wire;

	for my $leg ( [ 'controller-to-accessory', $c2a ],
		[ 'accessory-to-controller', $a2c ] )
	{
		my ( $name, $capture ) = @$leg;
		ok( $capture->{encrypted}, "$name leg is encrypted" );

		my ( $lengths, $exact ) =
		    frame_lengths( $capture->{bytes} );
		ok( $exact,
			"$name stream is a whole number of frames" );
		ok( ( !grep { $_ > 1024 } @$lengths ),
			"$name frames carry at most 1024 bytes" );

		# Each frame is: 2-byte LE length + ciphertext + 16-byte tag
		my $expected = 0;
		$expected += 2 + $_ + 16 for @$lengths;
		is( length( $capture->{bytes} ),
			$expected, "$name frame overhead is 18 bytes" );
	}

	# The plaintext is not visible on the wire
	unlike( $a2c->{bytes}, qr/"accessories"/,
		'accessory JSON not visible in the encrypted stream' );

	OpenHAP::Pairing->clear_pairing_state();
};

subtest '[HAP-Encryption §4][HAP-Encryption §6] counters increment '
    . 'per frame and direction' => sub {
	my ( $controller, $hap, $session ) = make_verified_pair();

	$controller->request( 'GET', '/accessories' );
	$controller->request( 'GET', '/accessories' );

	# There are two requests and two responses. The response to
	# /accessories is larger than 1024 bytes. Thus it spans several
	# frames.
	my @c2a = grep { $_->{direction} eq 'c2a' } @wire;
	is( scalar @c2a, 2, 'two request transmissions' );

	is( $controller->{encrypt_count},
		2, 'controller write counter advanced once per frame' );
	cmp_ok( $controller->{decrypt_count}, '>=', 2,
		'controller read counter advanced per response frame' );
	is( $session->{decrypt_count},
		$controller->{encrypt_count},
		'accessory read counter mirrors controller writes' );
	is( $session->{encrypt_count},
		$controller->{decrypt_count},
		'accessory write counter mirrors controller reads' );

	OpenHAP::Pairing->clear_pairing_state();
};

subtest '[HAP-Encryption §9] tampered frame fails the session' => sub {
	my ( $controller, $hap, $session ) = make_verified_pair();

	# Build a valid encrypted request. Then flip a ciphertext bit.
	my $raw = $controller->_build_request( 'GET', '/accessories' );
	my $encrypted = $controller->_encrypt($raw);
	substr( $encrypted, 5, 1 ) =
	    substr( $encrypted, 5, 1 ) ^. "\x01";

	ok( !defined $session->decrypt($encrypted),
		'accessory rejects the tampered frame' );

	OpenHAP::Pairing->clear_pairing_state();
};

done_testing();
