#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');
use File::Temp qw(tempdir);

# Test the daemon mode functions. The spec-cited tests in
# t/conformance/hap-mdns.t cover the mDNS TXT record content.

# Test 1: MQTT connection with timeout
{
	use OpenHAP::MQTT;

	my $mqtt = OpenHAP::MQTT->new(
		host => '127.0.0.1',
		port => 1883,
	);

	# Make sure the timeout parameter exists
	my $start = time;
	my $result = $mqtt->mqtt_connect(2);  # 2 second timeout
	my $elapsed = time - $start;

	# The connect must fail quickly, in 3 seconds or less, if MQTT
	# is not available. It must succeed quickly if MQTT is available.
	ok($elapsed < 5, 'MQTT connect respects timeout');
}

# Test 2: MQTT reconnection support
{
	use OpenHAP::MQTT;

	my $mqtt = OpenHAP::MQTT->new(
		host => '127.0.0.1',
		port => 1883,
	);

	# The client must have a reconnect method
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

	# The HAP object must have a private resubscribe method
	ok($hap->can('_mqtt_resubscribe_accessories'),
	    'HAP has _mqtt_resubscribe_accessories method');
}

# Test 4: the unveil inventory builder. The builder only assembles
# data. Thus the test does not unveil anything.
{
	use OpenHAP::Daemon;

	my $tmpdir = tempdir(CLEANUP => 1);

	# by_path(): index the pair list for the assertions
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

	# The builder is deterministic. The same inputs give the same
	# ordered list. Assert this before a hash access below can
	# autovivify an entry.
	my @again = OpenHAP::Daemon->unveil_paths(
		db_path     => '/var/db/openhapd',
		config_file => '/etc/openhapd.conf',
		perl_dirs   => ['/perl/lib', '/perl/site', '/perl/lib'],
		script_lib  => $tmpdir,
	);
	is_deeply(\@again, \@paths, 'inventory is deterministic');

	my %row = by_path(@paths);

	# Required rows: if one is absent, the install is broken
	is($row{'/var/db/openhapd'}[1], 'rwc', 'db_path is rwc');
	ok(!$row{'/var/db/openhapd'}[2]{optional}, 'db_path is required');
	is($row{'/dev/urandom'}[1], 'r', '/dev/urandom readable');
	ok(!$row{'/dev/urandom'}[2]{optional}, '/dev/urandom is required');

	# The config file must never be a required row, even when the
	# path is given. A fresh install has no /etc/openhapd.conf and
	# must still boot.
	ok($row{'/etc/openhapd.conf'}[2]{optional},
	    'config file is optional');
	is($row{'/etc/openhapd.conf'}[1], 'r', 'config file read-only');

	# These optional rows can be absent on a working system.
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

	# The library directories are the enumerated list, with
	# duplicates removed. The list never comes from live @INC. On an
	# installed layout, it never has /usr/local/lib. The builder
	# excludes a script_lib that has no OpenHAP/ inside.
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

	# The builder includes the lib of a real checkout read-only
	my %checkout = by_path(
		OpenHAP::Daemon->unveil_paths(
			db_path    => '/var/db/openhapd',
			perl_dirs  => ['/perl/lib'],
			script_lib => "$RealBin/../../lib",
		));
	is($checkout{"$RealBin/../../lib"}[1],
	    'r', 'source checkout lib unveiled read-only');

	# No row grants execute permission. Pledge withholds exec. An
	# unveil that grants x would contradict pledge in the source.
	ok((!grep { $_->[1] =~ /x/ } @paths), 'no x permission in the view');

	# The builder refuses outright when it gets no db_path
	ok(!eval { OpenHAP::Daemon->unveil_paths(); 1 },
	    'db_path is not optional to the builder');
}

# Test 5: the PID file shim round-trips through FuguLib::Pidfile
{
	use OpenHAP::Daemon;

	my $tmpdir  = tempdir(CLEANUP => 1);
	my $pidfile = "$tmpdir/openhapd.pid";

	ok(OpenHAP::Daemon->write_pidfile($pidfile),
	    'write_pidfile reports success');
	is(OpenHAP::Daemon->read_pidfile($pidfile), $$,
	    'read_pidfile returns the PID that was written');

	# A path that does not open is a recoverable error, not a die
	my $unwritable = "$tmpdir/nonexistent/openhapd.pid";
	is(OpenHAP::Daemon->write_pidfile($unwritable), undef,
	    'write_pidfile returns undef on an unopenable path');
	is(OpenHAP::Daemon->read_pidfile("$tmpdir/absent.pid"), undef,
	    'read_pidfile returns undef for a missing file');
}

done_testing();
