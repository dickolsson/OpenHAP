#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

use_ok('OpenHAP::Service');

# Test service creation with known type
{
    my $service = OpenHAP::Service->new(
        type => 'Thermostat',
        iid => 10,
    );
    
    ok(defined $service, 'Service object created');
    isa_ok($service, 'OpenHAP::Service');
    is($service->{iid}, 10, 'Service IID set correctly');
    like($service->{type}, qr/^[0-9A-F-]+$/i, 'Service type is UUID');
}

# Test service with custom UUID
{
    my $custom_uuid = '12345678-1234-1234-1234-123456789012';
    my $service = OpenHAP::Service->new(
        type => $custom_uuid,
        iid => 20,
    );
    
    is($service->{type}, $custom_uuid, 'Custom UUID accepted');
}

# Test adding characteristics
{
    my $service = OpenHAP::Service->new(type => 'Switch', iid => 10);
    
    require OpenHAP::Characteristic;
    my $char = OpenHAP::Characteristic->new(
        type => 'On',
        iid => 11,
        format => 'bool',
        perms => ['pr', 'pw'],
        value => 0,
    );
    
    $service->add_characteristic($char);
    
    my @chars = $service->get_characteristics();
    is(scalar @chars, 1, 'One characteristic added');
    is($chars[0]->{iid}, 11, 'Characteristic IID correct');
}

# Test get_characteristic
{
    my $service = OpenHAP::Service->new(type => 'Switch', iid => 10);
    
    require OpenHAP::Characteristic;
    my $char1 = OpenHAP::Characteristic->new(type => 'On', iid => 11, format => 'bool', perms => ['pr'], value => 0);
    my $char2 = OpenHAP::Characteristic->new(type => 'Name', iid => 12, format => 'string', perms => ['pr'], value => 'Test');
    
    $service->add_characteristic($char1);
    $service->add_characteristic($char2);
    
    my $found = $service->get_characteristic(11);
    ok(defined $found, 'Characteristic found by IID');
    is($found->{iid}, 11, 'Correct characteristic returned');
    
    my $not_found = $service->get_characteristic(99);
    ok(!defined $not_found, 'Non-existent characteristic returns undef');
}

# Test JSON serialization
{
    my $service = OpenHAP::Service->new(
        type => 'Switch',
        iid => 10,
        primary => 1,
        hidden => 0,
    );
    
    require OpenHAP::Characteristic;
    my $char = OpenHAP::Characteristic->new(
        type => 'On',
        iid => 11,
        format => 'bool',
        perms => ['pr', 'pw'],
        value => 1,
    );
    $service->add_characteristic($char);
    
    my $json = $service->to_json();
    
    ok(exists $json->{type}, 'JSON has type');
    ok(exists $json->{iid}, 'JSON has iid');
    ok(exists $json->{characteristics}, 'JSON has characteristics');
    is(ref $json->{characteristics}, 'ARRAY', 'Characteristics is array');
    is(scalar @{$json->{characteristics}}, 1, 'One characteristic in JSON');
    ok(exists $json->{primary}, 'JSON has primary flag');
}

# Test UUID short form in JSON output
{
    my $service = OpenHAP::Service->new(type => 'Switch', iid => 10);
    my $json = $service->to_json();

    # The Switch UUID is 00000049-0000-1000-8000-0026BB765291. The
    # short form is "49".
    is($json->{type}, '49', 'Service type is in short form');

    # Test AccessoryInformation (3E)
    my $info_service = OpenHAP::Service->new(type => 'AccessoryInformation', iid => 1);
    my $info_json = $info_service->to_json();
    is($info_json->{type}, '3E', 'AccessoryInformation type is 3E in short form');

    # Test Thermostat (4A)
    my $therm_service = OpenHAP::Service->new(type => 'Thermostat', iid => 20);
    my $therm_json = $therm_service->to_json();
    is($therm_json->{type}, '4A', 'Thermostat type is 4A in short form');
}

# Test that the module does not shorten a custom UUID
{
    my $custom_uuid = '12345678-1234-1234-1234-123456789012';
    my $service = OpenHAP::Service->new(type => $custom_uuid, iid => 30);
    my $json = $service->to_json();
    is($json->{type}, $custom_uuid, 'Custom UUID preserved in JSON');
}

# Test get_characteristic_by_type
{
    my $service = OpenHAP::Service->new(type => 'Switch', iid => 10);

    require OpenHAP::Characteristic;
    my $on_char = OpenHAP::Characteristic->new(
        type => 'On', iid => 11, format => 'bool', perms => ['pr', 'pw'], value => 0
    );
    my $name_char = OpenHAP::Characteristic->new(
        type => 'Name', iid => 12, format => 'string', perms => ['pr'], value => 'Test'
    );

    $service->add_characteristic($on_char);
    $service->add_characteristic($name_char);

    my $found_on = $service->get_characteristic_by_type('On');
    ok(defined $found_on, 'Characteristic found by type name');
    is($found_on->{iid}, 11, 'Correct characteristic returned');

    my $found_name = $service->get_characteristic_by_type('Name');
    ok(defined $found_name, 'Another characteristic found by type');
    is($found_name->{iid}, 12, 'Correct Name characteristic returned');

    my $not_found = $service->get_characteristic_by_type('Identify');
    ok(!defined $not_found, 'Non-existent type returns undef');
}

# Test known service types
{
    my @known_types = qw(AccessoryInformation Thermostat Switch TemperatureSensor Outlet);
    
    for my $type (@known_types) {
        my $service = OpenHAP::Service->new(type => $type, iid => 1);
        ok(defined $service, "Service type $type recognized");
        like($service->{type}, qr/^[0-9A-F-]+$/i, "$type has valid UUID");
    }
}

done_testing();
