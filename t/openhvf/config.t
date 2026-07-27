#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use_ok('OpenHVF::Config');

# Test constants
is(OpenHVF::Config::DEFAULT_MEMORY(), 2048, 'DEFAULT_MEMORY is 2048');
is(OpenHVF::Config::DEFAULT_SSH_PORT(), 2222, 'DEFAULT_SSH_PORT is 2222');
is(OpenHVF::Config::DEFAULT_VERSION(), '7.8', 'DEFAULT_VERSION is 7.8');

# Test find_project_root returns undef when not in project
{
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir;
    my $root = OpenHVF::Config->find_project_root;
    is($root, undef, 'find_project_root returns undef outside project');
}

# Test find_project_root finds .openhvfrc file
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    # Create .openhvfrc at project root
    open my $fh, '>', "$tmpdir/.openhvfrc";
    close $fh;
    chdir $tmpdir;
    my $root = OpenHVF::Config->find_project_root;
    # Resolve symlinks for comparison (macOS /var -> /private/var)
    use Cwd qw(realpath);
    my $expected = realpath($tmpdir);
    my $actual = realpath($root);
    is($actual, $expected, 'find_project_root finds project root');
}

# Test config parsing
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # Create config file at project root
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "cache_dir /tmp/test\n";
    print $fh "default_vm test\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->default_vm, 'test', 'default_vm parsed correctly');
}

# Test VM config loading from block in .openhvfrc
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # Create project config with VM block
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "default_vm test\n";
    print $fh "\n";
    print $fh "vm \"test\" {\n";
    print $fh "    memory 4096\n";
    print $fh "    ssh_port 3333\n";
    print $fh "}\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('test');
    
    ok(defined $vm, 'VM config loaded from block');
    is($vm->{name}, 'test', 'VM name set from block name');
    is($vm->{memory}, 4096, 'VM memory parsed');
    is($vm->{ssh_port}, 3333, 'VM ssh_port parsed');
    is($vm->{version}, '7.8', 'VM version has default');
}

# Test VM config loading from separate file (backwards compatibility)
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # Create separate VM config file
    open my $fh, '>', "$tmpdir/.openhvf/vms/legacy.conf";
    print $fh "name legacy-vm\n";
    print $fh "memory 2048\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('legacy');
    
    ok(defined $vm, 'VM config loaded from separate file');
    is($vm->{name}, 'legacy-vm', 'VM name parsed from file');
    is($vm->{memory}, 2048, 'VM memory parsed from file');
}

# Test load_vm returns undef for missing VM
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");

    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('nonexistent');
    is($vm, undef, 'load_vm returns undef for missing VM');
}

# The resolved cache_dir reaches the per-VM config, so `openhvf up`
# writes its image cache where the cache subcommands look for it
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");

    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "cache_dir /var/cache/openhvf\n";
    print $fh "vm \"test\" {\n";
    print $fh "    memory 4096\n";
    print $fh "}\n";
    close $fh;

    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('test');

    is($vm->{cache_dir}, '/var/cache/openhvf',
	'load_vm injects the configured cache_dir');
    is($vm->{cache_dir}, $config->cache_dir,
	'and it is the same value cache_dir reports');
}

# A VM without any cache_dir configured still gets the default
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $homedir = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $homedir;
    make_path("$tmpdir/.openhvf/vms");

    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "vm test {\n}\n";
    close $fh;

    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('test');

    is($vm->{cache_dir}, "$homedir/.cache/openhvf",
	'default cache_dir is injected and tilde-expanded');
}

# Test ssh_pubkey from project config
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # Create config with ssh_pubkey at project root
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "ssh_pubkey ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test\@example\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    like($config->ssh_pubkey, qr/^ssh-ed25519/, 'ssh_pubkey parsed from project config');
}

# Test ssh_pubkey from global config fallback
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $homedir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # No ssh_pubkey in project config
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "default_vm test\n";
    close $fh;
    
    # Create global config with ssh_pubkey
    open my $gh, '>', "$homedir/.openhvfrc";
    print $gh "ssh_pubkey ssh-rsa AAAAB3NzaC1 global\@test\n";
    close $gh;
    
    local $ENV{HOME} = $homedir;
    my $config = OpenHVF::Config->new($tmpdir);
    like($config->ssh_pubkey, qr/^ssh-rsa/, 'ssh_pubkey falls back to global config');
}

