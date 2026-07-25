#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for Tasmota device modules

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');

# Mock MQTT client for testing
package MockMQTT;

sub new($class) {
	bless {
		subscriptions => {},
		published     => [],
		connected     => 1,
	}, $class;
}

sub is_connected($self) { $self->{connected} }

sub subscribe( $self, $topic, $callback )
{
	$self->{subscriptions}{$topic} = $callback;
}

sub publish( $self, $topic, $payload )
{
	push @{ $self->{published} }, { topic => $topic, payload => $payload };
}

sub get_subscriptions($self) { keys %{ $self->{subscriptions} } }

sub get_published($self) { @{ $self->{published} } }

sub clear_published($self) { $self->{published} = [] }

sub simulate_message( $self, $topic, $payload )
{
	for my $pattern ( keys %{ $self->{subscriptions} } ) {
		if ( _topic_matches( $pattern, $topic ) ) {
			$self->{subscriptions}{$pattern}->( $topic, $payload );
		}
	}
}

sub _topic_matches( $pattern, $topic )
{
	return 1 if $pattern eq $topic;
	return 0 unless $pattern =~ m{[+#]};

	my @pattern_parts = split m{/}, $pattern;
	my @topic_parts   = split m{/}, $topic;

	for my $i ( 0 .. $#pattern_parts ) {
		my $p = $pattern_parts[$i];
		return 1 if $p eq '#';
		return 0 if $i > $#topic_parts;
		next     if $p eq '+';
		return 0 if $p ne $topic_parts[$i];
	}

	return @topic_parts == @pattern_parts;
}

package main;

use_ok('OpenHAP::Tasmota::Base');
use_ok('OpenHAP::Tasmota::Heater');
use_ok('OpenHAP::Tasmota::Sensor');
use_ok('OpenHAP::Tasmota::Thermostat');
use_ok('OpenHAP::Tasmota::Lightbulb');

# Import constants for easier use in tests
use constant AVAILABILITY_UNKNOWN => 0;
use constant AVAILABILITY_ONLINE  => 1;
use constant AVAILABILITY_OFFLINE => 2;
use constant CAP_DIMMER           => 1;
use constant CAP_COLOR            => 2;
use constant CAP_CT               => 4;

# Test Base class
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Test Base',
		mqtt_topic  => 'test_device',
		mqtt_client => $mqtt,
	);

	ok( defined $base, 'Base device created' );
	is( $base->{mqtt_topic}, 'test_device', 'MQTT topic set' );
	is( $base->{availability},
		AVAILABILITY_UNKNOWN,
		'Initial availability is unknown' );
}

# Test Base MQTT subscriptions
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Test Base',
		mqtt_topic  => 'test_device',
		mqtt_client => $mqtt,
	);

	$base->subscribe_mqtt();

	my @subs = $mqtt->get_subscriptions();
	ok( ( grep { $_ eq 'tele/test_device/LWT' } @subs ),
		'[MQTT-Transport §1.4] Subscribed to LWT' );
	ok( ( grep { $_ eq 'tele/test_device/STATE' } @subs ),
		'[MQTT-State §2] Subscribed to tele/STATE' );
	ok( ( grep { $_ eq 'stat/test_device/RESULT' } @subs ),
		'[MQTT-State §1] Subscribed to stat/RESULT' );
	ok( ( grep { $_ eq 'tele/test_device/SENSOR' } @subs ),
		'[MQTT-Sensors §1] Subscribed to tele/SENSOR' );
}

# Test LWT handling
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Test Base',
		mqtt_topic  => 'test_device',
		mqtt_client => $mqtt,
	);

	$base->subscribe_mqtt();

	# Simulate Online message
	$mqtt->simulate_message( 'tele/test_device/LWT', 'Online' );
	is( $base->{availability},
		AVAILABILITY_ONLINE,
		'[MQTT-Transport §4.2] LWT Online sets availability' );
	ok( $base->is_online(), 'is_online() returns true' );

	# Check that Status 11 was queried
	my @published = $mqtt->get_published();
	ok( ( grep { $_->{topic} eq 'cmnd/test_device/Status'
			    && $_->{payload} eq '11' } @published ),
		'[MQTT-State §5.2] Status 11 queried on Online' );

	# Simulate Offline message
	$mqtt->simulate_message( 'tele/test_device/LWT', 'Offline' );
	is( $base->{availability},
		AVAILABILITY_OFFLINE,
		'[MQTT-Transport §4.2] LWT Offline sets availability' );
	ok( !$base->is_online(), 'is_online() returns false' );
}

