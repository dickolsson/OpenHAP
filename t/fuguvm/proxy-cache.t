#!/usr/bin/env perl
# ex:ts=8 sw=4:
# FuguVM::Proxy::Cache pruning: the only thing that bounds the proxy's
# on-disk store of OpenBSD downloads
#
# This file is separate from proxy.t, which skips itself without
# HTTP::Daemon and LWP::UserAgent.  Those are develop dependencies.
# Thus a CI run that installs the test set skips that whole file.
# But this code deletes directories under a user's cache. Every run
# must exercise it, not only the hosts where the VM harness can run.
#
# The tests seed trees directly and not through store().  store()
# uses cache_path(), which wants URI. URI is also develop-only and
# arrives with LWP.  The prune code reads the filesystem layout and
# never a URL. Thus the seam is real and not a workaround.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use_ok('FuguVM::Proxy::Cache');

# _seed($tmpdir, $relative_path, $bytes):
#	Write a cached file of $bytes bytes. Also create its tree.
sub _seed
{
	my ($tmpdir, $rel, $bytes) = @_;
	my $path = "$tmpdir/proxy/$rel";

	$path =~ m{\A(.*)/} and make_path($1);
	open my $fh, '>', $path or die "open $path: $!";
	print $fh 'x' x $bytes;
	close $fh;

	return $path;
}

my $MIRROR = 'cdn.openbsd.org/pub/OpenBSD';

# A version bump left the whole previous version's file sets behind
# permanently. They were unreadable afterwards, because every
# is_cacheable() pattern is version-scoped. Every copy of the
# directory that a CI cache made still carried them.
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	_seed($tmpdir, "$MIRROR/7.8/arm64/base78.tgz", 100);
	_seed($tmpdir, "$MIRROR/7.8/arm64/SHA256", 10);
	_seed($tmpdir, "$MIRROR/7.7/arm64/base77.tgz", 200);
	_seed($tmpdir, "$MIRROR/syspatch/7.7/arm64/001_x.tgz", 50);

	# The path holds no version, so prune must leave it. A cache
	# under $HOME is the wrong place to delete on a guess.
	_seed($tmpdir, 'example.com/loose.txt', 5);

	is($cache->size, 365, 'four versioned files and one loose one');

	my $removed = $cache->prune('7.8');
	is(scalar @$removed, 2, 'both 7.7 trees pruned');

	# Two trees, both 7.7: the release sets and the syspatch sets
	is_deeply([sort map { $_->{version} } @$removed], ['7.7', '7.7'],
	    'each names the version it held');
	is_deeply([sort { $a <=> $b } map { $_->{size} } @$removed],
	    [50, 200], 'and the bytes it freed');

	my @left = sort map { $_->{url} } @{$cache->list};
	is_deeply(\@left,
	    [
		"http://$MIRROR/7.8/arm64/SHA256",
		"http://$MIRROR/7.8/arm64/base78.tgz",
		'http://example.com/loose.txt',
	    ],
	    'the kept version and the unversioned file survive');
	is($cache->size, 115, 'and the freed bytes are gone');

	# The directory itself must be gone, not only its files. The
	# tree is what a CI cache uploads and downloads on every key
	# rotation.
	ok(!-e "$tmpdir/proxy/$MIRROR/7.7",
	    'the pruned release directory is gone');
	ok(!-e "$tmpdir/proxy/$MIRROR/syspatch/7.7",
	    'the pruned syspatch directory is gone');
	ok(-d "$tmpdir/proxy/$MIRROR/7.8",
	    'the kept version directory remains');

	is_deeply($cache->prune('7.8'), [], 'pruning twice removes nothing');
}

# Several versions kept at once, and a host that has nothing under
# pub/OpenBSD at all
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	_seed($tmpdir, "$MIRROR/7.6/arm64/base76.tgz", 10);
	_seed($tmpdir, "$MIRROR/7.7/arm64/base77.tgz", 20);
	_seed($tmpdir, "$MIRROR/7.8/arm64/base78.tgz", 40);
	_seed($tmpdir, 'ftp.example.org/elsewhere/file.tgz', 80);

	my $removed = $cache->prune('7.7', '7.8');
	is_deeply([map { $_->{version} } @$removed], ['7.6'],
	    'only the version named by neither is pruned');
	is($cache->size, 140, 'the other host is untouched');
}

# A prune that keeps only an absent version removes everything present
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	_seed($tmpdir, "$MIRROR/7.7/arm64/base77.tgz", 30);

	is(scalar @{$cache->prune('7.9')}, 1,
	    'an absent version keeps nothing');
	is($cache->size, 0, 'the cache is empty');
}

# The cache never received a write. Thus proxy/ holds no host
# directories at all.
{
	my $tmpdir = tempdir(CLEANUP => 1);
	my $cache = FuguVM::Proxy::Cache->new($tmpdir);

	is_deeply($cache->prune('7.8'), [],
	    'prune on an empty cache is a no-op');
}

done_testing();
