# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@dickolsson.com>
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

# OpenHVF::ImageCache - cache of installed OpenBSD disk images
#
# Installing OpenBSD under TCG emulation costs tens of minutes. This
# module keeps the result: a pristine, compacted copy of the disk taken
# the moment the installer finished, which later runs use as the backing
# image of a throwaway overlay.

package OpenHVF::ImageCache;

use Digest::SHA ();
use File::Basename;
use File::Path qw(make_path remove_tree);
use File::Spec ();
use JSON::XS   ();
use OpenHVF::Expect;
use OpenHVF::Image;

use constant {
	BASE_NAME         => 'base.qcow2',
	META_NAME         => 'meta.json',
	INSTALLED_DIR     => 'installed',
	SNAPSHOT_DIR      => 'snapshots',
	TEMP_PREFIX       => '.tmp.',
	GENERATION_FILE   => 'cache-generation',
	INSTALL_SCRIPT    => 'install.exp',
	KEY_HASH_LENGTH   => 8,
	MAX_SNAPSHOT_NAME => 128,
};

# Temporary entry trees still being built, removed by _cleanup_temp on
# any failure path and from the END guard. The convert step runs for
# minutes over multi-gigabyte images; an interrupt in the middle of it
# is what would otherwise orphan them.
my %TEMP_DIRS;

END {
	_cleanup_temp();
}

sub new ( $class, $cache_dir )
{
	$cache_dir =~ s/^~/$ENV{HOME}/;

	my $self = bless { cache_dir => $cache_dir, }, $class;

	return $self;
}

sub cache_dir ($self)
{
	return $self->{cache_dir};
}

# $self->installed_dir:
#	Directory holding every cached entry
sub installed_dir ($self)
{
	return "$self->{cache_dir}/" . INSTALLED_DIR;
}

# $self->entry_dir($key):
#	Directory of one cached entry
sub entry_dir ( $self, $key )
{
	return $self->installed_dir . "/$key";
}

# $self->base_path($key):
#	Absolute path of an entry's base image, whether or not it exists
sub base_path ( $self, $key )
{
	return $self->entry_dir($key) . '/' . BASE_NAME;
}

