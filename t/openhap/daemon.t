#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');
use File::Temp qw(tempdir);

# Test daemon mode functionality. mDNS TXT record content is covered by
# the spec-cited tests in t/conformance/hap-mdns.t.

# Test 1: MQTT connection with timeout
{
	use OpenHAP::MQTT;

	my $mqtt = OpenHAP::MQTT->new(
		host => '127.0.0.1',
		port => 1883,
	);

	# Test timeout parameter exists
	my $start = time;
	my $result = $mqtt->mqtt_connect(2);  # 2 second timeout
	my $elapsed = time - $start;

	# Should fail quickly (within 3 seconds) if MQTT not available
	# or succeed quickly if it is available
	ok($elapsed < 5, 'MQTT connect respects timeout');
}

# Test 2: MQTT reconnection support
{
	use OpenHAP::MQTT;

	my $mqtt = OpenHAP::MQTT->new(
		host => '127.0.0.1',
		port => 1883,
	);

	# Should have reconnect method
	ok($mqtt->can('reconnect'), 'MQTT has reconnect method');
}

# Test 3: HAP has MQTT resubscribe support
{
	use OpenHAP::HAP;

	my $tmpdir = tempdir(CLEANUP => 1);

	my $hap = OpenHAP::HAP->new(
		port         => 51828,  # Different port for testing
		pin          => '123-45-678',
		name         => 'Test Bridge',
		storage_path => $tmpdir,
	);

	# Should have private resubscribe method
	ok($hap->can('_mqtt_resubscribe_accessories'),
	    'HAP has _mqtt_resubscribe_accessories method');
}

done_testing();
