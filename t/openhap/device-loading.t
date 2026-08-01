#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

# Test device loading through OpenHAP::DeviceLoader with a mock config,
# a mock MQTT client, and a recording HAP stand-in.

use_ok('OpenHAP::DeviceLoader');

package MockConfig;

sub new ( $class, @devices )
{
	bless { devices => \@devices }, $class;
}

sub get_devices ($self) { @{ $self->{devices} } }

package MockMQTT;

sub new ( $class, %args )
{
	bless {
		connected     => $args{connected} // 1,
		subscriptions => {},
		published     => [],
	}, $class;
}

sub is_connected ($self) { $self->{connected} }

sub subscribe ( $self, $topic, $callback )
{
	$self->{subscriptions}{$topic} = $callback;
}

sub publish ( $self, $topic, $payload )
{
	push @{ $self->{published} }, { topic => $topic, payload => $payload };
}

package MockHAP;

sub new ($class) { bless { accessories => [] }, $class }

sub add_accessory ( $self, $accessory )
{
	push @{ $self->{accessories} }, $accessory;
}

package main;

# The loader loads a valid device and adds it to the bridge
{
	my $config = MockConfig->new( {
		type    => 'tasmota',
		subtype => 'thermostat',
		name    => 'Bedroom Thermostat',
		topic   => 'tasmota_bedroom',
		id      => 'TEST001',
	} );
	my $mqtt   = MockMQTT->new;
	my $hap    = MockHAP->new;
	my $loader = OpenHAP::DeviceLoader->new;

	my $count = $loader->load_devices( $config, $hap, $mqtt );
	is( $count, 1, 'One device loaded' );

	my @loaded = $loader->get_devices;
	is( scalar @loaded, 1, 'Loader tracks loaded device' );
	isa_ok( $loaded[0], 'OpenHAP::Tasmota::Thermostat' );
	is( $loaded[0]{aid}, 2, 'First device gets AID 2 (bridge is AID 1)' );
	is( scalar @{ $hap->{accessories} }, 1, 'Accessory added to bridge' );
	ok( scalar keys %{ $mqtt->{subscriptions} } > 0,
		'Device subscribed to MQTT topics' );
}

# The loader rejects a device without a name
{
	my $config = MockConfig->new( {
		type    => 'tasmota',
		subtype => 'thermostat',
		topic   => 'test/topic',
		id      => 'TEST001',
	} );
	my $loader = OpenHAP::DeviceLoader->new;

	my $count =
	    $loader->load_devices( $config, MockHAP->new, MockMQTT->new );
	is( $count, 0, 'Device without name is skipped' );
}

# The loader rejects a device without a topic
{
	my $config = MockConfig->new( {
		type    => 'tasmota',
		subtype => 'thermostat',
		name    => 'Test Device',
		id      => 'TEST001',
	} );
	my $loader = OpenHAP::DeviceLoader->new;

	my $count =
	    $loader->load_devices( $config, MockHAP->new, MockMQTT->new );
	is( $count, 0, 'Device without topic is skipped' );
}

# A device without an id uses the topic as the serial
{
	my $config = MockConfig->new( {
		type    => 'tasmota',
		subtype => 'heater',
		name    => 'Test Heater',
		topic   => 'test_heater',
	} );
	my $loader = OpenHAP::DeviceLoader->new;

	my $count =
	    $loader->load_devices( $config, MockHAP->new, MockMQTT->new );
	is( $count, 1, 'Device without id still loads' );

	my ($device) = $loader->get_devices;
	is( $device->{serial}, 'test_heater', 'Topic used as serial fallback' );
}

# The loader skips an unsupported device type
{
	my $config = MockConfig->new( {
		type    => 'zigbee',
		subtype => 'sensor',
		name    => 'Test Device',
		topic   => 'test/topic',
		id      => 'TEST001',
	} );
	my $loader = OpenHAP::DeviceLoader->new;

	my $count =
	    $loader->load_devices( $config, MockHAP->new, MockMQTT->new );
	is( $count, 0, 'Unsupported device type is skipped' );
}

# The loader defers the MQTT subscription while the broker is not
# connected
{
	my $config = MockConfig->new( {
		type    => 'tasmota',
		subtype => 'sensor',
		name    => 'Test Sensor',
		topic   => 'test_sensor',
		id      => 'SENS01',
	} );
	my $mqtt   = MockMQTT->new( connected => 0 );
	my $loader = OpenHAP::DeviceLoader->new;

	my $count = $loader->load_devices( $config, MockHAP->new, $mqtt );
	is( $count, 1, 'Device loads while MQTT disconnected' );
	is( scalar keys %{ $mqtt->{subscriptions} },
		0, 'Subscription deferred while disconnected' );
}

# Mixed configuration: the loader assigns AIDs in sequence and skips
# the invalid entries
{
	my $config = MockConfig->new(
		{
			type    => 'tasmota',
			subtype => 'lightbulb',
			name    => 'Light One',
			topic   => 'light1',
			id      => 'L1',
		},
		{
			type    => 'tasmota',
			subtype => 'unsupported',
			name    => 'Bogus',
			topic   => 'bogus',
			id      => 'B1',
		},
		{
			type    => 'tasmota',
			subtype => 'sensor',
			name    => 'Sensor One',
			topic   => 'sensor1',
			id      => 'S1',
		},
	);
	my $hap    = MockHAP->new;
	my $loader = OpenHAP::DeviceLoader->new;

	my $count = $loader->load_devices( $config, $hap, MockMQTT->new );
	is( $count, 2, 'Two of three devices loaded' );

	my @loaded = $loader->get_devices;
	isa_ok( $loaded[0], 'OpenHAP::Tasmota::Lightbulb' );
	isa_ok( $loaded[1], 'OpenHAP::Tasmota::Sensor' );
	is( $loaded[0]{aid}, 2, 'First device AID 2' );
	is( $loaded[1]{aid}, 3,
		'Second device AID 3 (skipped device consumes no AID)' );
}

done_testing();
