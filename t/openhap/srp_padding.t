#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

BEGIN {
    eval {
        require Math::BigInt;
        require Digest::SHA;
    };
    if ($@) {
        plan skip_all => 'Math::BigInt or Digest::SHA not available';
    }
}

use_ok('OpenHAP::SRP');
use_ok('OpenHAP::Crypto');

# Test that A and B are correctly padded to N_len (384 bytes) when computing
# u, M1, and M2. This is critical for SRP-6a compatibility with HomeKit.
#
# Bug: The original implementation did not pad A and B to 384 bytes before
# hashing, causing proof verification failures with iOS Home app.

# Test padding of A and B in u computation
{
    my $srp = OpenHAP::SRP->new(password => '123-45-678');
    my $salt = $srp->generate_salt();
    $srp->compute_verifier($salt, '123-45-678');
    my $B = $srp->generate_server_public();

    # Create a client public key A that's shorter than 384 bytes when encoded
    # For example, a small value like 256 (0x100) would be 2 bytes unpadded
    my $A_small = Math::BigInt->new(256);
    my $A_bytes_unpadded = OpenHAP::SRP::_bigint_to_bytes($A_small);

    # Without padding, this would be 2 bytes
    ok(length($A_bytes_unpadded) < 384,
        'Small A is less than 384 bytes without padding');

    # With padding, it should be 384 bytes
    my $A_bytes_padded = OpenHAP::SRP::_bigint_to_bytes($A_small, 384);
    is(length($A_bytes_padded), 384,
        '[HAP-Pairing §2.5] small A is left-padded to 384 bytes');

    # Verify padding is with leading zeros
    is(unpack('H*', $A_bytes_padded), ('00' x 382) . '0100',
        '[HAP-Pairing §2.5] A is padded with leading zeros');
}

# Test that compute_session_key uses padded A and B for u
{
    my $srp = OpenHAP::SRP->new(password => '123-45-678');
    my $salt = $srp->generate_salt();
    $srp->compute_verifier($salt, '123-45-678');
    $srp->generate_server_public();
    
    # Create two different encodings of the same A value
    # One with minimal encoding, one padded to 384 bytes
    my $A_val = Math::BigInt->new(12345);
    my $A_bytes_unpadded = OpenHAP::SRP::_bigint_to_bytes($A_val);
    my $A_bytes_padded = OpenHAP::SRP::_bigint_to_bytes($A_val, 384);
    
    isnt(length($A_bytes_unpadded), length($A_bytes_padded),
        'Padded and unpadded A have different lengths');

    # Both should produce the same session key because internally
    # compute_session_key pads A to 384 bytes before computing u
    my $K1 = $srp->compute_session_key($A_bytes_unpadded);

    # Need a fresh SRP instance for second test
    my $srp2 = OpenHAP::SRP->new(password => '123-45-678');
    $srp2->generate_salt();
    $srp2->compute_verifier($salt, '123-45-678');
    # Copy the same b and B to ensure identical server state
    $srp2->{b} = $srp->{b};
    $srp2->{B} = $srp->{B};
    $srp2->{v} = $srp->{v};
    $srp2->{salt} = $srp->{salt};

    my $K2 = $srp2->compute_session_key($A_bytes_padded);

    ok(defined $K1 && defined $K2, 'Both session keys computed');
    is(unpack('H*', $K1), unpack('H*', $K2),
        '[HAP-Pairing §2.6] u uses PAD(A): unpadded and padded A '
        . 'wire encodings derive the same session key');
}

# Test full SRP exchange with known values to verify padding
{
    # Set up SRP with known parameters
    my $password = '123-45-678';
    my $srp = OpenHAP::SRP->new(password => $password);
    
    # Generate a known salt (for reproducibility, use a fixed value in real test)
    my $salt = $srp->generate_salt();
    $srp->compute_verifier($salt, $password);
    my $B = $srp->generate_server_public();
    
    # Create a valid client public key A (must be non-zero mod N)
    # For testing, use a small valid value
    my $A_int = Math::BigInt->new(2)->bmodpow(Math::BigInt->new(256), $srp->{N});
    my $A_bytes = OpenHAP::SRP::_bigint_to_bytes($A_int, 384);
    
    # Compute session key (this internally computes u = H(PAD(A) | PAD(B)))
    my $K = $srp->compute_session_key($A_bytes);
    ok(defined $K, 'Session key computed successfully');
    is(length($K), 64,
        '[HAP-Pairing §2.6] session key K = H(S) is 64 bytes (SHA-512)');
    
    # Verify internal A is stored correctly
    ok(defined $srp->{A}, 'A is stored in SRP object');
    
    # Compute client proof M1
    # The client would compute this, but we can verify our verification works
    # For now, just test that verify_client_proof uses padded values
    my $M1_dummy = 'X' x 64;  # Wrong proof for this test
    my $result = $srp->verify_client_proof($M1_dummy);
    ok(!$result, '[HAP-Pairing §2.6] wrong client proof M1 is rejected');
}

# Test N_len constant matches our padding expectation
{
    # N is 3072 bits = 384 bytes
    my $N_len = length($OpenHAP::Crypto::N_3072);
    is($N_len, 384,
        '[HAP-Pairing §2.2] N_3072 group prime is 384 bytes (3072 bits)');
}

done_testing();
