#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use_ok('FuguVM::Util');

# Test generate_random_bytes
{
    my $bytes = FuguVM::Util->generate_random_bytes(16);
    is(length($bytes), 16, 'generate_random_bytes returns correct length');
    
    my $bytes2 = FuguVM::Util->generate_random_bytes(16);
    isnt($bytes, $bytes2, 'generate_random_bytes returns different values');
}

# Test generate_random_bytes with different lengths
{
    for my $len (8, 24, 32, 64) {
	my $bytes = FuguVM::Util->generate_random_bytes($len);
	is(length($bytes), $len, "generate_random_bytes($len) returns $len bytes");
    }
}

# Test generate_password
{
    my $password = FuguVM::Util->generate_password(32);
    is(length($password), 32, 'generate_password returns correct length');
    
    # Check it only contains URL-safe base64 characters
    like($password, qr/^[A-Za-z0-9_-]+$/, 'generate_password uses URL-safe characters');
}

# Test generate_password returns different values
{
    my $p1 = FuguVM::Util->generate_password(32);
    my $p2 = FuguVM::Util->generate_password(32);
    isnt($p1, $p2, 'generate_password returns different values each call');
}

# Test generate_password with different lengths
{
    for my $len (8, 16, 24, 48) {
	my $password = FuguVM::Util->generate_password($len);
	is(length($password), $len, "generate_password($len) returns $len chars");
	like($password, qr/^[A-Za-z0-9_-]+$/, "generate_password($len) is URL-safe");
    }
}

done_testing();
