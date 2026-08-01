#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: MQTT <-> HAP round trips for Tasmota devices.
# The test publishes each simulated device message on the real
# broker and asserts its effect through the paired HAP data plane.
# The test also covers the opposite direction.

use v5.36;
use Test::More tests => 11;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use JSON::PP qw(decode_json encode_json);
use Time::HiRes qw(sleep time);

my $env = OpenHAP::Test::Integration->new;
$env->setup;
$env->ensure_unpaired or die "Cannot reset pairing state\n";

die "MQTT broker required for protocol tests\n"
    unless $env->ensure_mqtt_running;
my $mqtt = $env->get_mqtt;
die "Cannot connect to MQTT broker\n" unless defined $mqtt;

my ($light)  = grep { $_->{subtype} eq 'lightbulb' } $env->get_devices;
my ($sensor) = grep { $_->{subtype} eq 'sensor' } $env->get_devices;
die "No lightbulb device configured for testing\n" unless $light;
die "No sensor device configured for testing\n"    unless $sensor;

my $controller = $env->get_controller;
$controller->pair_setup
    or die 'pair-setup failed: ' . ( $controller->last_error // '?' ) . "\n";
$controller->pair_verify
    or die 'pair-verify failed: ' . ( $controller->last_error // '?' ) . "\n";

# Locate accessories by their configured names
my $result   = $controller->request('GET', '/accessories');
my $database = decode_json($result->{body});

# find_char($device, $type): (aid, iid) of a characteristic by short
# type on the accessory whose Name matches the device's config name
sub find_char ($device, $type)
{
	for my $accessory (@{ $database->{accessories} }) {
		my $named = 0;
		for my $service (@{ $accessory->{services} }) {
			for my $char (@{ $service->{characteristics} }) {
				$named = 1
				    if $char->{type} eq '23'
				    && ($char->{value} // '') eq
				    $device->{name};
			}
		}
		next unless $named;
		for my $service (@{ $accessory->{services} }) {
			for my $char (@{ $service->{characteristics} }) {
				return ($accessory->{aid}, $char->{iid})
				    if $char->{type} eq $type;
			}
		}
	}
	return;
}

# poll_value($aid, $iid, $expected): poll the paired GET endpoint until
# the value matches (JSON-encoded comparison) or 5 seconds pass
sub poll_value ($aid, $iid, $expected)
{
	my $deadline = time + 5;
	my $seen;
	while (time < $deadline) {
		my $res = $controller->request('GET',
			"/characteristics?id=$aid.$iid");
		my $data = decode_json($res->{body});
		$seen = $data->{characteristics}[0]{value};
		my $normalized =
		    JSON::PP::is_bool($seen) ? ( $seen ? 1 : 0 ) : $seen;
		return $normalized
		    if defined $normalized && "$normalized" eq "$expected";
		sleep 0.25;
	}
	return $seen;
}

my ($light_aid, $on_iid) = find_char($light, '25');
ok(defined $on_iid, 'lightbulb On characteristic located');
my (undef, $brightness_iid) = find_char($light, '8');
ok(defined $brightness_iid, 'lightbulb Brightness characteristic located');
my ($sensor_aid, $temp_iid) = find_char($sensor, '11');
ok(defined $temp_iid, 'sensor CurrentTemperature located');

die "Accessory database missing expected characteristics\n"
    unless defined $on_iid && defined $brightness_iid && defined $temp_iid;

# Test 1: stat/POWER -> HAP On ([MQTT-State §1] -> [MQTT §4])
$mqtt->publish("stat/$light->{topic}/POWER", 'ON');
is(poll_value($light_aid, $on_iid, 1), 1,
   '[MQTT-State §1] published POWER ON visible as HAP On=true');

# Test 2: tele/STATE -> HAP Brightness ([MQTT-State §3])
$mqtt->publish("tele/$light->{topic}/STATE",
	'{"POWER":"ON","Dimmer":42}');
is(poll_value($light_aid, $brightness_iid, 42), 42,
   '[MQTT-State §3] STATE Dimmer visible as HAP Brightness');

# Test 3: tele/SENSOR -> HAP CurrentTemperature ([MQTT-Sensors §1])
$mqtt->publish("tele/$sensor->{topic}/SENSOR",
	'{"DS18B20":{"Temperature":23.5},"TempUnit":"C"}');
is(poll_value($sensor_aid, $temp_iid, 23.5), 23.5,
   '[MQTT-Sensors §1] SENSOR temperature visible via HAP');

# Test 4: Fahrenheit SENSOR converted ([MQTT-Sensors §3])
$mqtt->publish("tele/$sensor->{topic}/SENSOR",
	'{"DS18B20":{"Temperature":77},"TempUnit":"F"}');
is(poll_value($sensor_aid, $temp_iid, 25), 25,
   '[MQTT-Sensors §3] Fahrenheit reading converted to Celsius');

# Test 5: HAP write -> cmnd publish ([MQTT-Control §1])
my $power_cmd;
$mqtt->subscribe("cmnd/$light->{topic}/Power",
	sub ($t, $p, $ = undef) { $power_cmd = $p; });
sleep 0.3;

my $put = $controller->request('PUT', '/characteristics',
	encode_json({ characteristics =>
		[ { aid => $light_aid, iid => $on_iid, value => \0 } ] }),
	{ 'Content-Type' => 'application/hap+json' });
is($put->{status}, 204, 'HAP write accepted');

my $deadline = time + 5;
$mqtt->tick(0.2) while !defined $power_cmd && time < $deadline;
is($power_cmd, 'OFF',
   '[MQTT-Control §1] HAP On=false observed as cmnd Power OFF');

# Test 6: HAP Brightness write -> cmnd Dimmer ([MQTT-Control §2])
my $dimmer_cmd;
$mqtt->subscribe("cmnd/$light->{topic}/Dimmer",
	sub ($t, $p, $ = undef) { $dimmer_cmd = $p; });
sleep 0.3;

$controller->request('PUT', '/characteristics',
	encode_json({ characteristics => [
		{ aid => $light_aid, iid => $brightness_iid, value => 66 }
	] }),
	{ 'Content-Type' => 'application/hap+json' });

$deadline = time + 5;
$mqtt->tick(0.2) while !defined $dimmer_cmd && time < $deadline;
is($dimmer_cmd, '66',
   '[MQTT-Control §2] HAP Brightness observed as cmnd Dimmer');

# Test 7: LWT Online triggers a Status 11 state query
# ([MQTT-Transport §1.4][MQTT-State §5.2])
my $status_cmd;
$mqtt->subscribe("cmnd/$light->{topic}/Status",
	sub ($t, $p, $ = undef) { $status_cmd = $p; });
sleep 0.3;

$mqtt->publish("tele/$light->{topic}/LWT", 'Online');
$deadline = time + 5;
$mqtt->tick(0.2) while !defined $status_cmd && time < $deadline;
is($status_cmd, '11',
   '[MQTT-Transport §1.4] LWT Online answered with Status 11 query');

# Cleanup
$mqtt->unsubscribe("cmnd/$light->{topic}/Power");
$mqtt->unsubscribe("cmnd/$light->{topic}/Dimmer");
$mqtt->unsubscribe("cmnd/$light->{topic}/Status");

$controller->remove_pairing;
$env->teardown;
