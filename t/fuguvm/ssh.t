#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

# Skip if Net::SSH2 is not available
BEGIN {
    eval { require Net::SSH2 };
    if ($@) {
	plan skip_all => 'Net::SSH2 not available';
    }
}

use_ok('FuguVM::SSH');

# Test constants
is(FuguVM::SSH::EXIT_SUCCESS(), 0, 'EXIT_SUCCESS is 0');
is(FuguVM::SSH::EXIT_ERROR(), 1, 'EXIT_ERROR is 1');
is(FuguVM::SSH::DEFAULT_TIMEOUT(), 10, 'DEFAULT_TIMEOUT is 10');
is(FuguVM::SSH::BUFFER_SIZE(), 32768, 'BUFFER_SIZE is 32768');

# Test object creation
{
    my $ssh = FuguVM::SSH->new(host => 'localhost', port => 22);
    ok(defined $ssh, 'SSH object created');
    is($ssh->{host}, 'localhost', 'host stored');
    is($ssh->{port}, 22, 'port stored');
}

# Test object creation with default port
{
    my $ssh = FuguVM::SSH->new(host => 'example.com');
    is($ssh->{port}, 22, 'default port is 22');
}

# Test wait_available to non-existent host returns false
{
    my $ssh = FuguVM::SSH->new(host => 'localhost', port => 59999);
    my $result = $ssh->wait_available(1);
    ok(!$result, 'wait_available to closed port returns false');
}

# Test is_available
{
    my $ssh = FuguVM::SSH->new(host => 'localhost', port => 59999);
    ok(!$ssh->is_available, 'is_available false for closed port');
}

# _exit_code maps a raw wait status to a 0-255 exit code. This lets
# `fuguvm ssh`, when it runs a script over stdin, propagate a failing
# remote command (for example a failing `prove` run). Without it, a raw
# status like 256 truncates down to exit(256) -> 0.
{
    is(FuguVM::SSH::_exit_code(0), 0, 'status 0 -> exit 0');
    is(FuguVM::SSH::_exit_code(1 << 8), 1, 'exit code 1 preserved');
    is(FuguVM::SSH::_exit_code(2 << 8), 2, 'exit code 2 preserved');
    is(FuguVM::SSH::_exit_code(255 << 8), 255, 'exit code 255 preserved');
    is(FuguVM::SSH::_exit_code(-1), 1, 'system() failure (-1) -> EXIT_ERROR');
    is(FuguVM::SSH::_exit_code(15), 143, 'signal 15 -> 128 + signal');
    is(FuguVM::SSH::_exit_code(2), 130, 'signal 2 -> 128 + signal');
}

done_testing();
