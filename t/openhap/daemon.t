#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');
use File::Temp qw(tempdir);

# Test daemon mode functionality

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

# Test 4: HAP get_mdns_txt_records returns correct structure
{
	use OpenHAP::HAP;

	my $tmpdir = tempdir(CLEANUP => 1);

	my $hap = OpenHAP::HAP->new(
		port         => 51829,
		pin          => '123-45-678',
		name         => 'Test MDNS Bridge',
		storage_path => $tmpdir,
	);

	my $txt = $hap->get_mdns_txt_records();

	# Verify structure
	ok(defined $txt, 'get_mdns_txt_records returns defined value');
	is(ref $txt, 'HASH', 'Returns a hash reference');

	# Verify required HAP fields exist
	ok(exists $txt->{'c#'}, "[HAP-mDNS §2] contains 'c#' (config number)");
	ok(exists $txt->{'ff'}, "[HAP-mDNS §2] contains 'ff' (feature flags)");
	ok(exists $txt->{'id'}, "[HAP-mDNS §2] contains 'id' (device ID)");
	ok(exists $txt->{'md'}, "[HAP-mDNS §2] contains 'md' (model name)");
	ok(exists $txt->{'pv'}, "[HAP-mDNS §2] contains 'pv' (protocol version)");
	ok(exists $txt->{'s#'}, "[HAP-mDNS §2] contains 's#' (state number)");
	ok(exists $txt->{'sf'}, "[HAP-mDNS §2] contains 'sf' (status flags)");
	ok(exists $txt->{'ci'}, "[HAP-mDNS §2] contains 'ci' (category identifier)");

	# Verify values
	is($txt->{'ff'}, 0, '[HAP-mDNS §3.2] feature flags is 0');
	is($txt->{'pv'}, '1', '[HAP-mDNS §3.5] protocol version is 1');
	is($txt->{'s#'}, 1, '[HAP-mDNS §3.6] state number is 1');
	is($txt->{'ci'}, 2, '[HAP-mDNS §3.8] category identifier is 2 (bridge)');
	is($txt->{'md'}, 'Test MDNS Bridge',
		'[HAP-mDNS §3.4] model name matches HAP name');
	ok($txt->{'sf'} == 0 || $txt->{'sf'} == 1,
		'[HAP-mDNS §3.7] status flags is 0 (paired) or 1 (unpaired)');
	# Check device ID format (XX:XX:XX:XX:XX:XX)
	ok($txt->{'id'} =~ /^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/,
		'[HAP-mDNS §3.3] device ID is in uppercase XX:XX:XX:XX:XX:XX format');
	# Verify device ID is specifically uppercase (not lowercase)
	ok($txt->{'id'} !~ /[a-f]/,
		'[HAP-mDNS §3.3] device ID contains no lowercase hex characters');
}

# Test 5: Setup hash in mDNS TXT records
{
	use OpenHAP::HAP;

	my $tmpdir = tempdir(CLEANUP => 1);

	# Create HAP with setup_id
	my $hap = OpenHAP::HAP->new(
		port         => 51831,
		pin          => '123-45-678',
		name         => 'Setup Hash Test',
		storage_path => $tmpdir,
		setup_id     => 'XYZQ',  # 4-character setup ID
	);

	my $txt = $hap->get_mdns_txt_records();

	# Verify setup hash exists when setup_id is provided
	ok(exists $txt->{'sh'},
		"[HAP-mDNS §3.9] contains 'sh' (setup hash) when setup_id provided");
	# Setup hash should be 4 bytes base64 encoded = ~6 characters
	ok(length($txt->{'sh'}) >= 4 && length($txt->{'sh'}) <= 8,
		'[HAP-mDNS §3.9] setup hash length matches base64-encoded 4 bytes');
}

# Test 6: No setup hash without setup_id
{
	use OpenHAP::HAP;

	my $tmpdir = tempdir(CLEANUP => 1);

	# Create HAP without setup_id
	my $hap = OpenHAP::HAP->new(
		port         => 51832,
		pin          => '123-45-678',
		name         => 'No Setup ID Test',
		storage_path => $tmpdir,
		# no setup_id
	);

	my $txt = $hap->get_mdns_txt_records();

	# Verify setup hash is NOT present without setup_id
	ok(!exists $txt->{'sh'} || !defined $txt->{'sh'},
		"No 'sh' (setup hash) when setup_id not provided");
}

# Test 7: Status flag changes with pairing state
{
	use OpenHAP::HAP;
	use OpenHAP::Storage;

	my $tmpdir = tempdir(CLEANUP => 1);

	my $hap = OpenHAP::HAP->new(
		port         => 51830,
		pin          => '123-45-678',
		name         => 'Pairing Test',
		storage_path => $tmpdir,
	);

	# Unpaired state
	my $txt_unpaired = $hap->get_mdns_txt_records();
	is($txt_unpaired->{'sf'}, 1,
		'[HAP-mDNS §3.7] status flag is 1 when unpaired');

	# Add a pairing using Storage directly
	my $storage = OpenHAP::Storage->new(db_path => $tmpdir);
	my $dummy_ltpk = chr(0) x 32;  # 32 zero bytes
	$storage->save_pairing('test-controller', $dummy_ltpk, 1);

	# Check status flag after pairing
	my $txt_paired = $hap->get_mdns_txt_records();
	is($txt_paired->{'sf'}, 0,
		'[HAP-mDNS §3.7] status flag is 0 when paired');
}

done_testing();
