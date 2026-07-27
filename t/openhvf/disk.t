#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);

use_ok('OpenHVF::Disk');

# Test object creation
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $disk = OpenHVF::Disk->new($tmpdir);
    ok(defined $disk, 'Disk object created');
}

# Test path generation
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $disk = OpenHVF::Disk->new($tmpdir);
    
    my $path = $disk->path('test');
    like($path, qr/test.*disk\.qcow2$/, 'path includes VM name and disk.qcow2');
}

# Test exists returns false for non-existent disk
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $disk = OpenHVF::Disk->new($tmpdir);
    
    ok(!$disk->disk_exists('test'), 'disk_exists returns false for missing disk');
}

# Test remove on non-existent disk
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $disk = OpenHVF::Disk->new($tmpdir);
    
    my $result = $disk->remove('test');
    ok($result, 'remove returns true for non-existent disk');
}

# Skip tests that require qemu-img
SKIP: {
    my $has_qemu = `which qemu-img 2>/dev/null`;
    skip 'qemu-img not installed', 10 unless $has_qemu;

    my $tmpdir = tempdir(CLEANUP => 1);
    my $disk = OpenHVF::Disk->new($tmpdir);

    # Test disk creation
    my $path = $disk->create('test', '1G');
    ok(defined $path, 'create returns path');
    ok(-f $path, 'disk file created');

    # A standalone disk has no backing file
    is($disk->backing_file('test'), undef,
	'backing_file is undef for a standalone disk');
    is($disk->backing_file('missing'), undef,
	'backing_file is undef for a missing disk');

    # Overlays: no size, and a qcow2 (not raw) backing format
    my $overlay_dir = tempdir(CLEANUP => 1);
    my $overlay = OpenHVF::Disk->new($overlay_dir);
    my $opath = $overlay->create('child', undef, $path, 'qcow2');
    ok(defined $opath, 'overlay created without an explicit size');

    my $info = $overlay->info('child');
    is($info->{'backing-filename-format'}, 'qcow2',
	'backing format is passed through, not hardwired to raw');
    is($overlay->backing_file('child'), $path,
	'backing_file resolves the parent image');
    is($info->{'virtual-size'}, $disk->info('test')->{'virtual-size'},
	'overlay inherits the backing image virtual size');

    # qemu-img still reports the reference once the parent is gone:
    # that is what makes a broken chain diagnosable rather than an
    # opaque failure at boot.
    unlink $path;
    is($overlay->backing_file('child'), $path,
	'backing_file still names a missing parent');
    ok(!-f $overlay->backing_file('child'),
	'and the caller can see that it is gone');
}

done_testing();
