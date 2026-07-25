#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

# Check if module can be loaded (may fail if Net::SSH2 not available)
BEGIN {
	eval { require OpenHVF::VM; 1 }
	    or plan skip_all => 'OpenHVF::VM dependencies not available';
}

use_ok('OpenHVF::VM');

# Memory and CPU constants
{
	ok(defined &OpenHVF::VM::MEMORY_DEFAULT, 'MEMORY_DEFAULT defined');
	is(OpenHVF::VM::MEMORY_DEFAULT(), '1G', 'Default memory is 1G');
	ok(defined &OpenHVF::VM::CPU_COUNT, 'CPU_COUNT defined');
	is(OpenHVF::VM::CPU_COUNT(), 2, 'Default CPU count is 2');
}

# Exit code constants
{
	is(OpenHVF::VM::EXIT_SUCCESS(), 0, 'EXIT_SUCCESS is 0');
	is(OpenHVF::VM::EXIT_ERROR(), 1, 'EXIT_ERROR is 1');
	is(OpenHVF::VM::EXIT_VM_RUNNING(), 5, 'EXIT_VM_RUNNING is 5');
	is(OpenHVF::VM::EXIT_VM_NOT_RUNNING(), 6, 'EXIT_VM_NOT_RUNNING is 6');
	is(OpenHVF::VM::EXIT_TIMEOUT(), 7, 'EXIT_TIMEOUT is 7');
}

# Accelerator selection
{
	# --emulate always forces TCG with a named CPU model
	my $emulated = OpenHVF::VM->new(emulate => 1);
	my %args = ($emulated->_accel_args);
	is($args{'-accel'}, 'tcg', '--emulate forces TCG');
	is($args{'-cpu'}, OpenHVF::VM::TCG_CPU(),
	    'TCG uses a named CPU model, not host passthrough');

	# Auto-selection returns a consistent accel/cpu pair
	my $auto = OpenHVF::VM->new;
	%args = ($auto->_accel_args);
	like($args{'-accel'}, qr/^(hvf|kvm|tcg)$/, 'known accelerator');
	if ($args{'-accel'} eq 'tcg') {
		is($args{'-cpu'}, OpenHVF::VM::TCG_CPU(),
		    'software emulation pairs with a named CPU');
	} else {
		is($args{'-cpu'}, 'host',
		    'hardware acceleration pairs with host CPU');
	}

	# Host arch helper returns a non-empty machine string
	ok(length(OpenHVF::VM::_host_arch()), 'host arch detected');
}

done_testing();
