# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@senzilla.io>
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

package OpenHVF::Proxy::MetaCache;

# In-memory metadata cache for file serving optimization
# Caches file metadata (path, size, mtime, content_type, etag)
# to avoid repeated stat() calls and content-type detection

sub new ($class)
{
	bless {
		entries => {},  # URL -> {path, size, mtime, content_type, etag}
	}, $class;
}

# $self->lookup($url):
#	Lookup cached metadata for a URL
#	Returns metadata hashref if found and still valid, undef otherwise
#	Validates that file still exists and hasn't been modified
sub lookup ( $self, $url )
{
	my $entry = $self->{entries}{$url};
	return unless $entry;

	# Verify file still exists and hasn't been modified
	my @stat = stat $entry->{path};
	return unless @stat;

	my ( $size, $mtime ) = ( $stat[7], $stat[9] );
	return unless $size == $entry->{size} && $mtime == $entry->{mtime};

	return $entry;
}

# $self->store($url, $path):
#	Store metadata for a URL
#	Stats the file and caches all relevant metadata
#	Returns metadata hashref on success, undef on failure
sub store ( $self, $url, $path )
{
	my @stat = stat $path;
	return unless @stat;

	my ( $size, $mtime ) = ( $stat[7], $stat[9] );

	my $entry = {
		path         => $path,
		size         => $size,
		mtime        => $mtime,
		content_type => $self->_guess_content_type($path),
		etag         => $self->_generate_etag( $mtime, $size ),
	};

	$self->{entries}{$url} = $entry;
	return $entry;
}

# $self->remove($url):
#	Remove a URL from the cache
sub remove ( $self, $url )
{
	delete $self->{entries}{$url};
}

# $self->clear:
#	Clear all cached metadata
sub clear ($self)
{
	$self->{entries} = {};
}

# $self->warm($cache):
#	Pre-warm the metadata cache by scanning all cached files
#	Takes an OpenHVF::Proxy::Cache object
sub warm ( $self, $cache )
{
	my $cache_dir = $cache->{cache_dir};
	my $proxy_dir = "$cache_dir/proxy";
	return unless -d $proxy_dir;

	$self->_walk_cache_dir(
		$proxy_dir,
		$cache_dir,
		sub ( $url, $path ) {
			$self->store( $url, $path );
		} );
}

# $self->_guess_content_type($path):
#	Guess content type from file extension
sub _guess_content_type ( $self, $path )
{
	return 'application/x-gzip'       if $path =~ /\.tgz$/;
	return 'application/gzip'         if $path =~ /\.gz$/;
	return 'application/octet-stream' if $path =~ /\.img$/;
	return 'text/plain'               if $path =~ /SHA256(\.sig)?$/;
	return 'text/plain'               if $path =~ /\.txt$/;
	return 'text/plain'               if $path =~ /BUILDINFO$/;
	return 'application/octet-stream' if $path =~ /\/bsd(\.mp|\.rd)?$/;
	return 'application/octet-stream';
}

# $self->_generate_etag($mtime, $size):
#	Generate an ETag from file modification time and size
#	Format: "mtime-size" in hex
sub _generate_etag ( $self, $mtime, $size )
{
	return sprintf( '"%x-%x"', $mtime, $size );
}

# $self->_walk_cache_dir($dir, $cache_dir, $callback):
#	Recursively walk cache directory and invoke callback for each file
#	Reconstructs URLs from filesystem paths
sub _walk_cache_dir ( $self, $dir, $cache_dir, $callback )
{
	opendir my $dh, $dir or return;
	my @entries = readdir $dh;
	closedir $dh;

	for my $entry (@entries) {
		next if $entry eq '.' || $entry eq '..';

		my $path = "$dir/$entry";
		if ( -d $path ) {
			$self->_walk_cache_dir( $path, $cache_dir, $callback );
		}
		elsif ( -f $path ) {

			# Reconstruct URL from path
			# Path format: $cache_dir/proxy/$host/$path
			my $url = $self->_path_to_url( $path, $cache_dir );
			$callback->( $url, $path ) if defined $url;
		}
	}
}

# $self->_path_to_url($path, $cache_dir):
#	Convert cache filesystem path back to URL
sub _path_to_url ( $self, $path, $cache_dir )
{
	my $proxy_dir = "$cache_dir/proxy";
	return unless $path =~ s{^\Q$proxy_dir\E/}{};

	# Split into host and path
	my ( $host, @parts ) = split m{/}, $path;
	return unless defined $host && @parts;

	my $url_path = join '/', @parts;
	return "http://$host/$url_path";
}

1;
