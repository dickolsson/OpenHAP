#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for OpenHAP::HAP module

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');
use File::Temp qw(tempdir);

BEGIN {
    eval {
        require IO::Socket::INET;
        require Crypt::Ed25519;
    };
    if ($@) {
        plan skip_all => 'Required modules not available';
    }
}

use_ok('OpenHAP::HAP');
use_ok('OpenHAP::Storage');
use_ok('OpenHAP::Crypto');
use_ok('OpenHAP::Pairing');

# Test HAP object creation
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51827,
        pin          => '123-45-678',
        name         => 'Test Bridge',
        storage_path => $temp_dir,
    );

    ok(defined $hap, 'HAP object created');
    isa_ok($hap, 'OpenHAP::HAP');
    ok(defined $hap->{storage}, 'Storage initialized');
    ok(defined $hap->{pairing}, 'Pairing handler initialized');
    ok(defined $hap->{bridge}, 'Bridge initialized');
}

# Test is_paired()
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51828,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    ok(!$hap->is_paired(), 'Not paired initially');

    # Add a pairing
    $hap->{storage}->save_pairing('test-controller', 'X' x 32, 1);
    ok($hap->is_paired(), 'Paired after adding pairing');
}

# Test get_device_id()
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51829,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    my $device_id = $hap->get_device_id();
    ok(defined $device_id, 'Device ID generated');
    like($device_id, qr/^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/, 'Device ID is MAC format');
}

# Test get_mdns_txt_records()
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51830,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    my $records = $hap->get_mdns_txt_records();
    ok(defined $records, 'mDNS records generated');
    ok(exists $records->{'c#'}, 'c# record exists');
    ok(exists $records->{'id'}, 'id record exists');
    ok(exists $records->{'sf'}, 'sf record exists');
    is($records->{'sf'}, 1, 'sf=1 when not paired');

    # Add pairing and check sf changes
    $hap->{storage}->save_pairing('test-controller', 'X' x 32, 1);
    $records = $hap->get_mdns_txt_records();
    is($records->{'sf'}, 0, 'sf=0 when paired');
}

# Test event queue initialization ([HAP-HTTP §14] event notifications)
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51831,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    ok(exists $hap->{event_queue}, '[HAP-HTTP §14] event queue exists');
    ok(ref $hap->{event_queue} eq 'HASH', 'Event queue is a hash');
    ok(!defined $hap->{event_flush_scheduled}, 'No flush scheduled initially');
}

# Test identity regeneration
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51832,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    my $old_ltpk = $hap->{accessory_ltpk};
    ok(defined $old_ltpk, 'Initial LTPK exists');

    # Call _regenerate_identity
    $hap->_regenerate_identity();

    my $new_ltpk = $hap->{accessory_ltpk};
    ok(defined $new_ltpk, 'New LTPK exists after regeneration');
    isnt($new_ltpk, $old_ltpk, 'LTPK changed after regeneration');

    # Verify keys were persisted
    my ($stored_ltsk, $stored_ltpk) = $hap->{storage}->load_accessory_keys();
    is($stored_ltpk, $new_ltpk, 'New LTPK persisted to storage');
}

# Test IMMEDIATE_EVENT_TYPES constant ([HAP-HTTP §14] event coalescing)
{
    # Constants are defined in the package, access via method
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51833,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    # Test that queue_event method exists (uses the constants internally)
    ok($hap->can('queue_event'), '[HAP-HTTP §14] queue_event method exists');
    ok($hap->can('flush_events'), 'flush_events method exists');
    ok($hap->can('send_event'), 'send_event method exists');
}

done_testing();
