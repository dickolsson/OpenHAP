#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new(mode => 'quiet', ident => 'test');
use File::Temp qw(tempdir);

use_ok('OpenHAP::Storage');

# Create temporary directory for testing
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

done_testing();
