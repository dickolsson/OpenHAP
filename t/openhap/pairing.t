#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::TestLog;
use File::Temp qw(tempdir);

BEGIN {
    eval {
        require Math::BigInt;
        require Digest::SHA;
    };
    if ($@) {
        plan skip_all => 'Required modules not available';
    }
}

use_ok('OpenHAP::Pairing');
use_ok('OpenHAP::Storage');
use_ok('Protocol::HAP::Crypto');
use_ok('OpenHAP::Session');

# Test pairing object creation
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 1 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    ok(defined $pairing, 'Pairing object created');
    isa_ok($pairing, 'OpenHAP::Pairing');
}

# Test TLV constants are defined
{
    ok(defined &OpenHAP::Pairing::kTLVType_Method, 'kTLVType_Method defined');
    ok(defined &OpenHAP::Pairing::kTLVType_State, 'kTLVType_State defined');
    ok(defined &OpenHAP::Pairing::kTLVType_Error, 'kTLVType_Error defined');
    ok(defined &OpenHAP::Pairing::kTLVType_PublicKey, 'kTLVType_PublicKey defined');
    ok(defined &OpenHAP::Pairing::kTLVType_Proof, 'kTLVType_Proof defined');
    ok(defined &OpenHAP::Pairing::kTLVType_EncryptedData, 'kTLVType_EncryptedData defined');
}

# Test error constants
{
    ok(defined &OpenHAP::Pairing::kTLVError_Unknown, 'kTLVError_Unknown defined');
    ok(defined &OpenHAP::Pairing::kTLVError_Authentication, 'kTLVError_Authentication defined');
    ok(defined &OpenHAP::Pairing::kTLVError_Backoff, 'kTLVError_Backoff defined');
    ok(defined &OpenHAP::Pairing::kTLVError_MaxPeers, 'kTLVError_MaxPeers defined');
}

# Test error response generation
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 2 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    my $error_response = $pairing->_error_response(
        OpenHAP::Pairing::kTLVError_Authentication(),
        2
    );
    
    ok(defined $error_response, 'Error response generated');
    ok(length($error_response) > 0, 'Error response has content');
}

# Test handle_pair_setup with invalid state
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 1 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    my $session = OpenHAP::Session->new(socket => 'dummy');
    
    # Create a TLV with an invalid state (99)
    require Protocol::HAP::TLV;
    my $body = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 99),
    );
    
    my $response = $pairing->handle_pair_setup($body, $session);
    ok(defined $response, 'Invalid state returns error response');
}

# Test handle_pair_verify with invalid state
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 1 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    my $session = OpenHAP::Session->new(socket => 'dummy');
    
    # Create a TLV with an invalid state (99)
    require Protocol::HAP::TLV;
    my $body = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 99),
    );
    
    my $response = $pairing->handle_pair_verify($body, $session);
    ok(defined $response, 'Invalid state returns error response');
}

# Test new TLV type constants
{
    ok(defined &OpenHAP::Pairing::kTLVType_SessionID, 'kTLVType_SessionID defined');
    ok(defined &OpenHAP::Pairing::kTLVType_Flags, 'kTLVType_Flags defined');
    is(OpenHAP::Pairing::kTLVType_SessionID(), 0x0E, '[HAP-TLV8 §5] kTLVType_SessionID is 0x0E');
    is(OpenHAP::Pairing::kTLVType_Flags(), 0x13, '[HAP-TLV8 §5] kTLVType_Flags is 0x13');
}

# Test kTLVError_MaxTries constant
{
    ok(defined &OpenHAP::Pairing::kTLVError_MaxTries, 'kTLVError_MaxTries defined');
    is(OpenHAP::Pairing::kTLVError_MaxTries(), 0x05, '[HAP-TLV8 §7] kTLVError_MaxTries is 0x05');
}

# Test invalid pairing method rejection
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 2 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    # Reset the global state for a clean test
    OpenHAP::Pairing->clear_pairing_state();
    OpenHAP::Pairing->reset_auth_attempts();
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    my $session = OpenHAP::Session->new(socket => 'dummy1');
    
    # Create a TLV with an invalid method (99)
    require Protocol::HAP::TLV;
    my $body = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 1),
        OpenHAP::Pairing::kTLVType_Method(), pack('C', 99),
    );
    
    my $response = $pairing->handle_pair_setup($body, $session);
    ok(defined $response, 'Invalid method returns response');
    
    # Decode the response to check for an error
    my %resp_tlv = Protocol::HAP::TLV::decode($response);
    my $error = unpack('C', $resp_tlv{ OpenHAP::Pairing::kTLVType_Error() } // '');
    is($error, OpenHAP::Pairing::kTLVError_Unknown(),
        '[HAP-TLV8 §6] invalid pairing method returns kTLVError_Unknown');

    OpenHAP::Pairing->clear_pairing_state();
}

