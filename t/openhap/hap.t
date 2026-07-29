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

# mDNS TXT record content is covered by t/conformance/hap-mdns.t

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

# Test config number tracking ([HAP-mDNS §3.1] c# increments on change)
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my %args = (
        port         => 51834,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    my $hap = OpenHAP::HAP->new(%args);
    is($hap->update_config_number, 1,
        '[HAP-mDNS §3.1] first run keeps c# at 1');
    is($hap->update_config_number, 1,
        'unchanged database keeps c# stable');

    # Restart with the same database: c# unchanged
    my $hap2 = OpenHAP::HAP->new(%args);
    is($hap2->update_config_number, 1,
        '[HAP-mDNS §8] c# persisted across restart');

    # Restart with an added accessory: c# increments
    require OpenHAP::Tasmota::Heater;
    require OpenHAP::TestMock::MQTT;
    my $hap3 = OpenHAP::HAP->new(%args);
    $hap3->add_accessory(
        OpenHAP::Tasmota::Heater->new(
            aid         => 2,
            name        => 'New Heater',
            mqtt_topic  => 'heater',
            mqtt_client => OpenHAP::TestMock::MQTT->new,
        ));
    is($hap3->update_config_number, 2,
        '[HAP-mDNS §3.1] c# increments when a device is added');
    is($hap3->get_mdns_txt_records->{'c#'}, 2, 'TXT c# reflects change');
}

# TXT string formatter: key=value pairs joined with '.' in sorted key
# order - mdnsd's TXT delimiter makes the ordering observable, so it
# must be deterministic ([HAP-mDNS §2])
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51836,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );

    my $txt     = $hap->get_mdns_txt_string;
    my $records = $hap->get_mdns_txt_records;

    # No default value carries a '.', so the pairs split back apart
    my @pairs = split /\./, $txt;
    is(scalar @pairs, scalar keys %$records,
        '[HAP-mDNS §2] every TXT record is one dot-separated pair');

    my @keys = map { /^([^=]+)=/ ? $1 : () } @pairs;
    is_deeply(\@keys, [sort keys %$records],
        'pairs appear in sorted key order');

    my %parsed = map { split /=/, $_, 2 } @pairs;
    is_deeply(\%parsed, $records, 'formatted string carries the records');
}

# Test mDNS re-advertisement on pairing change ([HAP-mDNS §8])
{
    package MockMDNS;

    sub new($class) { bless { updates => [], published => 1 }, $class }

    sub is_published($self) { return $self->{published} }

    sub update_txt($self, %args)
    {
        push @{ $self->{updates} }, $args{txt};
        return 1;
    }

    sub error($self) { return }

    package main;

    my $temp_dir = tempdir(CLEANUP => 1);
    my $hap = OpenHAP::HAP->new(
        port         => 51835,
        pin          => '123-45-678',
        storage_path => $temp_dir,
    );
    my $mdns = MockMDNS->new;
    $hap->set_mdns($mdns);

    # No change: no re-advertisement
    $hap->_refresh_mdns;
    is(scalar @{ $mdns->{updates} }, 0, 'no update without state change');

    # Pairing added: sf flips to 0 and the TXT record is re-advertised
    $hap->{storage}->save_pairing('controller', 'X' x 32, 1);
    $hap->_refresh_mdns;
    is(scalar @{ $mdns->{updates} }, 1,
        '[HAP-mDNS §8] TXT re-advertised when pairing added');
    like($mdns->{updates}[0], qr/(?:^|\.)sf=0(?:\.|$)/,
        'advertised sf=0 once paired');

    # Pairing removed: re-advertised again with sf=1
    $hap->{storage}->remove_all_pairings;
    $hap->_refresh_mdns;
    like($mdns->{updates}[1], qr/(?:^|\.)sf=1(?:\.|$)/,
        '[HAP-mDNS §8] advertised sf=1 when pairing removed');

    # Unpublished handle: the pairing path must never drive an update
    # onto it (the guard that used to live inside OpenHAP::MDNS)
    $mdns->{published} = 0;
    $hap->{storage}->save_pairing('controller', 'X' x 32, 1);
    $hap->_refresh_mdns;
    is(scalar @{ $mdns->{updates} }, 2,
        'no TXT update pushed while unpublished');
    $hap->{storage}->remove_all_pairings;
}

# Event emission behavior ([HAP-HTTP §14]) is covered end-to-end by
# t/conformance/hap-http.t, which drives the PUT handler and the MQTT
# device path against subscribed mock sessions.

done_testing();