# Test temperature conversion
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Test Base',
		mqtt_topic  => 'test_device',
		mqtt_client => $mqtt,
	);

	# Test Celsius passthrough
	$base->{temp_unit} = 'C';
	is( $base->convert_temperature(25), 25, '[MQTT-Sensors §3] Celsius passthrough' );

	# Test Fahrenheit to Celsius conversion
	$base->{temp_unit} = 'F';
	my $celsius = $base->convert_temperature(77);    # 77F = 25C
	ok( abs( $celsius - 25 ) < 0.1, '[MQTT-Sensors §3] Fahrenheit to Celsius conversion' );

	# Test 32F = 0C
	$celsius = $base->convert_temperature(32);
	ok( abs($celsius) < 0.1, '[MQTT-Sensors §3] 32F = 0C' );
}

# Test multi-relay support
{
	my $mqtt = MockMQTT->new();

	# Default (no index)
	my $heater1 = OpenHAP::Tasmota::Heater->new(
		aid         => 2,
		name        => 'Heater 1',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
	);

	is( $heater1->_get_power_key(),   'POWER',           '[MQTT-Control §1] No index: POWER' );
	is( $heater1->_get_power_topic(), 'cmnd/device/Power', 'No index topic' );

	# With relay index
	my $heater2 = OpenHAP::Tasmota::Heater->new(
		aid         => 3,
		name        => 'Heater 2',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
		relay_index => 2,
	);

	is( $heater2->_get_power_key(), 'POWER2', '[MQTT-Control §1] Index 2: POWER2' );
	is( $heater2->_get_power_topic(),
		'cmnd/device/Power2', 'Index 2 topic' );
}

# Test Heater device
{
	my $mqtt = MockMQTT->new();
	my $heater = OpenHAP::Tasmota::Heater->new(
		aid         => 2,
		name        => 'Test Heater',
		mqtt_topic  => 'heater',
		mqtt_client => $mqtt,
	);

	ok( defined $heater,            'Heater created' );
	is( $heater->{power_state}, 0,  'Initial power state is off' );

	$heater->subscribe_mqtt();

	# Test power control
	$mqtt->clear_published();
	$heater->set_power(1);

	my @published = $mqtt->get_published();
	is( $published[0]{topic},   'cmnd/heater/Power', '[MQTT-Control §1] Power topic correct' );
	is( $published[0]{payload}, 'ON',                '[MQTT-Control §1] Power ON sent' );

	# Test TOGGLE
	$mqtt->clear_published();
	$heater->toggle_power();
	@published = $mqtt->get_published();
	is( $published[0]{payload}, 'TOGGLE', '[MQTT-Control §1] TOGGLE command works' );

	# Test BLINK
	$mqtt->clear_published();
	$heater->blink(1);
	@published = $mqtt->get_published();
	is( $published[0]{payload}, 'BLINK', '[MQTT-Control §1] BLINK command works' );

	$mqtt->clear_published();
	$heater->blink(0);
	@published = $mqtt->get_published();
	is( $published[0]{payload}, 'BLINKOFF', '[MQTT-Control §1] BLINKOFF command works' );
}

# Test Heater state updates
{
	my $mqtt = MockMQTT->new();
	my $heater = OpenHAP::Tasmota::Heater->new(
		aid         => 2,
		name        => 'Test Heater',
		mqtt_topic  => 'heater',
		mqtt_client => $mqtt,
	);

	$heater->subscribe_mqtt();

	# Test RESULT message
	$mqtt->simulate_message( 'stat/heater/RESULT', '{"POWER":"ON"}' );
	is( $heater->{power_state}, 1, '[MQTT-State §4] RESULT updates power state' );

	# Test plain POWER message
	$mqtt->simulate_message( 'stat/heater/POWER', 'OFF' );
	is( $heater->{power_state}, 0, '[MQTT-State §1] plain POWER updates power state' );

	# Test STATE message
	$mqtt->simulate_message( 'tele/heater/STATE',
		'{"POWER":"ON","Uptime":"1T00:00:00"}' );
	is( $heater->{power_state}, 1, '[MQTT-State §3] STATE updates power state' );
}

