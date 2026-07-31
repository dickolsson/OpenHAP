#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use_ok('FuguVM::Image');

# Test constants
is(FuguVM::Image::CDN_HOST(), 'cdn.openbsd.org',
    'CDN_HOST is correct');
is(FuguVM::Image::ARCH(), 'arm64',
    'ARCH is correct');

# download() only warns when the helper is missing, so a rename would
# degrade silently to "no download" instead of failing.  Assert the path
# still resolves.
ok(-x FuguVM::Image::_ftp_script(),
    'the ftp helper resolves to an executable');

# Test object creation
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    ok(defined $image, 'Image object created');
}

# Test url generation
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    
    my $url = $image->url('7.8');
    is($url, 'https://cdn.openbsd.org/pub/OpenBSD/7.8/arm64/miniroot78.img',
       'URL generated correctly');
}

# Test image filename generation
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    
    my $filename = $image->_image_filename('7.8');
    is($filename, 'miniroot78.img', 'Image filename generated correctly');
}

# Test path returns undef for missing image
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    
    my $path = $image->path('7.8');
    is($path, undef, 'path returns undef for missing image');
}

# Test path returns path for cached image
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    
    # Create fake cached image in proxy cache structure
    my $cache_path = "$tmpdir/proxy/cdn.openbsd.org/pub/OpenBSD/7.8/arm64";
    make_path($cache_path);
    open my $fh, '>', "$cache_path/miniroot78.img";
    print $fh "fake image content";
    close $fh;
    
    my $path = $image->path('7.8');
    ok(defined $path, 'path returns path for cached image');
    like($path, qr/miniroot78\.img$/, 'path ends with correct filename');
}

# Test list returns empty for empty cache
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    
    my $list = $image->list;
    is(ref $list, 'ARRAY', 'list returns array ref');
    is(scalar @$list, 0, 'list is empty for empty cache');
}

# Test list finds cached images
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $image = FuguVM::Image->new($tmpdir);
    
    # Create fake cached images in proxy cache structure
    for my $ver (qw(7.7 7.8)) {
        (my $shortver = $ver) =~ s/\.//;
        my $cache_path = "$tmpdir/proxy/cdn.openbsd.org/pub/OpenBSD/$ver/arm64";
        make_path($cache_path);
        open my $fh, '>', "$cache_path/miniroot$shortver.img";
        close $fh;
    }
    
    my $list = $image->list;
    is(scalar @$list, 2, 'list finds both images');
    is($list->[0]{version}, '7.8', 'latest version first');
    is($list->[1]{version}, '7.7', 'older version second');
}

done_testing();
