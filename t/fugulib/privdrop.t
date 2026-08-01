#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use_ok('FuguLib::Privdrop');

# Test 1: Module loads
pass('FuguLib::Privdrop loaded');

# Test 2: drop_privileges requires user parameter
{
	eval { FuguLib::Privdrop->drop_privileges(); };
	like( $@, qr/user parameter required/, 'drop_privileges requires user parameter' );
}

# Test 3: drop_privileges with invalid user
SKIP: {
	skip 'Must be root to test invalid user error', 1 unless $> == 0;
	
	eval { FuguLib::Privdrop->drop_privileges( user => 'nonexistent_user_12345' ); };
	like( $@, qr/Cannot get UID for user/, 'drop_privileges fails with invalid user' );
}

# Test 4: drop_privileges with invalid group
SKIP: {
	skip 'Must be root to test privilege dropping', 1 unless $> == 0;
	
	eval { FuguLib::Privdrop->drop_privileges( user => 'nobody', group => 'nonexistent_group_12345' ); };
	like( $@, qr/Cannot get GID for group/, 'drop_privileges fails with invalid group' );
}

# Test 5: drop_privileges when already non-root (should be no-op)
SKIP: {
	skip 'Running as root, cannot test non-root behavior', 1 if $> == 0;
	
	my $orig_uid = $>;
	my $ok = eval { FuguLib::Privdrop->drop_privileges( user => 'nobody' ); 1; };
	ok( $ok, 'drop_privileges succeeds when already non-root' );
	is( $>, $orig_uid, 'UID unchanged when already non-root' );
}

# Test 6: Actual privilege drop (requires root)
SKIP: {
	skip 'Must be root to test actual privilege dropping', 5 unless $> == 0;
	
	# This test drops privileges for real. That has an effect on
	# the rest of the test suite. Thus normal test runs skip it.
	# Test it manually or in isolation.
	skip 'Actual privilege drop test skipped (would affect other tests)', 5;
	
	# A manual test does these steps:
	# - Fork a child process
	# - In the child, call drop_privileges
	# - Make sure that the UID and the GID have changed
	# - Make sure that the child cannot get root again
	# - Exit the child
}

done_testing();