# Test Sensor device with multiple sensor types
{
	my $mqtt = MockMQTT->new();
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid         => 2,
		name        => 'Test Sensor',
		mqtt_topic  => 'sensor',
		mqtt_client => $mqtt,
	);

	ok( defined $sensor, 'Sensor created' );
	is( $sensor->{current_temp}, 20.0, 'Initial temperature' );

	$sensor->subscribe_mqtt();

	# Test DS18B20 sensor
	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"Time":"2024-01-01T00:00:00","DS18B20":{"Temperature":25.5},"TempUnit":"C"}'
	);
	is( $sensor->{current_temp}, 25.5, '[MQTT-Sensors §2] DS18B20 temperature updated' );
	is( $sensor->{sensor_type}, 'DS18B20', '[MQTT-Sensors §2] sensor type auto-detected' );
}

# Test Sensor with Fahrenheit
{
	my $mqtt = MockMQTT->new();
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid         => 2,
		name        => 'Test Sensor',
		mqtt_topic  => 'sensor',
		mqtt_client => $mqtt,
	);

	$sensor->subscribe_mqtt();

	# Simulate Fahrenheit reading
	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"Time":"2024-01-01T00:00:00","DS18B20":{"Temperature":77},"TempUnit":"F"}'
	);

	# 77F = 25C
	ok( abs( $sensor->{current_temp} - 25 ) < 0.1,
		'[MQTT-Sensors §3] Fahrenheit converted to Celsius' );
}

# Test Sensor with DHT22
{
	my $mqtt = MockMQTT->new();
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid          => 2,
		name         => 'DHT Sensor',
		mqtt_topic   => 'dht',
		mqtt_client  => $mqtt,
		has_humidity => 1,
	);

	$sensor->subscribe_mqtt();

	$mqtt->simulate_message( 'tele/dht/SENSOR',
		'{"DHT22":{"Temperature":22.5,"Humidity":65},"TempUnit":"C"}' );

	is( $sensor->{current_temp},     22.5, '[MQTT-Sensors §4] DHT22 temperature' );
	is( $sensor->{current_humidity}, 65,   '[MQTT-Sensors §4] DHT22 humidity' );
	is( $sensor->{sensor_type}, 'DHT22', '[MQTT-Sensors §2] DHT22 auto-detected' );
}

# Test Sensor with indexed sensors
{
	my $mqtt = MockMQTT->new();
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid          => 2,
		name         => 'Multi Sensor',
		mqtt_topic   => 'multi',
		mqtt_client  => $mqtt,
		sensor_type  => 'DS18B20',
		sensor_index => 2,
	);

	$sensor->subscribe_mqtt();

	$mqtt->simulate_message( 'tele/multi/SENSOR',
		'{"DS18B20-1":{"Temperature":20},"DS18B20-2":{"Temperature":25},"TempUnit":"C"}'
	);

	is( $sensor->{current_temp}, 25, '[MQTT-Sensors §3] indexed sensor DS18B20-2' );
}

# Test Thermostat device
{
	my $mqtt = MockMQTT->new();
	my $thermostat = OpenHAP::Tasmota::Thermostat->new(
		aid         => 2,
		name        => 'Test Thermostat',
		mqtt_topic  => 'thermostat',
		mqtt_client => $mqtt,
	);

	ok( defined $thermostat, 'Thermostat created' );
	is( $thermostat->{current_temp},  20.0, 'Initial current temp' );
	is( $thermostat->{target_temp},   20.0, 'Initial target temp' );
	is( $thermostat->{heating_state}, 0,    'Initial heating state off' );

	$thermostat->subscribe_mqtt();

	# Check Status 10 was queried (recommended per spec)
	my @published = $mqtt->get_published();
	ok( ( grep { $_->{topic} eq 'cmnd/thermostat/Status'
			    && $_->{payload} eq '10' } @published ),
		'[MQTT-Control §5] Status 10 queried on subscribe' );
}

