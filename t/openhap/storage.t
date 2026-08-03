#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::TestLog;
use File::Temp qw(tempdir);

use_ok('OpenHAP::Storage');

# Create a temporary directory for the tests
my $temp_dir = tempdir(CLEANUP => 1);

# Test storage initialization
{
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    ok(defined $storage, 'Storage object created');
    isa_ok($storage, 'OpenHAP::Storage');
    ok(-d $temp_dir, 'Storage directory exists');
}

# Test accessory key storage
{
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    
    my $ltsk = 'secret_key_' . ('x' x 54);
    my $ltpk = 'public_key_' . ('x' x 21);
    
    $storage->save_accessory_keys($ltsk, $ltpk);
    
    my ($loaded_ltsk, $loaded_ltpk) = $storage->load_accessory_keys();
    is($loaded_ltsk, $ltsk, 'LTSK loaded correctly');
    is($loaded_ltpk, $ltpk, 'LTPK loaded correctly');
}

# Test pairing storage and loading
{
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    
    my $controller_id = 'controller-123';
    my $ltpk = 'public_key_abc';
    my $permissions = 1;
    
    $storage->save_pairing($controller_id, $ltpk, $permissions);
    
    my $pairings = $storage->load_pairings();
    ok(exists $pairings->{$controller_id}, 'Pairing exists');
    is($pairings->{$controller_id}{ltpk}, $ltpk, 'LTPK matches');
    is($pairings->{$controller_id}{permissions}, $permissions, 'Permissions match');
}

# Test multiple pairings
{
    my $temp_dir2 = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir2);
    
    $storage->save_pairing('controller-1', 'ltpk1', 1);
    $storage->save_pairing('controller-2', 'ltpk2', 0);
    
    my $pairings = $storage->load_pairings();
    is(scalar keys %$pairings, 2, 'Two pairings stored');
    is($pairings->{'controller-1'}{permissions}, 1, 'Controller 1 is admin');
    is($pairings->{'controller-2'}{permissions}, 0, 'Controller 2 is regular');
}

# Test pairing removal
{
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    
    $storage->save_pairing('temp-controller', 'temp-ltpk', 1);
    my $pairings = $storage->load_pairings();
    ok(exists $pairings->{'temp-controller'}, 'Pairing exists before removal');
    
    $storage->remove_pairing('temp-controller');
    $pairings = $storage->load_pairings();
    ok(!exists $pairings->{'temp-controller'}, 'Pairing removed');
}

# Test config number
{
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    
    my $config_num = $storage->get_config_number();
    ok($config_num >= 1, 'Config number is valid');
    
    my $new_num = $storage->increment_config_number();
    is($new_num, $config_num + 1, 'Config number incremented');
    
    my $loaded_num = $storage->get_config_number();
    is($loaded_num, $new_num, 'Config number persisted');
}

# Test hex encoding in pairings file
{
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir);
    
    # Binary LTPK with special characters
    my $binary_ltpk = pack('H*', 'deadbeef' . ('aa' x 12));
    $storage->save_pairing('binary-controller', $binary_ltpk, 1);
    
    my $pairings = $storage->load_pairings();
    is($pairings->{'binary-controller'}{ltpk}, $binary_ltpk, 'Binary LTPK stored correctly');
}

# Test remove_all_pairings ([HAP-Pairing §7.2] last-admin removal)
{
    my $temp_dir3 = tempdir(CLEANUP => 1);
    my $storage = OpenHAP::Storage->new(db_path => $temp_dir3);
    
    # Add multiple pairings
    $storage->save_pairing('controller-a', 'ltpk-a', 1);
    $storage->save_pairing('controller-b', 'ltpk-b', 0);
    $storage->save_pairing('controller-c', 'ltpk-c', 0);
    
    my $pairings = $storage->load_pairings();
    is(scalar keys %$pairings, 3, 'Three pairings stored');
    
    # Remove all pairings
    $storage->remove_all_pairings();

    $pairings = $storage->load_pairings();
    is(scalar keys %$pairings, 0,
        '[HAP-Pairing §7.2] all pairings removed');
}

# The counters live in one state file, at mode 0600. A restart must
# find them where it left them: a controller that sees c# go backwards
# drops the accessory and the owner has to pair again.
subtest 'the counters survive a restart' => sub {
	my $dir     = tempdir( CLEANUP => 1 );
	my $storage = OpenHAP::Storage->new( db_path => $dir );

	$storage->save_config_digest('b1946ac92492d2347c6235b4d2611184');
	$storage->set_auth_attempts(3);
	is( $storage->increment_config_number, 2, 'c# starts at 1 and goes up' );

	ok( -f "$dir/state.json", 'the counters are in a state file' );
	is( ( stat "$dir/state.json" )[2] & 07777,
		0600, 'which no other user can read' );

	my $again = OpenHAP::Storage->new( db_path => $dir );
	is( $again->get_config_number, 2,
		'[HAP-Pairing §7.2] the configuration number survives' );
	is( $again->get_config_digest,
		'b1946ac92492d2347c6235b4d2611184',
		'the configuration digest survives' );
	is( $again->get_auth_attempts, 3,
		'[HAP-Pairing §8] the failed-attempt counter survives' );
};

# OpenHAP::Storage is a store in the sense of Protocol/HAP/Store.pod.
# The engine calls these twelve methods and no others; a missing one
# must fail here, not in a paired home.
subtest 'the store contract of Protocol::HAP' => sub {
	my @contract = qw(
	    load_accessory_keys save_accessory_keys
	    load_pairings save_pairing remove_pairing remove_all_pairings
	    get_config_number increment_config_number
	    get_config_digest save_config_digest
	    get_auth_attempts set_auth_attempts
	);

	for my $method (@contract) {
		ok( OpenHAP::Storage->can($method),
			"OpenHAP::Storage provides $method" );
	}
};

done_testing();
