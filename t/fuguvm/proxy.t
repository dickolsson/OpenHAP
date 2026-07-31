#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);

# Check dependencies
BEGIN {
	eval { require HTTP::Daemon };
	plan skip_all => 'HTTP::Daemon not available' if $@;

	eval { require LWP::UserAgent };
	plan skip_all => 'LWP::UserAgent not available' if $@;
}

use_ok('FuguVM::State');
use_ok('FuguVM::Proxy');
use_ok('FuguVM::Proxy::Cache');

# Test cache path derivation
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	my $path = $cache->cache_path(
	    'http://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/base78.tgz');
	is($path,
	    "$tmpdir/proxy/cdn.openbsd.org/pub/OpenBSD/7.8/arm64/base78.tgz",
	    'Cache path derived correctly');

	# Test directory traversal is completely rejected (returns undef)
	my $bad_path = $cache->cache_path(
	    'http://cdn.openbsd.org/../../../etc/passwd');
	is($bad_path, undef, 'Directory traversal rejected');

	# Test various traversal patterns are rejected
	is($cache->cache_path('http://example.com/foo/../bar'), undef,
	    'Mid-path traversal rejected');
	is($cache->cache_path('http://example.com/..'), undef,
	    'Parent dir traversal rejected');
	is($cache->cache_path('http://example.com/foo/..'), undef,
	    'Trailing parent dir traversal rejected');
}

# Test is_cacheable patterns
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	# Should be cacheable
	ok($cache->is_cacheable(
	    'http://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/base78.tgz'),
	    'File set is cacheable');
	ok($cache->is_cacheable(
	    'http://cdn.openbsd.org/pub/OpenBSD/7.8/packages/amd64/vim-9.0.tgz'),
	    'Package is cacheable');
	ok($cache->is_cacheable(
	    'http://cdn.openbsd.org/pub/OpenBSD/syspatch/7.8/amd64/syspatch78-001.tgz'),
	    'Syspatch is cacheable');
	ok($cache->is_cacheable(
	    'http://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/SHA256'),
	    'SHA256 is cacheable');
	ok($cache->is_cacheable(
	    'http://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/SHA256.sig'),
	    'SHA256.sig is cacheable');

	# Should not be cacheable
	ok(!$cache->is_cacheable('http://example.com/random.html'),
	    'Random HTML is not cacheable');
	ok(!$cache->is_cacheable(
	    'http://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/base78.tgz', 404),
	    '404 response is not cacheable');
}

# Test cache store and lookup
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	my $url = 'http://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/SHA256';
	my $content = "SHA256 (base78.tgz) = abc123\n";

	# Initially not in cache
	is($cache->lookup($url), undef, 'URL not in cache initially');

	# Store content
	my $stored_path = $cache->store($url, $content);
	ok(defined $stored_path, 'Content stored');
	ok(-f $stored_path, 'Cache file exists');

	# Lookup should now succeed
	my $cached_path = $cache->lookup($url);
	is($cached_path, $stored_path, 'Lookup returns stored path');

	# Verify content
	open my $fh, '<', $cached_path;
	my $read_content = do { local $/; <$fh> };
	close $fh;
	is($read_content, $content, 'Cached content matches');
}

# Test cache size calculation
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	is($cache->size, 0, 'Empty cache has size 0');

	# Add some content
	$cache->store('http://example.com/file1.txt', 'x' x 100);
	$cache->store('http://example.com/file2.txt', 'y' x 200);

	is($cache->size, 300, 'Cache size calculated correctly');
}

# Test cache list
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	$cache->store('http://cdn.openbsd.org/pub/OpenBSD/7.8/SHA256', 'content1');
	$cache->store('http://cdn.openbsd.org/pub/OpenBSD/7.8/base78.tgz', 'content2');

	my $files = $cache->list;
	is(scalar @$files, 2, 'List returns correct count');

	my @urls = sort map { $_->{url} } @$files;
	is($urls[0], 'http://cdn.openbsd.org/pub/OpenBSD/7.8/SHA256',
	    'First URL correct');
	is($urls[1], 'http://cdn.openbsd.org/pub/OpenBSD/7.8/base78.tgz',
	    'Second URL correct');
}

# Test cache clear
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	$cache->store('http://example.com/file.txt', 'content');
	ok($cache->size > 0, 'Cache has content');

	$cache->clear;
	is($cache->size, 0, 'Cache cleared');
	is(scalar @{$cache->list}, 0, 'No files after clear');
}

# Test Proxy creation
{
	my $state_dir = tempdir(CLEANUP => 1);
	my $cache_dir = tempdir(CLEANUP => 1);
	my $state = FuguVM::State->new($state_dir, 'test');

	my $proxy = FuguVM::Proxy->new($state, $cache_dir);
	ok(defined $proxy, 'Proxy object created');
	ok(!$proxy->is_running, 'Proxy not running initially');
	is($proxy->port, undef, 'No port initially');
	is($proxy->guest_url, undef, 'No guest_url initially');
}

# Test Proxy port finding
{
	my $state_dir = tempdir(CLEANUP => 1);
	my $cache_dir = tempdir(CLEANUP => 1);
	my $state = FuguVM::State->new($state_dir, 'test');

	my $proxy = FuguVM::Proxy->new($state, $cache_dir);
	my $port = $proxy->_find_available_port;

	ok(defined $port, 'Found available port');
	ok($port >= 8080 && $port <= 8180, 'Port in expected range');
}

# Test Proxy URL generation
{
	my $state_dir = tempdir(CLEANUP => 1);
	my $cache_dir = tempdir(CLEANUP => 1);
	my $state = FuguVM::State->new($state_dir, 'test');

	# Manually set port to test URL generation
	$state->set_proxy_port(8080);

	my $proxy = FuguVM::Proxy->new($state, $cache_dir);
	my $url = $proxy->guest_url;

	is($url, 'http://10.0.2.2:8080', 'Proxy guest_url correct');
}

# Test Proxy start/stop (integration test - may be slow)
SKIP: {
	skip 'Set FUGUVM_TEST_PROXY=1 to run proxy integration tests', 4
	    unless $ENV{FUGUVM_TEST_PROXY};

	my $state_dir = tempdir(CLEANUP => 1);
	my $cache_dir = tempdir(CLEANUP => 1);
	my $state = FuguVM::State->new($state_dir, 'test');

	my $proxy = FuguVM::Proxy->new($state, $cache_dir);

	my $port = $proxy->start;
	ok(defined $port, 'Proxy started');
	ok($proxy->is_running, 'Proxy is running');
	ok(defined $proxy->port, 'Port is set');

	$proxy->stop;
	ok(!$proxy->is_running, 'Proxy stopped');
}

done_testing();