# Test Thermostat temperature updates
{
	my $mqtt = MockMQTT->new();
	my $thermostat = OpenHAP::Tasmota::Thermostat->new(
		aid         => 2,
		name        => 'Test Thermostat',
		mqtt_topic  => 'thermostat',
		mqtt_client => $mqtt,
	);

	$thermostat->subscribe_mqtt();

	# Test SENSOR message
	$mqtt->simulate_message( 'tele/thermostat/SENSOR',
		'{"DS18B20":{"Temperature":22.5},"TempUnit":"C"}' );
	is( $thermostat->{current_temp}, 22.5, '[MQTT-Sensors §1] SENSOR updates temperature' );

	# Test STATUS8 response
	$mqtt->simulate_message( 'stat/thermostat/STATUS8',
		'{"StatusSNS":{"DS18B20":{"Temperature":23},"TempUnit":"C"}}' );
	is( $thermostat->{current_temp}, 23, '[MQTT-Control §5] STATUS8 updates temperature' );
}

# Test Lightbulb device
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'Test Light',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_DIMMER
		    | CAP_COLOR
		    | CAP_CT,
	);

	ok( defined $lightbulb, 'Lightbulb created' );
	is( $lightbulb->{power_state}, 0,   'Initial power off' );
	is( $lightbulb->{brightness},  100, 'Initial brightness 100' );

	$lightbulb->subscribe_mqtt();
}

# Test Lightbulb Dimmer control
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'Test Light',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_DIMMER,
	);

	$lightbulb->subscribe_mqtt();

	# Test brightness control
	$mqtt->clear_published();
	$lightbulb->_set_brightness(75);

	my @published = $mqtt->get_published();
	is( $published[0]{topic},   'cmnd/light/Dimmer', '[MQTT-Control §2] Dimmer topic' );
	is( $published[0]{payload}, '75',                '[MQTT-Control §2] Dimmer value' );

	# Test dimmer step commands
	$mqtt->clear_published();
	$lightbulb->dimmer_step('+');
	@published = $mqtt->get_published();
	is( $published[0]{payload}, '+', '[MQTT-Control §2] Dimmer step +' );

	$mqtt->clear_published();
	$lightbulb->dimmer_step('-');
	@published = $mqtt->get_published();
	is( $published[0]{payload}, '-', '[MQTT-Control §2] Dimmer step -' );

	$mqtt->clear_published();
	$lightbulb->dimmer_min();
	@published = $mqtt->get_published();
	is( $published[0]{payload}, '<', '[MQTT-Control §2] Dimmer min' );

	$mqtt->clear_published();
	$lightbulb->dimmer_max();
	@published = $mqtt->get_published();
	is( $published[0]{payload}, '>', '[MQTT-Control §2] Dimmer max' );
}

# Test Lightbulb Color control
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'Test Light',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_DIMMER
		    | CAP_COLOR,
	);

	$lightbulb->subscribe_mqtt();

	# Test hue control
	$mqtt->clear_published();
	$lightbulb->_set_hue(240);
	my @published = $mqtt->get_published();
	is( $published[0]{topic},   'cmnd/light/HSBColor1', '[MQTT-Control §3.1] Hue topic' );
	is( $published[0]{payload}, '240',                  '[MQTT-Control §3.1] Hue value' );

	# Test saturation control
	$mqtt->clear_published();
	$lightbulb->_set_saturation(80);
	@published = $mqtt->get_published();
	is( $published[0]{topic},   'cmnd/light/HSBColor2', '[MQTT-Control §3.1] Saturation topic' );
	is( $published[0]{payload}, '80',                   '[MQTT-Control §3.1] Saturation value' );

	# Test combined color
	$mqtt->clear_published();
	$lightbulb->set_color( 120, 100, 50 );
	@published = $mqtt->get_published();
	is( $published[0]{topic}, 'cmnd/light/HSBColor', '[MQTT-Control §3.1] HSBColor topic' );
	is( $published[0]{payload}, '120,100,50', '[MQTT-Control §3.1] HSBColor value' );
}

