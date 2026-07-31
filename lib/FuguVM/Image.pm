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

package FuguVM::Image;

# FuguVM::Image - Download and cache OpenBSD miniroot images
#
# This module provides access to OpenBSD miniroot images. Images are
# automatically downloaded when needed and stored in the proxy cache for reuse.
# Downloads use the scripts/ftp helper (curl/wget/ftp fallbacks) and files are
# stored via the Proxy::Cache module for consistent caching.

use constant {
	CDN_HOST => 'cdn.openbsd.org',
	ARCH     => 'arm64',
};

sub new ( $class, $cache_dir, $proxy = undef )
{
	# Expand ~ in path
	$cache_dir =~ s/^~/$ENV{HOME}/;

	my $self = bless {
		cache_dir => $cache_dir,
		proxy     => $proxy,
	}, $class;

	return $self;
}

# $self->path($version):
#	Return path to cached miniroot image for given version
#	Returns undef if not cached
sub path ( $self, $version )
{
	my $path = $self->_image_path($version);
	return -f $path ? $path : undef;
}

# $self->ensure($version):
#	Ensure image is available, downloading if necessary
#	Returns path on success, undef on failure
sub ensure ( $self, $version )
{
	# Check if already cached
	my $path = $self->path($version);
	return $path if defined $path;

	# Download via proxy if available
	return $self->download($version);
}

# _ftp_script():
#	Absolute path to the scripts/ftp helper, resolved from this
#	module's own location: lib/FuguVM/Image.pm is two directories
#	below the project root.  Factored out of download so a test can
#	assert the path still resolves - download only warns when it does
#	not, so a rename would otherwise degrade silently to "no download"
#	instead of failing.
sub _ftp_script ()
{
	require File::Basename;
	require File::Spec;

	my $module_dir =
	    File::Basename::dirname( File::Spec->rel2abs(__FILE__) );
	my $project_root =
	    File::Basename::dirname( File::Basename::dirname($module_dir) );

	return File::Spec->catfile( $project_root, 'scripts', 'ftp' );
}

# $self->download($version):
#	Download miniroot image for version via proxy cache
#	Returns path on success, undef on failure
sub download ( $self, $version )
{
	if ( !defined $self->{proxy} ) {
		warn "No proxy available for download\n";
		return;
	}

	my $url = $self->url($version);

	# Download using the scripts/ftp helper (uses curl/wget/ftp)
	# Then store in proxy cache
	require File::Temp;
	my $tmp      = File::Temp->new( SUFFIX => '.img' );
	my $tmp_path = $tmp->filename;

	my $ftp = _ftp_script();

	if ( !-x $ftp ) {
		warn "Cannot find the ftp helper at $ftp\n";
		return;
	}

	# Download to temp file
	my $result = system( $ftp, $tmp_path, $url );
	if ( $result != 0 ) {
		warn "Download failed: exit code $result\n";
		return;
	}

	# Verify file was downloaded
	if ( !-f $tmp_path || -z $tmp_path ) {
		warn "Download succeeded but file is empty\n";
		return;
	}

	# Store in proxy cache
	my $cache       = $self->{proxy}->cache;
	my $cached_path = $cache->store_from_file( $url, $tmp_path );
	if ( !defined $cached_path ) {
		warn "Failed to store in cache\n";
		return;
	}

	return $cached_path;
}

# $self->url($version):
#	Return the CDN URL for a miniroot image
sub url ( $self, $version )
{
	my $filename = $self->_image_filename($version);
	return
	      "https://"
	    . CDN_HOST
	    . "/pub/OpenBSD/$version/"
	    . ARCH
	    . "/$filename";
}

# $self->list:
#	List all cached miniroot images
#	Returns arrayref of { version, filename, path }
sub list ($self)
{
	my @images;
	my $base_path = $self->_proxy_cache_path;

	return \@images if !-d $base_path;

	# Scan for version directories
	opendir my $dh, $base_path or return \@images;
	while ( my $version = readdir $dh ) {
		next if $version =~ /^\./;
		next if !-d "$base_path/$version";

		my $arch_path = "$base_path/$version/" . ARCH;
		next if !-d $arch_path;

		# Look for miniroot images
		opendir my $arch_dh, $arch_path or next;
		while ( my $file = readdir $arch_dh ) {
			if ( $file =~ /^miniroot(\d+)\.img$/ ) {
				push @images,
				    {
					version  => $version,
					filename => $file,
					path     => "$arch_path/$file",
				    };
			}
		}
		closedir $arch_dh;
	}
	closedir $dh;

	# Sort by version descending
	@images = sort { $b->{version} cmp $a->{version} } @images;

	return \@images;
}

# $self->_image_filename($version):
#	Generate miniroot filename for version (e.g., "miniroot78.img")
sub _image_filename ( $self, $version )
{
	( my $ver = $version ) =~ s/\.//g;
	return "miniroot$ver.img";
}

# $self->_image_path($version):
#	Return expected cache path for miniroot image
sub _image_path ( $self, $version )
{
	my $filename = $self->_image_filename($version);
	return $self->_proxy_cache_path . "/$version/" . ARCH . "/$filename";
}

# $self->_proxy_cache_path:
#	Return base path for proxy-cached OpenBSD files
sub _proxy_cache_path ($self)
{
	return "$self->{cache_dir}/proxy/" . CDN_HOST . "/pub/OpenBSD";
}

1;
