#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Conformance tests for spec/MQTT-Sensors.md

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new( mode => 'quiet', ident => 'test' );

use_ok('OpenHAP::TestMock::MQTT');
use_ok('OpenHAP::Tasmota::Sensor');
use_ok('OpenHAP::Tasmota::Base');

sub make_sensor ( $mqtt, %extra )
{
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid         => 2,
		name        => 'Sensor',
		mqtt_topic  => 'sensor',
		mqtt_client => $mqtt,
		%extra,
	);
	$sensor->subscribe_mqtt;
	return $sensor;
}

subtest '[MQTT-Sensors §1] SENSOR message structure' => sub {
	my $mqtt   = OpenHAP::TestMock::MQTT->new;
	my $sensor = make_sensor($mqtt);

	ok( ( grep { $_ eq 'tele/sensor/SENSOR' }
		    $mqtt->get_subscriptions ),
		'[MQTT-Sensors §5.2] subscribed to tele/+/SENSOR' );

	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"Time":"2024-01-01T00:00:00",'
		    . '"DS18B20":{"Temperature":25.5},"TempUnit":"C"}' );
	is( $sensor->{current_temp}, 25.5,
		'per-sensor object parsed from SENSOR message' );
};

subtest '[MQTT-Sensors §2] common sensor types' => sub {
	my $mqtt   = OpenHAP::TestMock::MQTT->new;
	my $sensor = make_sensor($mqtt);

	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"DS18B20":{"Temperature":21},"TempUnit":"C"}' );
	is( $sensor->{sensor_type}, 'DS18B20',
		'[MQTT-Sensors §2/DS18B20] type auto-detected' );

	my $dht = make_sensor(
		OpenHAP::TestMock::MQTT->new,
		aid          => 3,
		name         => 'DHT',
		has_humidity => 1,
	);
	$dht->{mqtt_client}->simulate_message( 'tele/sensor/SENSOR',
		'{"DHT22":{"Temperature":22.5,"Humidity":65},"TempUnit":"C"}'
	);
	is( $dht->{sensor_type}, 'DHT22',
		'[MQTT-Sensors §2/DHT11] DHT-family type auto-detected' );
};

subtest '[MQTT-Sensors §3] temperature sensors' => sub {
	my $mqtt   = OpenHAP::TestMock::MQTT->new;
	my $sensor = make_sensor($mqtt);

	# The sensor passes TempUnit C readings through
	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"DS18B20":{"Temperature":25},"TempUnit":"C"}' );
	is( $sensor->{current_temp}, 25, 'Celsius reading passed through' );

	# The sensor converts TempUnit F readings before use in HomeKit
	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"DS18B20":{"Temperature":77},"TempUnit":"F"}' );
	ok( abs( $sensor->{current_temp} - 25 ) < 0.1,
		'TempUnit F converted to Celsius (77F = 25C)' );

	# The conversion helper converts the boundary case correctly
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 9,
		name        => 'Conv',
		mqtt_topic  => 'conv',
		mqtt_client => $mqtt,
	);
	$base->{temp_unit} = 'F';
	ok( abs( $base->convert_temperature(32) ) < 0.1, '32F = 0C' );

	# Multiple sensors report under indexed keys
	my $indexed = make_sensor(
		OpenHAP::TestMock::MQTT->new,
		aid          => 4,
		name         => 'Indexed',
		sensor_type  => 'DS18B20',
		sensor_index => 2,
	);
	$indexed->{mqtt_client}->simulate_message( 'tele/sensor/SENSOR',
		'{"DS18B20-1":{"Temperature":20},'
		    . '"DS18B20-2":{"Temperature":25},"TempUnit":"C"}' );
	is( $indexed->{current_temp}, 25,
		'indexed sensor DS18B20-2 selected' );

	# The module tracks the sensor Id field
	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"DS18B20":{"Id":"01131B123456","Temperature":22.5},'
		    . '"TempUnit":"C"}' );
	is( $sensor->{sensor_id}, '01131B123456', 'sensor Id tracked' );
};

subtest '[MQTT-Sensors §4] humidity sensors' => sub {
	my $mqtt   = OpenHAP::TestMock::MQTT->new;
	my $sensor = make_sensor( $mqtt, has_humidity => 1 );

	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"DHT22":{"Temperature":22.5,"Humidity":65},"TempUnit":"C"}'
	);
	is( $sensor->{current_temp},     22.5, 'temperature from DHT22' );
	is( $sensor->{current_humidity}, 65,   'humidity from DHT22' );
};

subtest '[MQTT-Sensors §5][MQTT-Sensors §5.1] TelePeriod forces telemetry' => sub {
	my $mqtt = OpenHAP::TestMock::MQTT->new;
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Tele',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
	);

	$mqtt->clear_published;
	$base->force_telemetry;
	ok( ( grep { $_->{topic} eq 'cmnd/device/TelePeriod' }
		    $mqtt->get_published ),
		'TelePeriod command forces a telemetry report' );
};

done_testing();
