# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2024 Dick Olsson <hi@senzilla.io>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use v5.36;

package OpenHVF::Proxy::Cache;

use File::Basename;
use File::Path qw(make_path);

# Patterns for content that should be cached (OpenBSD-specific)
my @CACHEABLE_PATTERNS = (
	qr{/pub/OpenBSD/\d+\.\d+/\w+/.*\.(tgz|img|gz)$},    # File sets
	qr{/pub/OpenBSD/syspatch/.*\.tgz$},                 # Patches
	qr{/pub/OpenBSD/\d+\.\d+/packages/\w+/.*\.tgz$},    # Packages
	qr{/pub/OpenBSD/\d+\.\d+/\w+/SHA256(\.sig)?$},      # Checksums
	qr{/pub/OpenBSD/\d+\.\d+/\w+/miniroot\d+\.img$},    # Miniroot images
	qr{/pub/OpenBSD/\d+\.\d+/\w+/bsd(\.mp|\.rd)?$},     # Kernel files
	qr{/pub/OpenBSD/\d+\.\d+/\w+/BUILDINFO$},           # Build info
	qr{/pub/OpenBSD/\d+\.\d+/\w+/.*\.txt$},    # Text files (index, etc)
);

sub new ( $class, $cache_dir )
{
	my $self = bless { cache_dir => $cache_dir, }, $class;

	$self->_ensure_dir;

	return $self;
}

sub _ensure_dir ($self)
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	if ( !-d $proxy_dir ) {
		make_path($proxy_dir);
	}
}

# $self->cache_path($url):
#	Convert URL to filesystem cache path
#	Returns undef if URL cannot be converted safely
sub cache_path ( $self, $url )
{
	require URI;
	my $uri = URI->new($url);
	return if !$uri->can('host');

	my $host = $uri->host // return;
	return if $host eq '' || $host =~ m{[/\\]};

	my $path = $uri->path // return;
	$path =~ s|^/||;

	# Security: reject hostile paths outright
	return if $path eq '' || $path =~ /\.\./;

	return "$self->{cache_dir}/proxy/$host/$path";
}

# $self->is_cacheable($url, $status_code):
#	Determine if a URL response should be cached
sub is_cacheable ( $self, $url, $status_code = 200 )
{
	# Only cache successful responses
	return 0 if $status_code != 200;

	# Check against cacheable patterns
	for my $pattern (@CACHEABLE_PATTERNS) {
		return 1 if $url =~ $pattern;
	}

	return 0;
}

# $self->lookup($url):
#	Check if URL is in cache
#	Returns cache file path if found, undef otherwise
sub lookup ( $self, $url )
{
	my $path = $self->cache_path($url);
	return if !defined $path;

	return -f $path ? $path : undef;
}

# $self->store($url, $content):
#	Store content in cache
#	Returns cache file path on success, undef on failure
sub store ( $self, $url, $content )
{
	my $path = $self->cache_path($url);
	return if !defined $path;

	# Create directory structure
	my $dir = dirname($path);
	make_path( $dir, { error => \my $err } );
	if ( $err && @$err ) {
		my ( $file, $msg ) = %{ $err->[0] };
		warn "Cannot create cache directory $dir: $msg\n";
		return;
	}

	# Write to temp file then rename for atomicity
	my $tmp = "$path.tmp.$$";
	open my $fh, '>', $tmp or do {
		warn "Cannot write cache file $tmp: $!";
		return;
	};

	binmode $fh;
	print $fh $content;
	close $fh;

	rename $tmp, $path or do {
		warn "Cannot rename $tmp to $path: $!";
		unlink $tmp;
		return;
	};

	return $path;
}

# $self->store_from_file($url, $source_path):
#	Store content from a file into cache
#	Returns cache file path on success, undef on failure
sub store_from_file ( $self, $url, $source_path )
{
	my $path = $self->cache_path($url);
	return if !defined $path;

	# Create directory structure
	my $dir = dirname($path);
	make_path( $dir, { error => \my $err } );
	if ( $err && @$err ) {
		my ( $file, $msg ) = %{ $err->[0] };
		warn "Cannot create cache directory $dir: $msg\n";
		return;
	}

	# Copy file
	require File::Copy;
	File::Copy::copy( $source_path, $path ) or do {
		warn "Cannot copy $source_path to $path: $!";
		return;
	};

	return $path;
}

# $self->size:
#	Calculate total cache size in bytes
sub size ($self)
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	return 0 if !-d $proxy_dir;

	my $total = 0;
	$self->_walk_dir(
		$proxy_dir,
		sub ($file) {
			$total += -s $file if -f $file;
		} );

	return $total;
}

# $self->clear:
#	Remove all cached files
sub clear ($self)
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	return 1 if !-d $proxy_dir;

	require File::Path;
	File::Path::remove_tree($proxy_dir);
	$self->_ensure_dir;

	return 1;
}

# $self->list:
#	List all cached files
#	Returns arrayref of {url => $url, path => $path, size => $size}
sub list ($self)
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	my @files;

	return \@files if !-d $proxy_dir;

	$self->_walk_dir(
		$proxy_dir,
		sub ($path) {
			return if !-f $path;

			# Reconstruct URL from path
			my $rel = $path;
			$rel =~ s|^\Q$proxy_dir/\E||;

			# First component is host, rest is path
			my ( $host, @rest ) = split '/', $rel;
			my $url_path = join '/', @rest;

			push @files,
			    {
				url  => "http://$host/$url_path",
				path => $path,
				size => -s $path,
			    };
		} );

	return \@files;
}

sub _walk_dir ( $self, $dir, $callback )
{
	opendir my $dh, $dir or return;

	while ( my $entry = readdir $dh ) {
		next if $entry eq '.' || $entry eq '..';

		my $path = "$dir/$entry";
		if ( -d $path ) {
			$self->_walk_dir( $path, $callback );
		}
		else {
			$callback->($path);
		}
	}

	closedir $dh;
}

1;
