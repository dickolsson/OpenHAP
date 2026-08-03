#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: System prerequisites and environment validation

use v5.36;
use Test::More tests => 11;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;

# Test 1: Environment variable set
ok($ENV{OPENHAP_INTEGRATION_TEST}, 'OPENHAP_INTEGRATION_TEST is set');

# Test 2: rcctl available
ok(-x '/usr/sbin/rcctl', 'rcctl command available');

# Test 3: openhapd binary installed
ok(-x '/usr/local/bin/openhapd', 'openhapd binary installed');

# Test 4: hapctl binary installed
ok(-x '/usr/local/bin/hapctl', 'hapctl binary installed');

# Test 5: OpenHAP modules available
eval { require OpenHAP::HAP; };
ok(!$@, 'OpenHAP::HAP module available');

# Test 6: Configuration file exists
my $config_file = '/etc/openhapd.conf';
ok(-f $config_file, 'configuration file exists');

# Test 7: Configuration file readable
ok(-r $config_file, 'configuration file readable');

# Test 8: System user exists
my $user_exists = system('id _openhap >/dev/null 2>&1') == 0;
ok($user_exists, '_openhap system user exists');

# Test 9: Data directory exists
ok(-d '/var/db/openhapd', 'data directory exists');

# Test 10: rc.d script installed
ok(-f '/etc/rc.d/openhapd', 'rc.d script installed');

# Test 11: SRP obtains the GMP Math::BigInt backend. The try => 'GMP'
# selection falls back silently to pure Perl. The pure Perl path
# reintroduces multi-minute pair-setups under TCG emulation. A
# missing backend must be a hard, visible failure here, not a
# slow-but-green run.
require Protocol::HAP::SRP;
is(Math::BigInt->config->{lib}, 'Math::BigInt::GMP',
   'Math::BigInt uses the GMP backend');
