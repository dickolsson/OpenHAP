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

package FuguVM::Proxy::Cache;

use File::Basename;
use File::Path qw(make_path);

# The patterns match the content to cache. They are OpenBSD-specific.
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
#	Convert the URL to a filesystem cache path. The method returns
#	undef if it cannot convert the URL safely.
sub cache_path ( $self, $url )
{
	require URI;
	my $uri = URI->new($url);
	return if !$uri->can('host');

	my $host = $uri->host // return;
	return if $host eq '' || $host =~ m{[/\\]};

	my $path = $uri->path // return;
	$path =~ s|^/||;

	# Security: reject hostile paths before any use
	return if $path eq '' || $path =~ /\.\./;

	return "$self->{cache_dir}/proxy/$host/$path";
}

# $self->is_cacheable($url, $status_code):
#	Check if a URL response is cacheable
sub is_cacheable ( $self, $url, $status_code = 200 )
{
	# Cache only successful responses
	return 0 if $status_code != 200;

	# Check the URL against the cacheable patterns
	for my $pattern (@CACHEABLE_PATTERNS) {
		return 1 if $url =~ $pattern;
	}

	return 0;
}

# $self->lookup($url):
#	Check if the URL is in the cache. The method returns the cache
#	file path if the file exists and undef otherwise.
sub lookup ( $self, $url )
{
	my $path = $self->cache_path($url);
	return if !defined $path;

	return -f $path ? $path : undef;
}

# $self->store($url, $content):
#	Store the content in the cache. The method returns the cache
#	file path on success and undef on failure.
sub store ( $self, $url, $content )
{
	my $path = $self->cache_path($url);
	return if !defined $path;

	# Create the directory structure
	my $dir = dirname($path);
	make_path( $dir, { error => \my $err } );
	if ( $err && @$err ) {
		my ( $file, $msg ) = %{ $err->[0] };
		warn "Cannot create cache directory $dir: $msg\n";
		return;
	}

	# Write to a temp file. Then rename the file to make the store
	# atomic.
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
#	Store the content of a file into the cache. The method returns
#	the cache file path on success and undef on failure.
sub store_from_file ( $self, $url, $source_path )
{
	my $path = $self->cache_path($url);
	return if !defined $path;

	# Create the directory structure
	my $dir = dirname($path);
	make_path( $dir, { error => \my $err } );
	if ( $err && @$err ) {
		my ( $file, $msg ) = %{ $err->[0] };
		warn "Cannot create cache directory $dir: $msg\n";
		return;
	}

	# Copy the file
	require File::Copy;
	File::Copy::copy( $source_path, $path ) or do {
		warn "Cannot copy $source_path to $path: $!";
		return;
	};

	return $path;
}

# $self->size:
#	Calculate the total cache size in bytes
sub size ($self)
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	return 0 if !-d $proxy_dir;

	return $self->_dir_size($proxy_dir);
}

# $self->prune(@keep):
#	Remove the cached download tree of every OpenBSD version other
#	than @keep. The method returns [ { version, path, size } ] for
#	each removed tree.
#
#	Nothing else bounds this cache. 'fuguvm cache clear --stale'
#	prunes installed images. Those images live beside these
#	downloads under the same cache_dir, but no common key connects
#	them. Thus a version bump left the full file sets of the
#	previous version here for good. Nothing read them again,
#	because every pattern that is_cacheable() admits is
#	version-scoped. And every copy of the directory that a
#	continuous-integration cache made still carried them.
#
#	The method removes whole directories, not matching files.
#	Removal of the files alone leaves the empty version tree
#	behind, and such a copy walks the tree.
#
#	The method does not touch a directory whose name is not a
#	version. In practice there are none. The patterns put
#	everything under pub/OpenBSD/<version>/ or
#	pub/OpenBSD/syspatch/<version>/. And a cache under $HOME is the
#	wrong place to delete on a guess.
sub prune ( $self, @keep )
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	return [] if !-d $proxy_dir;

	my %keep = map { $_ => 1 } @keep;
	my @removed;

	for my $root ( $self->_version_roots($proxy_dir) ) {
		opendir my $dh, $root or next;
		my @versions =
		    sort grep { /\A[0-9]+\.[0-9]+\z/ } readdir $dh;
		closedir $dh;

		for my $version (@versions) {
			next if $keep{$version};

			my $dir = "$root/$version";
			next if !-d $dir;

			# Measure the size before removal. Thus the caller
			# can say what the prune freed.
			my $size = $self->_dir_size($dir);

			require File::Path;
			File::Path::remove_tree( $dir, { error => \my $err } );
			if ( $err && @$err ) {
				my ( $file, $msg ) = %{ $err->[0] };
				warn "Cannot remove $dir: $msg\n";
				next;
			}

			push @removed,
			    {
				version => $version,
				path    => $dir,
				size    => $size,
			    };
		}
	}

	return \@removed;
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
#	List all cached files. The method returns an arrayref of
#	{url => $url, path => $path, size => $size}.
sub list ($self)
{
	my $proxy_dir = "$self->{cache_dir}/proxy";
	my @files;

	return \@files if !-d $proxy_dir;

	$self->_walk_dir(
		$proxy_dir,
		sub ($path) {
			return if !-f $path;

			# Reconstruct the URL from the path
			my $rel = $path;
			$rel =~ s|^\Q$proxy_dir/\E||;

			# The first component is the host. The rest is
			# the path.
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

# $self->_version_roots($proxy_dir):
#	Get every directory under $proxy_dir whose immediate children
#	are OpenBSD version numbers, across all cached hosts. Release
#	trees hang off pub/OpenBSD. Syspatch sets sit one level deeper.
#	Both have the name of a version, and neither outlives it.
sub _version_roots ( $self, $proxy_dir )
{
	opendir my $dh, $proxy_dir or return ();
	my @hosts = sort grep { !/\A\.\.?\z/ } readdir $dh;
	closedir $dh;

	my @roots;
	for my $host (@hosts) {
		my $release = "$proxy_dir/$host/pub/OpenBSD";
		next if !-d $release;

		push @roots, $release;
		push @roots, "$release/syspatch" if -d "$release/syspatch";
	}

	return @roots;
}

# $self->_dir_size($dir):
#	Get the total bytes of the regular files under $dir.
sub _dir_size ( $self, $dir )
{
	my $total = 0;
	$self->_walk_dir(
		$dir,
		sub ($file) {
			$total += -s $file if -f $file;
		} );

	return $total;
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
