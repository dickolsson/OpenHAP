#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

# Test Crypto module
BEGIN {
    # Skip the tests if the crypto modules are not available
    eval {
        require Crypt::Curve25519;
        require Crypt::Ed25519;
        require CryptX;
    };
    if ($@) {
        plan skip_all => 'Crypto modules not available';
    }
}

use_ok('OpenHAP::Crypto');

# Test random byte generation
{
    my $bytes = OpenHAP::Crypto::generate_random_bytes(32);
    ok(defined $bytes, 'Random bytes generated');
    is(length($bytes), 32, 'Random bytes has correct length');
    
    my $bytes2 = OpenHAP::Crypto::generate_random_bytes(32);
    isnt($bytes, $bytes2, 'Random bytes are different');
}

# Test Ed25519 keypair generation
{
    my ($secret, $public) = OpenHAP::Crypto::generate_keypair_ed25519();
    ok(defined $secret, 'Ed25519 secret key generated');
    ok(defined $public, 'Ed25519 public key generated');
    is(length($secret), 64, 'Ed25519 secret key has correct length');
    is(length($public), 32, 'Ed25519 public key has correct length');
}

# Test Ed25519 signing and verification
{
    my ($secret, $public) = OpenHAP::Crypto::generate_keypair_ed25519();
    my $message = "Test message for signing";
    
    my $signature = OpenHAP::Crypto::sign_ed25519($message, $secret, $public);
    ok(defined $signature, 'Ed25519 signature created');
    is(length($signature), 64, 'Ed25519 signature has correct length');
    
    my $valid = OpenHAP::Crypto::verify_ed25519($signature, $message, $public);
    ok($valid, 'Ed25519 signature verifies correctly');
    
    # Test invalid signature
    my $bad_sig = $signature;
    substr($bad_sig, 0, 1) = chr(ord(substr($bad_sig, 0, 1)) ^ 0xFF);
    my $invalid = OpenHAP::Crypto::verify_ed25519($bad_sig, $message, $public);
    ok(!$invalid, 'Invalid Ed25519 signature rejected');
}

# Test X25519 keypair generation
{
    my ($secret, $public) = OpenHAP::Crypto::generate_keypair_x25519();
    ok(defined $secret, 'X25519 secret key generated');
    ok(defined $public, 'X25519 public key generated');
    is(length($secret), 32, 'X25519 secret key has correct length');
    is(length($public), 32, 'X25519 public key has correct length');
}

# Test X25519 shared secret derivation
{
    my ($secret1, $public1) = OpenHAP::Crypto::generate_keypair_x25519();
    my ($secret2, $public2) = OpenHAP::Crypto::generate_keypair_x25519();
    
    my $shared1 = OpenHAP::Crypto::derive_shared_secret($secret1, $public2);
    my $shared2 = OpenHAP::Crypto::derive_shared_secret($secret2, $public1);
    
    ok(defined $shared1, 'Shared secret 1 derived');
    ok(defined $shared2, 'Shared secret 2 derived');
    is($shared1, $shared2, 'Shared secrets match');
}

# Test HKDF-SHA512
{
    my $ikm = "input key material";
    my $salt = "salt value";
    my $info = "context info";
    
    my $key = OpenHAP::Crypto::hkdf_sha512($ikm, $salt, $info, 32);
    ok(defined $key, 'HKDF key derived');
    is(length($key), 32, 'HKDF key has correct length');
    
    # Make sure the derivation is deterministic
    my $key2 = OpenHAP::Crypto::hkdf_sha512($ikm, $salt, $info, 32);
    is($key, $key2, 'HKDF is deterministic');
}

# Test ChaCha20-Poly1305 encryption/decryption
{
    my $key = OpenHAP::Crypto::generate_random_bytes(32);
    my $nonce = OpenHAP::Crypto::generate_random_bytes(12);
    my $plaintext = "Secret message to encrypt";
    my $aad = "Additional authenticated data";
    
    my ($ciphertext, $tag) = OpenHAP::Crypto::chacha20_poly1305_encrypt(
        $key, $nonce, $plaintext, $aad
    );
    
    ok(defined $ciphertext, 'Ciphertext generated');
    ok(defined $tag, 'Authentication tag generated');
    is(length($tag), 16, 'Tag has correct length');
    isnt($ciphertext, $plaintext, 'Ciphertext differs from plaintext');
    
    my $decrypted = OpenHAP::Crypto::chacha20_poly1305_decrypt(
        $key, $nonce, $ciphertext, $tag, $aad
    );
    
    ok(defined $decrypted, 'Decryption succeeded');
    is($decrypted, $plaintext, 'Decrypted text matches original');
    
    # Test with wrong AAD
    my $bad_decrypt = OpenHAP::Crypto::chacha20_poly1305_decrypt(
        $key, $nonce, $ciphertext, $tag, "wrong aad"
    );
    ok(!defined $bad_decrypt, 'Decryption fails with wrong AAD');
}

done_testing();