# $self->key($vm_config):
#	Derive the cache key for a VM configuration:
#	<version>-<arch>-<hash8>. The hash covers everything that shapes
#	an installed disk - the OpenBSD version, the architecture, the
#	disk size, the installer script, and the generation counter - and
#	nothing that does not, so memory and port changes keep hitting the
#	same entry. Returns undef when an input cannot be read, which
#	leaves the caller with no key and therefore no caching.
sub key ( $self, $vm_config )
{
	my $version   = _sanitize( $vm_config->{version} // '' );
	my $arch      = _sanitize(OpenHVF::Image::ARCH);
	my $disk_size = $vm_config->{disk_size} // '';

	my $script = $self->_install_script;
	if ( !defined $script ) {
		warn "Cannot locate " . INSTALL_SCRIPT . " for cache key\n";
		return;
	}

	my $installer = _read_file($script);
	return if !defined $installer;

	my $generation_file = $self->_generation_file;
	if ( !defined $generation_file ) {
		warn "Cannot locate " . GENERATION_FILE . " for cache key\n";
		return;
	}

	my $generation = _read_file($generation_file);
	return if !defined $generation;

	# Hash file contents separately so the joined record stays free of
	# newlines and the delimiter cannot be forged by an input value.
	my @inputs = (
		"version=$version",
		"arch=$arch",
		"disk_size=$disk_size",
		'install=' . Digest::SHA::sha256_hex($installer),
		'generation=' . Digest::SHA::sha256_hex($generation),
	);

	my $hash = Digest::SHA::sha256_hex( join( "\n", @inputs ) );

	return "$version-$arch-" . substr( $hash, 0, KEY_HASH_LENGTH );
}

# $self->lookup($key):
#	Return { base => path, meta => hashref, dir => path } for a
#	complete entry, undef otherwise. A half-written entry is a miss,
#	not an error: the caller falls back to a full installation.
sub lookup ( $self, $key )
{
	return if !defined $key;

	my $dir  = $self->entry_dir($key);
	my $base = "$dir/" . BASE_NAME;
	return if !-f $base;

	my $meta = _read_json( "$dir/" . META_NAME );
	return if !defined $meta;

	return {
		key  => $key,
		dir  => $dir,
		base => $base,
		meta => $meta,
	};
}

# $self->store($key, $disk_path, $meta):
#	Publish $disk_path as the cached base image for $key. The entry is
#	built whole in a sibling temporary directory and published by
#	renaming that directory, so no reader ever sees one installation's
#	base image beside another installation's metadata - a mismatch
#	that would look live and then wedge every later boot with a root
#	password that does not open the image.
#
#	Entries are write-once: rename onto a populated directory fails
#	with ENOTEMPTY, and the existing entry wins. Returns the base
#	image path, or undef on any failure.
sub store ( $self, $key, $disk_path, $meta = {} )
{
	return if !defined $key;

	if ( !-f $disk_path ) {
		warn "Cannot cache missing disk image: $disk_path\n";
		return;
	}

	my $installed = $self->installed_dir;
	if ( !-d $installed ) {
		make_path($installed);
		if ( !-d $installed ) {
			warn "Cannot create image cache: $installed\n";
			return;
		}
	}

	my $target = $self->entry_dir($key);
	if ( -e "$target/" . BASE_NAME ) {
		warn "Image cache entry already exists: $key\n";
		return;
	}

	my $tmp = $self->_make_temp_dir or return;

	local $SIG{INT}  = sub { _cleanup_temp(); exit 130; };
	local $SIG{TERM} = sub { _cleanup_temp(); exit 143; };

	my $base = "$tmp/" . BASE_NAME;
	if ( !_convert( $disk_path, $base ) ) {
		$self->_discard_temp($tmp);
		return;
	}

	chmod 0400, $base or do {
		warn "Cannot set permissions on $base: $!\n";
		$self->_discard_temp($tmp);
		return;
	};

	my %record = (
		%$meta,
		key        => $key,
		created_at => time,
	);
	if ( !_write_json( "$tmp/" . META_NAME, \%record ) ) {
		$self->_discard_temp($tmp);
		return;
	}

	if ( !rename $tmp, $target ) {
		warn "Cannot publish image cache entry $key: $!\n";
		$self->_discard_temp($tmp);
		return;
	}
	delete $TEMP_DIRS{$tmp};

	return "$target/" . BASE_NAME;
}

# $self->list:
#	Every complete entry, newest first, as
#	{ key, dir, base, size, created_at, meta, snapshots }
sub list ($self)
{
	my @entries;
	my $installed = $self->installed_dir;
	return \@entries if !-d $installed;

	opendir my $dh, $installed or return \@entries;
	my @keys = grep { !/^\./ && -d "$installed/$_" } readdir $dh;
	closedir $dh;

	for my $key ( sort @keys ) {
		my $entry = $self->lookup($key) or next;
		$entry->{size}       = _tree_size( $entry->{dir} );
		$entry->{created_at} = $entry->{meta}{created_at};
		$entry->{snapshots}  = $self->_snapshot_names($key);
		push @entries, $entry;
	}

	return [
		sort { ( $b->{created_at} // 0 ) <=> ( $a->{created_at} // 0 ) }
		    @entries
	];
}

# $self->key_for_path($path):
#	The cache key whose entry contains $path - a base image or a
#	snapshot - or undef when $path lies outside the cache. Lets a
#	caller answer "which cached image is this disk built on?".
sub key_for_path ( $self, $path )
{
	return if !defined $path;

	my $installed = $self->installed_dir . '/';
	return if index( $path, $installed ) != 0;

	my ($key) = split m{/}, substr( $path, length $installed ), 2;
	return if !defined $key || $key eq '';

	return $key;
}

# $self->snapshot_dir($key):
#	Directory holding an entry's named snapshot layers
sub snapshot_dir ( $self, $key )
{
	return $self->entry_dir($key) . '/' . SNAPSHOT_DIR;
}

# $self->snapshot_path($key, $name):
#	Absolute path of a named snapshot, whether or not it exists
sub snapshot_path ( $self, $key, $name )
{
	return $self->snapshot_dir($key) . "/$name.qcow2";
}

# valid_snapshot_name($name):
#	Snapshot names become file names inside the cache, so they are
#	held to the same restrictions as VM names plus a leading
#	alphanumeric, which keeps them clear of the cache's own dot-files.
sub valid_snapshot_name ( $, $name )
{
	return 0 if !defined $name || $name eq '';
	return 0 if length($name) > MAX_SNAPSHOT_NAME;
	return 0 if $name !~ /^[A-Za-z0-9][\w.-]*$/;

	return 1;
}

# $self->snapshot_store($key, $name, $disk_path, $meta):
#	Publish the (stopped) working disk as the named snapshot layer of
#	entry $key.
#
#	The disk is flattened onto base.qcow2 rather than copied. A copy
#	would carry the working disk's backing-file header verbatim, which
#	is only correct while that disk hangs directly off the base: after
#	a restore it hangs off a snapshot, so a copy would either stack
#	chains without bound or - when the same name is re-saved, which a
#	normal second run does - name itself as its own backing file.
#	Flattening also keeps every snapshot a direct child of the base,
#	so no snapshot is ever another's parent and removing one cannot
#	orphan another.
#
#	Returns the snapshot path, or undef on failure.
sub snapshot_store ( $self, $key, $name, $disk_path, $meta = {} )
{
	if ( !$self->valid_snapshot_name($name) ) {
		warn "Invalid snapshot name: " . ( $name // '(undef)' ) . "\n";
		return;
	}

	my $entry = $self->lookup($key);
	if ( !defined $entry ) {
		warn "No cached image for $key to snapshot against\n";
		return;
	}

	if ( !-f $disk_path ) {
		warn "Cannot snapshot missing disk image: $disk_path\n";
		return;
	}

	my $dir = $self->snapshot_dir($key);
	if ( !-d $dir ) {
		make_path($dir);
		if ( !-d $dir ) {
			warn "Cannot create snapshot directory: $dir\n";
			return;
		}
	}

	my $target   = $self->snapshot_path( $key, $name );
	my $tmp_disk = "$target." . TEMP_PREFIX . $$;
	my $tmp_meta = "$dir/$name.json." . TEMP_PREFIX . $$;

	unlink $tmp_disk, $tmp_meta;

	if ( !_convert( $disk_path, $tmp_disk, $entry->{base}, 'qcow2' ) ) {
		unlink $tmp_disk;
		return;
	}

	chmod 0400, $tmp_disk or do {
		warn "Cannot set permissions on $tmp_disk: $!\n";
		unlink $tmp_disk;
		return;
	};

	# The root password belongs to the base image, so it is copied
	# from there rather than trusted from the caller.
	my %record = (
		%$meta,
		key           => $key,
		name          => $name,
		root_password => $entry->{meta}{root_password},
		created_at    => time,
	);
	if ( !_write_json( $tmp_meta, \%record ) ) {
		unlink $tmp_disk, $tmp_meta;
		return;
	}

	# Two renames, metadata first. Re-saving a name is normal, and a
	# reader catching the window sees the previous image with the new
	# metadata - fields that describe the base, which has not changed.
	if ( !rename $tmp_meta, "$dir/$name.json" ) {
		warn "Cannot publish snapshot metadata $name: $!\n";
		unlink $tmp_disk, $tmp_meta;
		return;
	}
	if ( !rename $tmp_disk, $target ) {
		warn "Cannot publish snapshot $name: $!\n";
		unlink $tmp_disk;
		return;
	}

	return $target;
}

# $self->snapshot_lookup($key, $name):
#	Return { key, name, path, meta } for a snapshot whose image, its
#	metadata, and its backing chain all resolve; undef otherwise. A
#	snapshot whose base has been removed is a miss, so a caller can
#	fall back to provisioning from scratch instead of failing hard.
sub snapshot_lookup ( $self, $key, $name )
{
	return if !$self->valid_snapshot_name($name);

	my $path = $self->snapshot_path( $key, $name );
	return if !-f $path;

	my $meta = _read_json( $self->snapshot_dir($key) . "/$name.json" );
	return if !defined $meta;

	my $base = $self->base_path($key);
	return if !-f $base;

	return {
		key  => $key,
		name => $name,
		path => $path,
		base => $base,
		meta => $meta,
	};
}

# $self->snapshot_list($key):
#	Sorted snapshots of an entry, as { name, path, size, created_at }
sub snapshot_list ( $self, $key )
{
	my @snapshots;

	for my $name ( @{ $self->_snapshot_names($key) } ) {
		my $found = $self->snapshot_lookup( $key, $name ) or next;
		push @snapshots,
		    {
			name       => $name,
			path       => $found->{path},
			size       => ( -s $found->{path} ) // 0,
			created_at => $found->{meta}{created_at},
			meta       => $found->{meta},
		    };
	}

	return \@snapshots;
}

# $self->snapshot_remove($key, $name):
#	Delete a snapshot and its metadata. Safe in any order: snapshots
#	are always direct children of the base, never of each other.
sub snapshot_remove ( $self, $key, $name )
{
	return 0 if !$self->valid_snapshot_name($name);

	my $dir  = $self->snapshot_dir($key);
	my $path = "$dir/$name.qcow2";
	my $meta = "$dir/$name.json";

	for my $file ( $path, $meta ) {
		next if !-e $file;
		unlink $file or do {
			warn "Cannot remove $file: $!\n";
			return 0;
		};
	}

	return 1;
}

# $self->_snapshot_names($key):
#	Sorted names of the named snapshot layers stored under an entry
sub _snapshot_names ( $self, $key )
{
	my $dir = $self->snapshot_dir($key);
	return [] if !-d $dir;

	opendir my $dh, $dir or return [];
	my @names;
	for my $file ( readdir $dh ) {
		next if $file !~ /^([^.][^\/]*)\.qcow2$/;
		push @names, $1;
	}
	closedir $dh;

	return [ sort @names ];
}

# $self->remove($key):
#	Delete a cached entry and everything under it. Returns true when
#	the entry is gone afterwards.
sub remove ( $self, $key )
{
	my $dir = $self->entry_dir($key);
	return 1 if !-d $dir;

	remove_tree( $dir, { safe => 0 } );
	if ( -e $dir ) {
		warn "Cannot remove image cache entry $key\n";
		return 0;
	}

	return 1;
}

# $self->sweep_temp:
#	Remove temporary entry trees left behind by an interrupted store,
#	including those from earlier processes. Returns the count removed.
sub sweep_temp ($self)
{
	my $installed = $self->installed_dir;
	return 0 if !-d $installed;

	opendir my $dh, $installed or return 0;
	my $prefix = TEMP_PREFIX;
	my @stale  = grep { index( $_, $prefix ) == 0 } readdir $dh;
	closedir $dh;

	my $removed = 0;
	for my $name (@stale) {
		my $dir = "$installed/$name";
		next if !-d $dir;
		remove_tree( $dir, { safe => 0 } );
		$removed++ if !-e $dir;
	}

	return $removed;
}

# $self->_make_temp_dir:
#	Create a private sibling directory for an entry under
#	construction, registered for cleanup.
sub _make_temp_dir ($self)
{
	my $installed = $self->installed_dir;

	for my $attempt ( 1 .. 10 ) {
		my $dir = sprintf( '%s/%s%d.%06x',
			$installed, TEMP_PREFIX, $$, int( rand(0xffffff) ) );
		next if -e $dir;
		if ( mkdir $dir, 0700 ) {
			$TEMP_DIRS{$dir} = 1;
			return $dir;
		}
	}

	warn "Cannot create temporary image cache directory\n";
	return;
}

sub _discard_temp ( $, $dir )
{
	remove_tree( $dir, { safe => 0 } );
	delete $TEMP_DIRS{$dir};
	return;
}

sub _cleanup_temp ()
{
	for my $dir ( keys %TEMP_DIRS ) {
		remove_tree( $dir, { safe => 0 } );
		delete $TEMP_DIRS{$dir};
	}
	return;
}

# _convert($source, $target, $backing, $backing_format):
#	Compact $source into a fresh qcow2 at $target, optionally leaving
#	$backing as its parent so only the difference is stored.
sub _convert ( $source, $target, $backing = undef, $backing_format = 'qcow2' )
{
	my @cmd = ( 'qemu-img', 'convert', '-O', 'qcow2' );
	push @cmd, '-B', $backing, '-F', $backing_format if defined $backing;
	push @cmd, $source, $target;

	my $result = system(@cmd);
	if ( $result != 0 ) {
		warn "qemu-img convert failed for $source\n";
		return 0;
	}

	return 1;
}

# $self->_install_script:
#	The installer script whose bytes go into the cache key. Resolved
#	through OpenHVF::Expect so it is always the same file run_install
#	would execute.
sub _install_script ($)
{
	return OpenHVF::Expect->script_path(INSTALL_SCRIPT);
}

# $self->_generation_file:
#	Locate share/openhvf/cache-generation, whose contents rotate the
#	cache key when the install driver changes in ways the install.exp
#	hash cannot see.
sub _generation_file ($)
{
	my $module_dir = dirname( File::Spec->rel2abs(__FILE__) );
	my $root       = dirname( dirname($module_dir) );

	my @candidates = (
		"$root/share/openhvf/" . GENERATION_FILE,
		'share/openhvf/' . GENERATION_FILE,
	);

	for my $path (@candidates) {
		return $path if -f $path;
	}

	return;
}

sub _sanitize ($value)
{
	$value =~ s/[^\w.]/_/g;
	return $value;
}

sub _read_file ($path)
{
	open my $fh, '<', $path or do {
		warn "Cannot read $path: $!\n";
		return;
	};
	binmode $fh;
	local $/;
	my $content = <$fh>;
	close $fh;

	return $content // '';
}

sub _read_json ($path)
{
	return if !-f $path;

	my $content = _read_file($path);
	return if !defined $content || $content eq '';

	my $data = eval { JSON::XS::decode_json($content) };
	return if !defined $data || ref $data ne 'HASH';

	return $data;
}

# _write_json($path, $data):
#	Write metadata readable only by its owner: it carries the guest
#	root password.
sub _write_json ( $path, $data )
{
	open my $fh, '>', $path or do {
		warn "Cannot write $path: $!\n";
		return 0;
	};
	print $fh JSON::XS->new->canonical->encode($data);
	close $fh;

	chmod 0600, $path or do {
		warn "Cannot set permissions on $path: $!\n";
		return 0;
	};

	return 1;
}

sub _tree_size ($dir)
{
	my $total = 0;

	opendir my $dh, $dir or return $total;
	my @names = grep { !/^\.\.?$/ } readdir $dh;
	closedir $dh;

	for my $name (@names) {
		my $path = "$dir/$name";
		if ( -d $path ) {
			$total += _tree_size($path);
			next;
		}
		$total += ( -s $path ) // 0;
	}

	return $total;
}

1;
