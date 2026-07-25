#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');
use File::Temp qw(tempdir);

use_ok('OpenHAP::Config');

# Create temporary config file
my $temp_dir    = tempdir(CLEANUP => 1);
my $config_file = "$temp_dir/openhap_test.conf";
open my $fh, '>', $config_file or die "Cannot create test config: $!";
print $fh <<'EOF';
# Test configuration
hap_name = "Test Bridge"
hap_port = 51827
hap_pin = 1995-1018

mqtt_host = 127.0.0.1

device tasmota thermostat bedroom {
    name = "Bedroom Thermostat"
    topic = tasmota_test
}
EOF
close $fh;

# Test loading
my $config = OpenHAP::Config->new(file => $config_file);
$config->load();

is($config->get('hap_name'), 'Test Bridge', 'Config value loaded');
is($config->get('hap_port'), 51827, 'Numeric value loaded');
is($config->get('mqtt_host'), '127.0.0.1', 'MQTT host loaded');

# Test devices
my @devices = $config->get_devices();
is(scalar @devices, 1, 'One device loaded');
is($devices[0]{type}, 'tasmota', 'Device type correct');
is($devices[0]{subtype}, 'thermostat', 'Device subtype correct');
is($devices[0]{name}, 'Bedroom Thermostat', 'Device name correct');
is($devices[0]{topic}, 'tasmota_test', 'Device topic correct');

# Test default value
is($config->get('nonexistent', 'default'), 'default', 'Default value returned');

done_testing();
