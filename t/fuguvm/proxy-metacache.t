#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp;

use_ok('FuguVM::Proxy::MetaCache');

# Test creation
{
	my $cache = FuguVM::Proxy::MetaCache->new;
	ok( defined $cache, 'Created MetaCache' );
	isa_ok( $cache, 'FuguVM::Proxy::MetaCache' );
}

# Test store and lookup
{
	my $cache = FuguVM::Proxy::MetaCache->new;

	# Create a temp file with a .tgz extension
	my $tmp = File::Temp->new( SUFFIX => '.tgz' );
	print $tmp "test content\n";
	$tmp->flush;
	my $path = $tmp->filename;

	my $url  = 'http://example.com/test.tgz';
	my $meta = $cache->store( $url, $path );

	ok( defined $meta,        'Stored metadata' );
	ok( defined $meta->{path},         'Has path' );
	ok( defined $meta->{size},         'Has size' );
	ok( defined $meta->{mtime},        'Has mtime' );
	ok( defined $meta->{content_type}, 'Has content_type' );
	ok( defined $meta->{etag},         'Has etag' );

	is( $meta->{path}, $path, 'Path matches' );
	is( $meta->{content_type}, 'application/x-gzip',
		'Content type detected' );
	like( $meta->{etag}, qr/"[0-9a-f]+-[0-9a-f]+"/,
		'ETag format correct' );

	# Lookup
	my $found = $cache->lookup($url);
	ok( defined $found, 'Found in cache' );
	is( $found->{path}, $path, 'Lookup returns same path' );
}

# Test content type detection
{
	my $cache = FuguVM::Proxy::MetaCache->new;

	is( $cache->_guess_content_type('/path/to/file.tgz'),
		'application/x-gzip', '.tgz detected' );
	is( $cache->_guess_content_type('/path/to/file.gz'),
		'application/gzip', '.gz detected' );
	is( $cache->_guess_content_type('/path/to/file.img'),
		'application/octet-stream', '.img detected' );
	is( $cache->_guess_content_type('/path/to/SHA256'),
		'text/plain', 'SHA256 detected' );
	is( $cache->_guess_content_type('/path/to/SHA256.sig'),
		'text/plain', 'SHA256.sig detected' );
	is( $cache->_guess_content_type('/path/to/index.txt'),
		'text/plain', '.txt detected' );
	is( $cache->_guess_content_type('/path/to/BUILDINFO'),
		'text/plain', 'BUILDINFO detected' );
	is( $cache->_guess_content_type('/path/to/bsd'),
		'application/octet-stream', 'bsd kernel detected' );
	is( $cache->_guess_content_type('/path/to/bsd.mp'),
		'application/octet-stream', 'bsd.mp kernel detected' );
	is( $cache->_guess_content_type('/path/to/bsd.rd'),
		'application/octet-stream', 'bsd.rd kernel detected' );
}

# Test ETag generation
{
	my $cache = FuguVM::Proxy::MetaCache->new;

	my $etag1 = $cache->_generate_etag( 1234567890, 1024 );
	like( $etag1, qr/"[0-9a-f]+-[0-9a-f]+"/,
		'ETag format correct' );

	my $etag2 = $cache->_generate_etag( 1234567890, 1024 );
	is( $etag1, $etag2, 'Same mtime/size produces same ETag' );

	my $etag3 = $cache->_generate_etag( 1234567891, 1024 );
	isnt( $etag1, $etag3, 'Different mtime produces different ETag' );
}

# Test cache invalidation
{
	my $cache = FuguVM::Proxy::MetaCache->new;

	# Create and store a temp file
	my $tmp = File::Temp->new;
	print $tmp "test content\n";
	$tmp->flush;
	my $path = $tmp->filename;

	my $url = 'http://example.com/test.tgz';
	$cache->store( $url, $path );

	ok( defined $cache->lookup($url), 'Found after store' );

	# Modify the file
	sleep 1;    # Make sure that the mtime changes
	open my $fh, '>>', $path or die "Cannot append: $!";
	print $fh "more content\n";
	close $fh;

	# The lookup must miss because the mtime and size changed
	ok( !defined $cache->lookup($url),
		'Invalidated after file modification' );
}

# Test remove
{
	my $cache = FuguVM::Proxy::MetaCache->new;

	my $tmp = File::Temp->new;
	print $tmp "test content\n";
	$tmp->flush;
	my $path = $tmp->filename;

	my $url = 'http://example.com/test.tgz';
	$cache->store( $url, $path );

	ok( defined $cache->lookup($url), 'Found after store' );

	$cache->remove($url);
	ok( !defined $cache->lookup($url), 'Not found after remove' );
}

# Test clear
{
	my $cache = FuguVM::Proxy::MetaCache->new;

	my $tmp1 = File::Temp->new;
	print $tmp1 "test1\n";
	$tmp1->flush;
	my $tmp2 = File::Temp->new;
	print $tmp2 "test2\n";
	$tmp2->flush;

	$cache->store( 'http://example.com/file1.tgz', $tmp1->filename );
	$cache->store( 'http://example.com/file2.tgz', $tmp2->filename );

	ok( defined $cache->lookup('http://example.com/file1.tgz'),
		'File1 found' );
	ok( defined $cache->lookup('http://example.com/file2.tgz'),
		'File2 found' );

	$cache->clear;

	ok( !defined $cache->lookup('http://example.com/file1.tgz'),
		'File1 cleared' );
	ok( !defined $cache->lookup('http://example.com/file2.tgz'),
		'File2 cleared' );
}

done_testing();
