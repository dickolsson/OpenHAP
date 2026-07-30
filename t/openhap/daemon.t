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

# Test 4: the unveil inventory builder - pure assembly, testable
# without unveiling anything
{
	use OpenHAP::Daemon;

	my $tmpdir = tempdir(CLEANUP => 1);

	# by_path(): index the pair list for assertions
	sub by_path (@paths)
	{
		return map { $_->[0] => $_ } @paths;
	}

	my @paths = OpenHAP::Daemon->unveil_paths(
		db_path     => '/var/db/openhapd',
		config_file => '/etc/openhapd.conf',
		perl_dirs   => ['/perl/lib', '/perl/site', '/perl/lib'],
		script_lib  => $tmpdir,    # no OpenHAP/ inside: not a checkout
	);

	# Deterministic: same inputs, same ordered list (asserted before
	# any hash access below can autovivify entries)
	my @again = OpenHAP::Daemon->unveil_paths(
		db_path     => '/var/db/openhapd',
		config_file => '/etc/openhapd.conf',
		perl_dirs   => ['/perl/lib', '/perl/site', '/perl/lib'],
		script_lib  => $tmpdir,
	);
	is_deeply(\@again, \@paths, 'inventory is deterministic');

	my %row = by_path(@paths);

	# Required rows: absent means a broken install
	is($row{'/var/db/openhapd'}[1], 'rwc', 'db_path is rwc');
	ok(!$row{'/var/db/openhapd'}[2]{optional}, 'db_path is required');
	is($row{'/dev/urandom'}[1], 'r', '/dev/urandom readable');
	ok(!$row{'/dev/urandom'}[2]{optional}, '/dev/urandom is required');

	# The config file must never be a required row, even though the
	# path was given: a fresh install has no /etc/openhapd.conf and
	# must still boot
	ok($row{'/etc/openhapd.conf'}[2]{optional},
	    'config file is optional');
	is($row{'/etc/openhapd.conf'}[1], 'r', 'config file read-only');

	# Optional rows that are legitimately absent on a working system
	for my $optional (
		'/var/log/openhapd.log', '/var/run/mdnsd.sock',
		'/etc/resolv.conf',      '/etc/hosts',
		'/etc/services',         '/etc/protocols',
		'/etc/localtime',
	    )
	{
		ok($row{$optional}[2]{optional}, "$optional is optional");
	}
	is($row{'/var/run/mdnsd.sock'}[1], 'rw',
	    'mdnsd socket read-write for the update_txt reconnect');

	# The library directories are the enumerated list, deduped -
	# never live @INC, and never /usr/local/lib on an installed
	# layout (script_lib without OpenHAP/ inside is excluded)
	my @lib_rows = grep { $_->[0] =~ m{^/perl/} } @paths;
	is_deeply(
		[map { $_->[0] } @lib_rows],
		['/perl/lib', '/perl/site'],
		'perl dirs enumerated and deduped'
	);
	ok(!exists $row{$tmpdir}, 'non-checkout script_lib excluded');
	ok(!exists $row{'/usr/local/lib'}, '/usr/local/lib not in the view');
	ok((!grep { $_->[2]{optional} } @lib_rows),
	    'library directories are required');

	# A real checkout's lib is included read-only
	my %checkout = by_path(
		OpenHAP::Daemon->unveil_paths(
			db_path    => '/var/db/openhapd',
			perl_dirs  => ['/perl/lib'],
			script_lib => "$RealBin/../../lib",
		));
	is($checkout{"$RealBin/../../lib"}[1],
	    'r', 'source checkout lib unveiled read-only');

	# No execute permission anywhere: pledge withholds exec, and an
	# unveil that grants x would contradict it in the source
	ok((!grep { $_->[1] =~ /x/ } @paths), 'no x permission in the view');

	# Without db_path the builder refuses outright
	ok(!eval { OpenHAP::Daemon->unveil_paths(); 1 },
	    'db_path is not optional to the builder');
}

done_testing();
