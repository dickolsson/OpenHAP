#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

BEGIN {
    eval {
        require CryptX;
    };
    if ($@) {
        plan skip_all => 'CryptX not available';
    }
}

use_ok('OpenHAP::Session');
use_ok('OpenHAP::Crypto');

# Test session creation
{
    my $session = OpenHAP::Session->new(socket => 'dummy');
    ok(defined $session, 'Session object created');
    isa_ok($session, 'OpenHAP::Session');
    ok(!$session->is_encrypted(), 'Session not encrypted by default');
    ok(!$session->is_verified(), 'Session not verified by default');
}

# Test encryption setup
{
    my $session = OpenHAP::Session->new(socket => 'dummy');
    
    my $encrypt_key = OpenHAP::Crypto::generate_random_bytes(32);
    my $decrypt_key = OpenHAP::Crypto::generate_random_bytes(32);
    
    $session->set_encryption($encrypt_key, $decrypt_key);
    
    ok($session->is_encrypted(), 'Session is encrypted after setup');
}

# Test verification
{
    my $session = OpenHAP::Session->new(socket => 'dummy');
    
    $session->set_verified('controller-123');
    
    ok($session->is_verified(), 'Session is verified');
    is($session->controller_id(), 'controller-123', 'Controller ID stored');
}

# Test encryption/decryption
SKIP: {
    eval {
        require Crypt::AuthEnc::ChaCha20Poly1305;
    };
    skip 'ChaCha20Poly1305 not available', 4 if $@;
    
    my $session = OpenHAP::Session->new(socket => 'dummy');
    
    my $key = OpenHAP::Crypto::generate_random_bytes(32);
    $session->set_encryption($key, $key);
    
    my $plaintext = "Test message";
    my $encrypted = $session->encrypt($plaintext);
    
    ok(defined $encrypted, 'Data encrypted');
    isnt($encrypted, $plaintext, 'Encrypted data differs from plaintext');
    
    # Create a new session with the same keys for decryption
    my $session2 = OpenHAP::Session->new(socket => 'dummy');
    $session2->set_encryption($key, $key);
    
    my $decrypted = $session2->decrypt($encrypted);
    ok(defined $decrypted, 'Data decrypted');
    is($decrypted, $plaintext, 'Decrypted data matches original');
}

# Test encryption of longer data (multiple chunks)
SKIP: {
    eval {
        require Crypt::AuthEnc::ChaCha20Poly1305;
    };
    skip 'ChaCha20Poly1305 not available', 2 if $@;
    
    my $session = OpenHAP::Session->new(socket => 'dummy');
    my $key = OpenHAP::Crypto::generate_random_bytes(32);
    $session->set_encryption($key, $key);
    
    # Data larger than chunk size (1024 bytes)
    my $long_plaintext = "A" x 2500;
    my $encrypted = $session->encrypt($long_plaintext);
    
    ok(defined $encrypted, 'Long data encrypted');
    
    my $session2 = OpenHAP::Session->new(socket => 'dummy');
    $session2->set_encryption($key, $key);
    my $decrypted = $session2->decrypt($encrypted);
    
    is($decrypted, $long_plaintext, 'Long data decrypted correctly');
}

# Test pairing state storage
{
    my $session = OpenHAP::Session->new(socket => 'dummy');
    
    $session->{pairing_state}{test_key} = 'test_value';
    is($session->{pairing_state}{test_key}, 'test_value', 'Pairing state stored');
}

done_testing();
