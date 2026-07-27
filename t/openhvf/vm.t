#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);

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

# Bounded guest interaction: _bounded must return the code's value when
# it finishes in time and undef (without hanging) when it does not, so a
# wedged guest can never stall shutdown.
{
	my $vm = OpenHVF::VM->new;
	$vm->{log} = TestLog->new;    # swallow the timeout warning

	is($vm->_bounded(5, sub { return 'done' }), 'done',
	    '_bounded returns the code result when it finishes in time');

	my $start = time;
	my $ret = $vm->_bounded(1, sub { sleep 5; return 'late' });
	is($ret, undef, '_bounded returns undef when the deadline elapses');
	ok(time - $start < 4, '_bounded aborts near the deadline, not later');
	ok($vm->{log}{warned}, '_bounded warns on timeout');
}

# The image cache follows the configured cache_dir, which
# OpenHVF::Config::load_vm injects into the per-VM config.
{
	my $vm = OpenHVF::VM->new(config => { cache_dir => '/var/cache/hvf' });
	is($vm->_cache_dir, '/var/cache/hvf', 'configured cache_dir wins');
	is($vm->_image_cache->cache_dir, '/var/cache/hvf',
	    'the image cache uses it too');

	local $ENV{HOME} = '/home/nobody';
	my $bare = OpenHVF::VM->new(config => {});
	is($bare->_cache_dir, '/home/nobody/.cache/openhvf',
	    'a config without cache_dir falls back to the default');
}

# Switching the cache off suppresses restore and save together: `up`
# derives no key at all, so it can neither look one up nor publish one.
{
	my $off = OpenHVF::VM->new(
		config => { cache_dir => '/var/cache/hvf', image_cache => 0 });
	is($off->_image_cache, undef, 'image_cache no disables the cache');

	my $flag = OpenHVF::VM->new(
		config   => { cache_dir => '/var/cache/hvf' },
		no_cache => 1,
	);
	is($flag->_image_cache, undef, '--no-cache disables the cache');

	my $on = OpenHVF::VM->new(
		config => { cache_dir => '/var/cache/hvf', image_cache => 1 });
	ok(defined $on->_image_cache, 'image_cache yes leaves it enabled');
}

# Installed-image cache: restore, chain verification, and reparenting.
# These are the parts of `up` that do not need a running QEMU.
SKIP: {
	my $has_qemu = `which qemu-img 2>/dev/null`;
	skip 'qemu-img not installed', 14 unless $has_qemu;

	require OpenHVF::Disk;
	require OpenHVF::ImageCache;
	require OpenHVF::State;

	my $root = tempdir(CLEANUP => 1);
	my $cache = OpenHVF::ImageCache->new("$root/cache");
	my $key = '7.8-arm64-11223344';

	# A stand-in for a freshly installed disk
	my $installed = "$root/installed.qcow2";
	system('qemu-img', 'create', '-f', 'qcow2', $installed, '64M') == 0
	    or skip 'cannot create a test disk image', 14;
	my $base = $cache->store($key, $installed,
	    { root_password => 'from-the-image' });
	ok(defined $base, 'a base image is available to restore from');

	my $state = OpenHVF::State->new("$root/state", 'default');
	my $vm = OpenHVF::VM->new(
		config => { name => 'default', cache_dir => "$root/cache" },
		state  => $state,
		log    => TestLog->new,
	);

	# Restore: overlay plus the state the installation would have left
	ok($vm->_cache_restore($cache, $key), 'restore reports a cache hit');
	ok($state->disk_exists, 'the working disk exists after a restore');
	ok($state->is_installed, 'the restored VM is marked installed');
	is($state->get_root_password, 'from-the-image',
	    'the root password comes from the image, not a new install');
	is($state->{data}{cached_from}, $key,
	    'state records which cached image it came from');

	my $disk = OpenHVF::Disk->new("$root/state");
	is($disk->backing_file('default'), $base,
	    'the working disk is an overlay on the cached base');

	# A resolvable chain passes verification
	ok($vm->_verify_backing_chain, 'an intact backing chain verifies');

	# Reparenting a standalone disk onto a base
	my $other = OpenHVF::State->new("$root/state2", 'default');
	my $vm2 = OpenHVF::VM->new(
		config => { name => 'default', cache_dir => "$root/cache" },
		state  => $other,
		log    => TestLog->new,
	);
	OpenHVF::Disk->new("$root/state2")->create('default', '64M');
	ok($other->disk_exists, 'a standalone disk to reparent');
	ok($vm2->_reparent_disk($base), 'reparent succeeds');
	is(OpenHVF::Disk->new("$root/state2")->backing_file('default'), $base,
	    'the standalone disk became an overlay');
	ok(!-f $other->disk_path . '.replaced',
	    'no leftover copy of the replaced disk');

	# A missing base is a diagnosed failure, not silent corruption
	chmod 0700, $cache->entry_dir($key);
	unlink $base;
	my $log = TestLog->new;
	$vm->{log} = $log;
	ok(!$vm->_verify_backing_chain, 'a broken chain fails verification');
	like(join("\n", @{ $log->{errors} }), qr/openhvf destroy/,
	    'and the error names the remedy');

	# A restore against the now-empty cache is a miss, not a crash
	my $fresh = OpenHVF::State->new("$root/state3", 'default');
	my $vm3 = OpenHVF::VM->new(
		config => { name => 'default', cache_dir => "$root/cache" },
		state  => $fresh,
		log    => TestLog->new,
	);
	ok(!$vm3->_cache_restore($cache, $key),
	    'restore misses once the base is gone');
}

done_testing();

# Minimal log stub: counts warnings for _bounded and keeps errors so
# diagnostics can be asserted on
package TestLog;
sub new { return bless { warned => 0, errors => [] }, shift }
sub warning { my $self = shift; $self->{warned}++; return; }
sub info { return; }

sub error
{
	my ($self, $fmt, @args) = @_;
	push @{ $self->{errors} }, @args ? sprintf($fmt, @args) : $fmt;
	return;
}

sub debug { return; }
