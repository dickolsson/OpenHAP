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

package FuguVM::Proxy::MetaCache;

# The in-memory metadata cache makes file serving faster. It caches
# the file metadata: path, size, mtime, content_type, and etag. This
# prevents repeated stat() calls and repeated content-type detection.

sub new ($class)
{
	bless {
		entries => {},  # URL -> {path, size, mtime, content_type, etag}
	}, $class;
}

# $self->lookup($url):
#	Look up the cached metadata for a URL. The method returns the
#	metadata hashref if the entry is present and still valid, and
#	undef otherwise. It makes sure that the file still exists and
#	did not change.
sub lookup ( $self, $url )
{
	my $entry = $self->{entries}{$url};
	return unless $entry;

	# Make sure that the file still exists and did not change
	my @stat = stat $entry->{path};
	return unless @stat;

	my ( $size, $mtime ) = ( $stat[7], $stat[9] );
	return unless $size == $entry->{size} && $mtime == $entry->{mtime};

	return $entry;
}

# $self->store($url, $path):
#	Store the metadata for a URL. The method stats the file and
#	caches all applicable metadata. It returns the metadata hashref
#	on success and undef on failure.
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
#	Warm the metadata cache with a scan of all cached files. The
#	method takes a FuguVM::Proxy::Cache object.
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
#	Guess the content type from the file extension
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
#	Generate an ETag from the file modification time and size
#	Format: "mtime-size" in hex
sub _generate_etag ( $self, $mtime, $size )
{
	return sprintf( '"%x-%x"', $mtime, $size );
}

# $self->_walk_cache_dir($dir, $cache_dir, $callback):
#	Walk the cache directory recursively. Call the callback for
#	each file. The method reconstructs the URLs from the filesystem
#	paths.
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

			# Reconstruct the URL from the path
			# Path format: $cache_dir/proxy/$host/$path
			my $url = $self->_path_to_url( $path, $cache_dir );
			$callback->( $url, $path ) if defined $url;
		}
	}
}

# $self->_path_to_url($path, $cache_dir):
#	Convert the cache filesystem path back to the URL
sub _path_to_url ( $self, $path, $cache_dir )
{
	my $proxy_dir = "$cache_dir/proxy";
	return unless $path =~ s{^\Q$proxy_dir\E/}{};

	# Split the string into the host and the path
	my ( $host, @parts ) = split m{/}, $path;
	return unless defined $host && @parts;

	my $url_path = join '/', @parts;
	return "http://$host/$url_path";
}

1;