# Test already-paired rejection
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 2 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    # Reset the global state
    OpenHAP::Pairing->clear_pairing_state();
    OpenHAP::Pairing->reset_auth_attempts();
    
    # Add an existing pairing
    $storage->save_pairing('test-controller', 'X' x 32, 1);
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    my $session = OpenHAP::Session->new(socket => 'dummy2');
    
    require Protocol::HAP::TLV;
    my $body = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 1),
        OpenHAP::Pairing::kTLVType_Method(), pack('C', 0),  # PairSetup
    );
    
    my $response = $pairing->handle_pair_setup($body, $session);
    my %resp_tlv = Protocol::HAP::TLV::decode($response);
    my $error = unpack('C', $resp_tlv{ OpenHAP::Pairing::kTLVType_Error() } // '');
    is($error, OpenHAP::Pairing::kTLVError_Unavailable(),
        '[HAP-Pairing §2.4] already paired returns kTLVError_Unavailable in M2');
    
    # The accessory must allow PairSetupWithAuth (method=1) even
    # when paired
    OpenHAP::Pairing->clear_pairing_state();
    my $session2 = OpenHAP::Session->new(socket => 'dummy3');
    my $body_auth = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 1),
        OpenHAP::Pairing::kTLVType_Method(), pack('C', 1),  # PairSetupWithAuth
    );
    
    my $response_auth = $pairing->handle_pair_setup($body_auth, $session2);
    my %resp_auth = Protocol::HAP::TLV::decode($response_auth);
    my $state = unpack('C', $resp_auth{ OpenHAP::Pairing::kTLVType_State() } // '');
    is($state, 2,
        '[HAP-Pairing §2.3] PairSetupWithAuth allowed when already paired (returns M2)');
    
    OpenHAP::Pairing->clear_pairing_state();
}

# Test concurrent pairing protection
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 1 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    # Reset the global state
    OpenHAP::Pairing->clear_pairing_state();
    OpenHAP::Pairing->reset_auth_attempts();
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    require Protocol::HAP::TLV;
    my $body = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 1),
        OpenHAP::Pairing::kTLVType_Method(), pack('C', 0),
    );
    
    # The first session starts the pairing
    my $session1 = OpenHAP::Session->new(socket => 'dummy4');
    my $response1 = $pairing->handle_pair_setup($body, $session1);
    my %resp1 = Protocol::HAP::TLV::decode($response1);
    my $state1 = unpack('C', $resp1{ OpenHAP::Pairing::kTLVType_State() } // '');
    
    # The second session tries to start the pairing and must get Busy
    my $session2 = OpenHAP::Session->new(socket => 'dummy5');
    my $response2 = $pairing->handle_pair_setup($body, $session2);
    my %resp2 = Protocol::HAP::TLV::decode($response2);
    my $error2 = unpack('C', $resp2{ OpenHAP::Pairing::kTLVType_Error() } // '');
    is($error2, OpenHAP::Pairing::kTLVError_Busy(),
        '[HAP-Pairing §2.4] concurrent pairing returns kTLVError_Busy in M2');
    
    OpenHAP::Pairing->clear_pairing_state();
}

# Test failed attempt counting
{
    OpenHAP::Pairing->reset_auth_attempts();
    is(OpenHAP::Pairing->get_failed_attempts(), 0,
        '[HAP-Pairing §8] failed attempt counter starts at 0');
}

# Test that the M2 public key does not contain a '0x' prefix (bug fix)
SKIP: {
    eval {
        require Crypt::Ed25519;
    };
    skip 'Crypt::Ed25519 not available', 3 if $@;
    
    my $temp_dir = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    my ($ltsk, $ltpk) = Protocol::HAP::Crypto->ed25519_keypair;
    
    # Reset the global state
    OpenHAP::Pairing->clear_pairing_state();
    OpenHAP::Pairing->reset_auth_attempts();
    
    my $pairing = OpenHAP::Pairing->new(
        pin => '123-45-678',
        storage => $storage,
        accessory_ltsk => $ltsk,
        accessory_ltpk => $ltpk,
    );
    
    my $session = OpenHAP::Session->new(socket => 'dummy6');
    
    require Protocol::HAP::TLV;
    my $body = Protocol::HAP::TLV::encode(
        OpenHAP::Pairing::kTLVType_State(), pack('C', 1),
        OpenHAP::Pairing::kTLVType_Method(), pack('C', 0),
    );
    
    my $response = $pairing->handle_pair_setup($body, $session);
    my %resp = Protocol::HAP::TLV::decode($response);
    
    ok(defined $resp{ OpenHAP::Pairing::kTLVType_PublicKey() }, 'M2 contains PublicKey');
    
    my $public_key = $resp{ OpenHAP::Pairing::kTLVType_PublicKey() };
    my $hex = unpack('H*', $public_key);
    
    # Make sure that the hex does not start with '30', which is
    # ASCII '0'. With the bug, the hex would start with '307830...'
    # (0x30='0', 0x78='x').
    isnt(substr($hex, 0, 4), '3078',
        '[HAP-Pairing §2.4] public key does not start with ASCII "0x"');

    # The public key must be 384 bytes (3072 bits)
    is(length($public_key), 384,
        '[HAP-Pairing §2.4] M2 public key B is 384 bytes (3072 bits)');
    
    OpenHAP::Pairing->clear_pairing_state();
}

done_testing();