# Test ssh_pubkey included in VM config
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "ssh_pubkey ssh-ed25519 TESTKEY test\@vm\n";
    print $fh "\n";
    print $fh "vm \"test\" {\n";
    print $fh "    memory 2048\n";
    print $fh "}\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('test');
    is($vm->{ssh_pubkey}, 'ssh-ed25519 TESTKEY test@vm', 'ssh_pubkey included in VM config');
}

# Test project config overrides global config
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $homedir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # Global config
    open my $gh, '>', "$homedir/.openhvfrc";
    print $gh "default_vm global-vm\n";
    print $gh "cache_dir /global/cache\n";
    print $gh "ssh_pubkey ssh-rsa GLOBAL global\@test\n";
    close $gh;
    
    # Project config overrides some values
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "default_vm project-vm\n";
    close $fh;
    
    local $ENV{HOME} = $homedir;
    my $config = OpenHVF::Config->new($tmpdir);
    
    is($config->default_vm, 'project-vm', 'project config overrides global default_vm');
    is($config->cache_dir, '/global/cache', 'global cache_dir used when not in project');
    like($config->ssh_pubkey, qr/^ssh-rsa GLOBAL/, 'global ssh_pubkey used when not in project');
}

# Test find_project_root walks up directory tree
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/subdir/deep/nested");
    
    # Create .openhvfrc at project root
    open my $fh, '>', "$tmpdir/.openhvfrc";
    close $fh;
    
    # Save cwd, change to nested directory
    use Cwd qw(getcwd realpath);
    my $orig_cwd = getcwd();
    chdir "$tmpdir/subdir/deep/nested";
    my $root = OpenHVF::Config->find_project_root;
    chdir $orig_cwd;  # Restore cwd before cleanup
    
    my $expected = realpath($tmpdir);
    my $actual = realpath($root);
    is($actual, $expected, 'find_project_root walks up directory tree');
}

# Test config with comments and whitespace
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "# This is a comment\n";
    print $fh "   \n";
    print $fh "default_vm test  # inline comment\n";
    print $fh "  cache_dir   /path/with/spaces   \n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->default_vm, 'test', 'inline comments stripped');
    is($config->cache_dir, '/path/with/spaces', 'whitespace trimmed');
}

# Test data_dir accessor
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->{data_dir}, "$tmpdir/.openhvf", 'data_dir set correctly');
}

# Test state_dir default
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->state_dir, "$tmpdir/.openhvf/state", 'state_dir defaults to .openhvf/state');
}

# Test state_dir from config
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "state_dir /custom/state\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->state_dir, '/custom/state', 'state_dir from config');
}

# Test cache_dir tilde expansion
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $homedir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "cache_dir ~/cache/openhvf\n";
    close $fh;
    
    local $ENV{HOME} = $homedir;
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->cache_dir, "$homedir/cache/openhvf", 'cache_dir expands tilde');
}

# Test VM block in global config
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $homedir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # VM defined in global config
    open my $gh, '>', "$homedir/.openhvfrc";
    print $gh "vm \"shared\" {\n";
    print $gh "    memory 1024\n";
    print $gh "    version 7.8\n";
    print $gh "}\n";
    close $gh;
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    close $fh;
    
    local $ENV{HOME} = $homedir;
    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('shared');
    
    ok(defined $vm, 'VM loaded from global config');
    is($vm->{memory}, 1024, 'VM memory from global config');
}

# Test project VM overrides global VM
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $homedir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    # VM in global config
    open my $gh, '>', "$homedir/.openhvfrc";
    print $gh "vm \"test\" {\n";
    print $gh "    memory 1024\n";
    print $gh "}\n";
    close $gh;
    
    # Same VM name in project config with different settings
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "vm \"test\" {\n";
    print $fh "    memory 4096\n";
    print $fh "}\n";
    close $fh;
    
    local $ENV{HOME} = $homedir;
    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('test');
    
    is($vm->{memory}, 4096, 'project VM config overrides global');
}

# Test project_root accessor
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    is($config->project_root, $tmpdir, 'project_root accessor');
}

# Test VM block with unquoted name
{
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/.openhvf/vms");
    
    open my $fh, '>', "$tmpdir/.openhvfrc";
    print $fh "vm simple {\n";
    print $fh "    memory 512\n";
    print $fh "    version 7.8\n";
    print $fh "}\n";
    close $fh;
    
    my $config = OpenHVF::Config->new($tmpdir);
    my $vm = $config->load_vm('simple');
    
    ok(defined $vm, 'VM with unquoted name loaded');
    is($vm->{memory}, 512, 'VM memory correct');
    is($vm->{name}, 'simple', 'VM name set from unquoted block name');
}

done_testing();
