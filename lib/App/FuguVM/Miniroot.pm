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

package App::FuguVM::Miniroot;

use Fugu::File;
use Fugu::Log;
use Fugu::Process;

# App::FuguVM::Miniroot - the OpenBSD miniroot install media.
#
# The miniroot is what the installer boots from. This module downloads
# it when necessary and keeps it in the proxy cache for reuse. The
# download uses the scripts/ftp helper, which falls back through curl,
# wget, and ftp.
#
# The module caches the install media. App::FuguVM::DiskCache caches
# the disk that the installer produced. Neither is a cache of the
# other.

use constant {
	CDN_HOST => 'cdn.openbsd.org',
	ARCH     => 'arm64',
};

sub new ( $class, $cache_dir, $proxy = undef )
{
	my $self = bless {
		cache_dir => Fugu::File->expand_tilde($cache_dir),
		proxy     => $proxy,
	}, $class;

	return $self;
}

# $self->path($version):
#	Return the path to the cached miniroot image for the given
#	version. Return undef if the image is not cached.
sub path ( $self, $version )
{
	my $path = $self->_image_path($version);
	return -f $path ? $path : undef;
}

# $self->ensure($version):
#	Make sure that the image is available. Download it if
#	necessary. Return the path on success, or undef on failure.
sub ensure ( $self, $version )
{
	# Check if the image is already cached
	my $path = $self->path($version);
	return $path if defined $path;

	# Download through the proxy if one is available
	return $self->download($version);
}

# _ftp_script():
#	Return the absolute path to the scripts/ftp helper.
#	Fugu::File->share_path resolves it, and it derives the root of
#	the tree from its own location, not from this module. Thus a
#	move of this file does not move the answer. The code factors
#	this function out of download. Thus a test can make sure that
#	the path still resolves. download only warns when the path does
#	not resolve. Thus a rename would otherwise degrade silently to
#	"no download" and would not fail.
sub _ftp_script ()
{
	return Fugu::File->share_path('scripts/ftp');
}

# $self->download($version):
#	Download the miniroot image for the version through the proxy
#	cache. Return the path on success, or undef on failure.
sub download ( $self, $version )
{
	if ( !defined $self->{proxy} ) {
		warn "No proxy available for download\n";
		return;
	}

	my $url = $self->url($version);

	# Download with the scripts/ftp helper, which uses curl, wget,
	# or ftp. Then store the file in the proxy cache.
	require File::Temp;
	my $tmp      = File::Temp->new( SUFFIX => '.img' );
	my $tmp_path = $tmp->filename;

	my $ftp = _ftp_script();

	if ( !-x $ftp ) {
		warn "Cannot find the ftp helper at $ftp\n";
		return;
	}

	# Download to the temp file. The helper writes its progress as
	# it goes, and a download of a hundred megabytes is a wait that
	# an operator wants to see.
	my $result = Fugu::Process->run(
		cmd         => [ $ftp, $tmp_path, $url ],
		passthrough => 1,
	);
	unless ( $result->{success} ) {
		Fugu::Log->default->error( 'Download failed: %s',
			$result->{error} // "exit $result->{exit_code}" );
		return;
	}

	# Make sure that the download wrote a file
	if ( !-f $tmp_path || -z $tmp_path ) {
		warn "Download succeeded but file is empty\n";
		return;
	}

	# Store the file in the proxy cache
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
#	List all the cached miniroot images. Return an arrayref of
#	{ version, filename, path }.
sub list ($self)
{
	my @images;

	# The listing walks the mirror tree that the cache built. The
	# root comes from a cache path, so this module still owns one
	# copy of the layout and not two.
	my $base_path = $self->_release_root;
	return \@images if !defined $base_path || !-d $base_path;

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

	# Sort by version in descending order
	@images = sort { $b->{version} cmp $a->{version} } @images;

	return \@images;
}

# $self->_image_filename($version):
#	Make the miniroot filename for the version, for example
#	"miniroot78.img".
sub _image_filename ( $self, $version )
{
	( my $ver = $version ) =~ s/\.//g;
	return "miniroot$ver.img";
}

# $self->_image_path($version):
#	Return the file that the miniroot of a version lands in.
#
#	The answer comes from the cache, not from a copy of its layout
#	here. A cache that changed where it puts a URL would otherwise
#	leave this module looking in the old place, and every run would
#	download the image again.
sub _image_path ( $self, $version )
{
	return $self->_cache->cache_path( $self->url($version) );
}

# $self->_release_root:
#	Return the directory that holds every cached OpenBSD release,
#	derived from where the cache puts a release URL.
sub _release_root ($self)
{
	my $sample = $self->_cache->cache_path(
		'https://' . CDN_HOST . '/pub/OpenBSD/marker' );
	return if !defined $sample;

	$sample =~ s{/marker$}{};

	return $sample;
}

# $self->_cache:
#	Return the cache to ask. A proxy brings its own; without one,
#	the module builds a cache over the same directory so that a
#	lookup still resolves.
sub _cache ($self)
{
	return $self->{proxy}->cache if defined $self->{proxy};

	require App::FuguVM::Proxy;
	return App::FuguVM::Proxy::Cache->new( $self->{cache_dir} );
}

1;