# Test Lightbulb CT control
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'Test Light',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_CT,
	);

	$lightbulb->subscribe_mqtt();

	# Test CT control
	$mqtt->clear_published();
	$lightbulb->_set_ct(300);
	my @published = $mqtt->get_published();
	is( $published[0]{topic},   'cmnd/light/CT', '[MQTT-Control §4] CT topic' );
	is( $published[0]{payload}, '300',           '[MQTT-Control §4] CT value' );

	# Test CT clamping (min)
	$mqtt->clear_published();
	$lightbulb->_set_ct(100);    # Below min 153
	@published = $mqtt->get_published();
	is( $published[0]{payload}, '153', '[MQTT-Control §4] CT clamped to min' );
}

# Test Lightbulb state updates from RESULT
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'Test Light',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_DIMMER
		    | CAP_COLOR
		    | CAP_CT,
	);

	$lightbulb->subscribe_mqtt();

	# Test RESULT with dimmer
	$mqtt->simulate_message( 'stat/light/RESULT', '{"Dimmer":75}' );
	is( $lightbulb->{brightness}, 75, '[MQTT-State §4] RESULT updates brightness' );

	# Test RESULT with HSBColor
	$mqtt->simulate_message( 'stat/light/RESULT',
		'{"HSBColor":"180,50,80"}' );
	is( $lightbulb->{hue},        180, '[MQTT-State §4] RESULT updates hue' );
	is( $lightbulb->{saturation}, 50,  '[MQTT-State §4] RESULT updates saturation' );
	is( $lightbulb->{brightness}, 80,  '[MQTT-State §4] RESULT updates brightness from HSB' );

	# Test RESULT with CT
	$mqtt->simulate_message( 'stat/light/RESULT', '{"CT":250}' );
	is( $lightbulb->{ct}, 250, '[MQTT-State §4] RESULT updates CT' );

	# Test STATE message
	$mqtt->simulate_message( 'tele/light/STATE',
		'{"POWER":"ON","Dimmer":60,"HSBColor":"90,100,60","CT":400}' );
	is( $lightbulb->{power_state}, 1,  '[MQTT-State §3] STATE updates power' );
	is( $lightbulb->{brightness},  60, '[MQTT-State §3] STATE updates brightness' );
}

# ==============================================================================
# New tests for compliance fixes
# ==============================================================================

# Test FullTopic support
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'FullTopic Test',
		mqtt_topic  => 'bedroom_light',
		mqtt_client => $mqtt,
		fulltopic   => 'tasmota/%topic%/%prefix%/',
	);

	# Test custom FullTopic pattern
	is( $base->_build_topic( 'cmnd', 'Power' ),
		'tasmota/bedroom_light/cmnd/Power',
		'[MQTT-Transport §1.2] custom FullTopic builds correctly' );

	is( $base->_build_topic( 'stat', 'RESULT' ),
		'tasmota/bedroom_light/stat/RESULT',
		'[MQTT-Transport §1.2] FullTopic stat topic correct' );

	is( $base->_build_topic( 'tele', 'STATE' ),
		'tasmota/bedroom_light/tele/STATE',
		'[MQTT-Transport §1.2] FullTopic tele topic correct' );
}

# Test default FullTopic
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Default FullTopic',
		mqtt_topic  => 'test_device',
		mqtt_client => $mqtt,
	);

	is( $base->_build_topic( 'cmnd', 'Power' ),
		'cmnd/test_device/Power',
		'[MQTT-Transport §1.2] default FullTopic works' );
}

