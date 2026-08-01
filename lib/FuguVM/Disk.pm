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

package FuguVM::Disk;

use File::Path qw(make_path);
use File::Basename;

sub new ( $class, $state_dir )
{
	my $self = bless { state_dir => $state_dir, }, $class;

	return $self;
}

# $self->create($name, $size, $backing_image, $backing_format):
#	Create the VM disk image. $size can be undef for an overlay.
#	The overlay then inherits the virtual size of $backing_image.
#	$backing_format names the format of $backing_image. Use 'qcow2'
#	for cached base images and snapshots. Use 'raw' in other cases.
#
#	The method returns early when the path already exists. Thus
#	callers that replace a disk with an overlay must unlink the
#	disk first.
sub create (
	$self, $name,
	$size           = undef,
	$backing_image  = undef,
	$backing_format = 'raw'
    )
{
	my $path = $self->path($name);
	my $dir  = dirname($path);

	make_path($dir) if !-d $dir;

	return $path if -f $path;    # Already exists

	my @cmd = ( 'qemu-img', 'create', '-f', 'qcow2' );

	if ( defined $backing_image ) {
		push @cmd, '-b', $backing_image, '-F', $backing_format;
	}

	push @cmd, $path;
	push @cmd, $size if defined $size;

	# Redirect the output to /dev/null. This removes the verbose
	# "Formatting..." messages of qemu-img. The code uses a shell
	# redirection because system() gives no output control.
	my $cmd_str =
	    join( ' ', map { my $s = $_; $s =~ s/'/'\\''/g; "'$s'" } @cmd );
	my $result = system("$cmd_str >/dev/null 2>&1");

	if ( $result != 0 ) {
		warn "Failed to create disk image: $path\n";
		return;
	}

	return $path;
}

sub disk_exists ( $self, $name )
{
	return -f $self->path($name);
}

sub path ( $self, $name )
{
	return "$self->{state_dir}/$name/disk.qcow2";
}

sub remove ( $self, $name )
{
	my $path = $self->path($name);
	if ( -f $path ) {
		unlink $path or do {
			warn "Cannot remove $path: $!";
			return 0;
		};
	}
	return 1;
}

# $self->info($name):
#	Get the qemu-img report on the disk as a hashref. The method
#	returns undef when there is no disk or when it cannot read the
#	disk. The inspection is read-only. Thus it asks for shared
#	access with -U. A running QEMU holds an exclusive lock. Without
#	shared access, the query fails on exactly the VMs whose backing
#	chain callers most need to resolve. If 'cache clear' skips the
#	disk of a running VM, it can remove the base from under that
#	VM.
sub info ( $self, $name )
{
	my $path = $self->path($name);
	return if !-f $path;

	my $output = `qemu-img info -U --output=json "$path" 2>/dev/null`;
	return if $? != 0;

	require JSON::XS;
	return eval { JSON::XS::decode_json($output) };
}

# $self->backing_file($name):
#	Get the absolute path of the image that backs the disk. The
#	method returns undef when the disk is standalone or when it
#	cannot inspect the disk. qemu-img reports a backing reference
#	even when the file it names is gone. This lets callers diagnose
#	a broken chain.
sub backing_file ( $self, $name )
{
	my $info = $self->info($name);
	return if !defined $info;

	my $backing = $info->{'full-backing-filename'}
	    // $info->{'backing-filename'};
	return if !defined $backing || $backing eq '';

	# Relative references resolve against the disk's own directory
	if ( $backing !~ m{^/} ) {
		$backing = dirname( $self->path($name) ) . "/$backing";
	}

	return $backing;
}

# P5: Check the disk image integrity. The method returns a hashref
# with the 'status' and 'output' keys. The 'status' key is 'ok' or
# 'corrupted'.
sub check ( $self, $name )
{
	my $path = $self->path($name);
	return if !-f $path;

	my $output    = `qemu-img check "$path" 2>&1`;
	my $exit_code = $?;

	if ( $exit_code != 0 ) {
		return {
			status => 'corrupted',
			output => $output,
			path   => $path,
		};
	}

	return {
		status => 'ok',
		output => $output,
		path   => $path,
	};
}

# P5: Repair the disk image. The method returns true on success and
# false on failure.
sub repair ( $self, $name )
{
	my $path = $self->path($name);
	return 0 if !-f $path;

	# Run qemu-img check with the repair option
	my $result = system( 'qemu-img', 'check', '-r', 'all', $path );
	return $result == 0;
}

1;
