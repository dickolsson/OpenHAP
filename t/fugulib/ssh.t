#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

# Skip if Net::SSH2 is not available
BEGIN {
    eval { require Net::SSH2 };
    if ($@) {
	plan skip_all => 'Net::SSH2 not available';
    }
}

use_ok('FuguLib::SSH');

# Test constants
is(FuguLib::SSH::EXIT_SUCCESS(), 0, 'EXIT_SUCCESS is 0');
is(FuguLib::SSH::EXIT_ERROR(), 1, 'EXIT_ERROR is 1');
is(FuguLib::SSH::DEFAULT_TIMEOUT(), 10, 'DEFAULT_TIMEOUT is 10');
is(FuguLib::SSH::BUFFER_SIZE(), 32768, 'BUFFER_SIZE is 32768');

# Test object creation
{
    my $ssh = FuguLib::SSH->new(host => 'localhost', port => 22);
    ok(defined $ssh, 'SSH object created');
    is($ssh->{host}, 'localhost', 'host stored');
    is($ssh->{port}, 22, 'port stored');
}

# Test object creation with default port
{
    my $ssh = FuguLib::SSH->new(host => 'example.com');
    is($ssh->{port}, 22, 'default port is 22');
}

# Test wait_available to non-existent host returns false
{
    my $ssh = FuguLib::SSH->new(host => 'localhost', port => 59999);
    my $result = $ssh->wait_available(1);
    ok(!$result, 'wait_available to closed port returns false');
}

# Test is_available
{
    my $ssh = FuguLib::SSH->new(host => 'localhost', port => 59999);
    ok(!$ssh->is_available, 'is_available false for closed port');
}

# interactive maps a raw wait status to a 0-255 exit code through
# FuguLib::Process->exit_code. This lets `fuguvm ssh`, when it runs a
# script over stdin, propagate a failing remote command (for example a
# failing `prove` run). Without it, a raw status like 256 truncates
# down to exit(256) -> 0. The mapping itself is proven in
# t/fugulib/process.t; here only the one copy has to be gone.
{
    ok(!FuguLib::SSH->can('_exit_code'),
        'the private copy of the mapping is gone');
    ok(FuguLib::Process->can('exit_code'),
        'FuguLib::Process owns the mapping');
}

done_testing();