# Test SetOption26 support
{
	my $mqtt = MockMQTT->new();

	# Without SetOption26
	my $heater1 = OpenHAP::Tasmota::Heater->new(
		aid         => 2,
		name        => 'Normal Heater',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
	);

	is( $heater1->_get_power_key(), 'POWER',
		'[MQTT-Control §1] without SetOption26 uses POWER' );

	# With SetOption26
	my $heater2 = OpenHAP::Tasmota::Heater->new(
		aid         => 3,
		name        => 'SetOption26 Heater',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
		setoption26 => 1,
	);

	is( $heater2->_get_power_key(), 'POWER1',
		'[MQTT-Control §1] with SetOption26 uses POWER1' );
	is( $heater2->_get_power_topic(), 'cmnd/device/Power1',
		'[MQTT-Control §1] SetOption26 power topic correct' );
}

# Test STATUS11 handling
{
	my $mqtt = MockMQTT->new();
	my $heater = OpenHAP::Tasmota::Heater->new(
		aid         => 2,
		name        => 'Status11 Test',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
	);

	$heater->subscribe_mqtt();

	# Check STATUS11 subscription exists
	my @subs = $mqtt->get_subscriptions();
	ok( ( grep { $_ eq 'stat/device/STATUS11' } @subs ),
		'[MQTT-Control §5] Subscribed to STATUS11' );

	# Simulate STATUS11 response
	my $status11 = '{"StatusSTS":{"POWER":"ON","Uptime":"1T00:00:00"}}';
	$mqtt->simulate_message( 'stat/device/STATUS11', $status11 );
	is( $heater->{power_state}, 1, '[MQTT-Control §5] STATUS11 updates power state' );
}

# Test Status 11 query on LWT Online
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Query Test',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
	);

	$base->subscribe_mqtt();
	$mqtt->clear_published();

	# Simulate LWT Online
	$mqtt->simulate_message( 'tele/device/LWT', 'Online' );

	# Verify Status 11 was queried (not Status 0)
	my @published = $mqtt->get_published();
	ok( ( grep { $_->{topic} eq 'cmnd/device/Status'
			    && $_->{payload} eq '11' } @published ),
		'[MQTT-State §5.2] Status 11 queried on Online' );
}

# Test force_telemetry
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'Telemetry Test',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
	);

	$mqtt->clear_published();
	$base->force_telemetry();

	my @published = $mqtt->get_published();
	ok( ( grep { $_->{topic} eq 'cmnd/device/TelePeriod' } @published ),
		'[MQTT-Sensors §5.1] TelePeriod command sent' );
}

# Test SetOption4 topic subscriptions for Lightbulb
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'SetOption4 Light',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_DIMMER | CAP_COLOR | CAP_CT,
	);

	$lightbulb->subscribe_mqtt();

	my @subs = $mqtt->get_subscriptions();

	ok( ( grep { $_ eq 'stat/light/DIMMER' } @subs ),
		'[MQTT-Transport §3.2] SetOption4: subscribed to DIMMER topic' );
	ok( ( grep { $_ eq 'stat/light/HSBCOLOR' } @subs ),
		'[MQTT-Transport §3.2] SetOption4: subscribed to HSBCOLOR topic' );
	ok( ( grep { $_ eq 'stat/light/CT' } @subs ),
		'[MQTT-Transport §3.2] SetOption4: subscribed to CT topic' );
}

# Test SetOption17 decimal color format
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'Color Test',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_COLOR,
	);

	$lightbulb->subscribe_mqtt();

	# Test hex color format (default)
	$mqtt->simulate_message( 'stat/light/RESULT',
		'{"Color":"FF0000"}' );
	is( $lightbulb->{hue}, 0, '[MQTT-Control §3.2] hex color red hue=0' );

	# Test decimal color format (SetOption17 1)
	$mqtt->simulate_message( 'stat/light/RESULT',
		'{"Color":"0,255,0"}' );
	is( $lightbulb->{hue}, 120, '[MQTT-Control §3.2] SetOption17 decimal color green hue=120' );

	# Test blue
	$mqtt->simulate_message( 'stat/light/RESULT',
		'{"Color":"0,0,255"}' );
	is( $lightbulb->{hue}, 240, '[MQTT-Control §3.2] SetOption17 decimal color blue hue=240' );
}

