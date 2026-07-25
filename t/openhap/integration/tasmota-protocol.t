#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: Tasmota MQTT message delivery to the daemon's broker
#
# Simulated device messages are published on the broker and asserted on an
# observer subscription. HAP-side effects of these messages (characteristic
# changes, cmnd/ publishes) require a paired controller and are covered by
# the paired MQTT round-trip tests.

use v5.36;
use Test::More tests => 11;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;

# Test 1: MQTT broker is available
my $mqtt_ok = $env->ensure_mqtt_running;
ok( $mqtt_ok, 'MQTT broker is running' );

die "MQTT broker required for protocol compliance tests\n" unless $mqtt_ok;

my $mqtt = $env->get_mqtt;
ok( defined $mqtt, 'Connected to MQTT broker' );

die "Cannot connect to MQTT broker\n" unless defined $mqtt;

# Get first configured device topic
my @device_topics = $env->get_device_topics;
die "No devices configured for testing\n" unless @device_topics;

my $topic = $device_topics[0];

# wait_for($flag_ref): tick the connection until the flag is set
sub wait_for ($flag_ref)
{
	my $start = time;
	while ( !$$flag_ref && ( time - $start ) < 5 ) {
		$mqtt->tick(0.2);
	}
	return $$flag_ref;
}

# Test 2: LWT message delivery ([MQTT-Transport §1.4], §4.2)
{
	my $lwt_received = 0;
	my $lwt_payload;

	$mqtt->subscribe(
		"tele/$topic/LWT",
		sub( $t, $p, $ = undef ) {
			$lwt_received = 1;
			$lwt_payload  = $p;
		} );

	$mqtt->publish( "tele/$topic/LWT", "Online" );

	ok( wait_for( \$lwt_received ),
		'[MQTT-Transport §1.4] LWT message delivered on tele/+/LWT' );
	is( $lwt_payload, 'Online',
		'[MQTT-Transport §4.2] LWT payload is Online' );
}

# Test 3: tele/STATE periodic update delivery ([MQTT-State §2], §3)
{
	my $state_received = 0;
	my $state_payload;

	$mqtt->subscribe(
		"tele/$topic/STATE",
		sub( $t, $p, $ = undef ) {
			$state_received = 1;
			$state_payload  = $p;
		} );

	my $state_json =
	    '{"Time":"2024-01-01T00:00:00","POWER":"OFF","Dimmer":50}';
	$mqtt->publish( "tele/$topic/STATE", $state_json );

	ok( wait_for( \$state_received ),
		'[MQTT-State §2] STATE message delivered on tele/+/STATE' );
	like( $state_payload, qr/"POWER":"OFF"/,
		'[MQTT-State §3] STATE payload carries POWER field' );
}

# Test 4: stat/RESULT command response delivery ([MQTT-State §4])
{
	my $result_received = 0;

	$mqtt->subscribe(
		"stat/$topic/RESULT",
		sub( $t, $p, $ = undef ) {
			$result_received = 1;
		} );

	$mqtt->publish( "stat/$topic/RESULT", '{"POWER":"ON"}' );

	ok( wait_for( \$result_received ),
		'[MQTT-State §4] RESULT message delivered on stat/+/RESULT' );
}

# Test 5: Multi-relay POWER<n> topics ([MQTT-Control §1])
for my $i ( 1 .. 2 ) {
	my $power_received = 0;

	$mqtt->subscribe(
		"stat/$topic/POWER$i",
		sub( $t, $p, $ = undef ) {
			$power_received = 1;
		} );

	$mqtt->publish( "stat/$topic/POWER$i", "ON" );

	ok( wait_for( \$power_received ),
		"[MQTT-Control §1] POWER$i message delivered" );
}

# Test 6: SENSOR telemetry delivery ([MQTT-Sensors §1])
{
	my $sensor_received = 0;
	my $sensor_payload;

	$mqtt->subscribe(
		"tele/$topic/SENSOR",
		sub( $t, $p, $ = undef ) {
			$sensor_received = 1;
			$sensor_payload  = $p;
		} );

	$mqtt->publish( "tele/$topic/SENSOR",
		'{"DS18B20":{"Temperature":22.5},"TempUnit":"C"}' );

	ok( wait_for( \$sensor_received ),
		'[MQTT-Sensors §1] SENSOR message delivered on tele/+/SENSOR' );
}

# Test 7: OpenHAP daemon still responsive after all MQTT activity
sleep 0.5;
my $response = $env->http_request( 'GET', '/accessories' );
ok( defined $response, 'Daemon responsive after MQTT tests' );

# Clean up
$mqtt->unsubscribe("tele/$topic/LWT");
$mqtt->unsubscribe("tele/$topic/STATE");
$mqtt->unsubscribe("tele/$topic/SENSOR");
$mqtt->unsubscribe("stat/$topic/RESULT");
$mqtt->unsubscribe("stat/$topic/POWER1");
$mqtt->unsubscribe("stat/$topic/POWER2");

$env->teardown;
