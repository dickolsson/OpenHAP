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

	return $self->_dir_size($proxy_dir);
}

# $self->prune(@keep):
#	Remove the cached download tree of every OpenBSD version other
#	than @keep. Returns [ { version, path, size } ] for what went.
#
#	Nothing else bounds this cache. 'fuguvm cache clear --stale'
#	prunes installed images, which live beside these downloads under
#	the same cache_dir but are keyed by nothing in common, so a
#	version bump used to leave the whole previous version's file sets
#	here for good - unreadable afterwards, since every pattern
#	is_cacheable() admits is version-scoped, and still carried by
#	every copy of the directory a continuous-integration cache makes.
#
#	Whole directories, not matching files: removing the files alone
#	would leave the empty version tree behind, and the tree is what
#	such a copy walks.
#
#	A directory whose name is not a version is left alone. In
#	practice there are none - the patterns put everything under
#	pub/OpenBSD/<version>/ or pub/OpenBSD/syspatch/<version>/ - and a
#	cache under $HOME is the wrong place to delete on a guess.
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

			# Measured before removal, so the caller can say
			# what the prune bought
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

# $self->_version_roots($proxy_dir):
#	Every directory under $proxy_dir whose immediate children are
#	OpenBSD version numbers, across all cached hosts. Release trees
#	hang off pub/OpenBSD, syspatch sets one level deeper; both are
#	named for a version and neither outlives it.
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
#	Total bytes of the regular files under $dir.
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