# Test CT range clamping
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'CT Test',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_CT,
	);

	$lightbulb->subscribe_mqtt();

	# Verify HomeKit min is 153 (not 140)
	# The characteristic is defined in new(), check the clamping behavior
	$mqtt->simulate_message( 'stat/light/RESULT', '{"CT":100}' );
	is( $lightbulb->{ct}, 153, '[MQTT-Control §4] CT clamped to min 153' );

	$mqtt->simulate_message( 'stat/light/RESULT', '{"CT":600}' );
	is( $lightbulb->{ct}, 500, '[MQTT-Control §4] CT clamped to max 500' );
}

# Test sensor ID tracking
{
	my $mqtt = MockMQTT->new();
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid         => 2,
		name        => 'ID Sensor',
		mqtt_topic  => 'sensor',
		mqtt_client => $mqtt,
	);

	$sensor->subscribe_mqtt();

	# Simulate SENSOR with ID
	$mqtt->simulate_message( 'tele/sensor/SENSOR',
		'{"DS18B20":{"Id":"01131B123456","Temperature":22.5},"TempUnit":"C"}'
	);

	is( $sensor->{sensor_id}, '01131B123456', '[MQTT-Sensors §3] sensor Id tracked' );
}

# Test STATUS10 subscription for sensors
{
	my $mqtt = MockMQTT->new();
	my $sensor = OpenHAP::Tasmota::Sensor->new(
		aid         => 2,
		name        => 'STATUS10 Test',
		mqtt_topic  => 'sensor',
		mqtt_client => $mqtt,
	);

	$sensor->subscribe_mqtt();

	my @subs = $mqtt->get_subscriptions();
	ok( ( grep { $_ eq 'stat/sensor/STATUS10' } @subs ),
		'[MQTT-Control §5] Subscribed to STATUS10' );

	# Simulate STATUS10 response
	$mqtt->simulate_message( 'stat/sensor/STATUS10',
		'{"StatusSNS":{"DS18B20":{"Temperature":26},"TempUnit":"C"}}' );
	is( $sensor->{current_temp}, 26, '[MQTT-Control §5] STATUS10 updates temperature' );
}

# Test RGB to HSB conversion accuracy
{
	my $mqtt = MockMQTT->new();
	my $lightbulb = OpenHAP::Tasmota::Lightbulb->new(
		aid          => 2,
		name         => 'RGB Test',
		mqtt_topic   => 'light',
		mqtt_client  => $mqtt,
		capabilities => CAP_COLOR,
	);

	# Test pure red
	my ( $h, $s, $b ) = $lightbulb->_rgb_to_hsb( 255, 0, 0 );
	is( $h, 0,   '[MQTT-Control §3.2] RGB red: hue=0' );
	is( $s, 100, 'RGB red: saturation=100' );
	is( $b, 100, 'RGB red: brightness=100' );

	# Test pure green
	( $h, $s, $b ) = $lightbulb->_rgb_to_hsb( 0, 255, 0 );
	is( $h, 120, '[MQTT-Control §3.2] RGB green: hue=120' );

	# Test pure blue
	( $h, $s, $b ) = $lightbulb->_rgb_to_hsb( 0, 0, 255 );
	is( $h, 240, '[MQTT-Control §3.2] RGB blue: hue=240' );

	# Test white (no saturation)
	( $h, $s, $b ) = $lightbulb->_rgb_to_hsb( 255, 255, 255 );
	is( $s, 0,   'RGB white: saturation=0' );
	is( $b, 100, 'RGB white: brightness=100' );

	# Test 50% gray
	( $h, $s, $b ) = $lightbulb->_rgb_to_hsb( 128, 128, 128 );
	is( $s, 0,  'RGB gray: saturation=0' );
	is( $b, 50, 'RGB gray: brightness=50' );
}

# Test FullTopic with multi-relay and SetOption26
{
	my $mqtt = MockMQTT->new();
	my $base = OpenHAP::Tasmota::Base->new(
		aid         => 2,
		name        => 'FullTopic Relay',
		mqtt_topic  => 'device',
		mqtt_client => $mqtt,
		relay_index => 2,
		fulltopic   => 'home/%topic%/%prefix%/',
	);

	is( $base->_get_power_topic(),
		'home/device/cmnd/Power2',
		'FullTopic + relay_index builds correct topic' );
}

done_testing();
