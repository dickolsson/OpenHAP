# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2024 Dick Olsson <hi@senzilla.io>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use v5.36;

package OpenHVF::CLI;

use Getopt::Long qw(:config require_order bundling);
use File::Basename;

use FuguLib::Log;
use OpenHVF::Config;
use OpenHVF::State;
use OpenHVF::Image;
use OpenHVF::ImageCache;
use OpenHVF::Proxy::Cache;
use OpenHVF::Disk;
use OpenHVF::VM;
use OpenHVF::SSH;
use OpenHVF::Expect;

use constant {
	EXIT_SUCCESS         => 0,
	EXIT_ERROR           => 1,
	EXIT_INVALID_ARGS    => 2,
	EXIT_CONFIG_ERROR    => 3,
	EXIT_VM_NOT_FOUND    => 4,
	EXIT_VM_RUNNING      => 5,
	EXIT_VM_NOT_RUNNING  => 6,
	EXIT_TIMEOUT         => 7,
	EXIT_SSH_FAILED      => 8,
	EXIT_EXPECT_FAILED   => 9,
	EXIT_DOWNLOAD_FAILED => 10,

	# Scriptable: lets 'snapshot restore || provision-from-scratch'
	# tell a missing layer from a real failure
	EXIT_SNAPSHOT_NOT_FOUND => 11,
};

my %commands = (
	'up'       => \&cmd_up,
	'down'     => \&cmd_down,
	'destroy'  => \&cmd_destroy,
	'status'   => \&cmd_status,
	'start'    => \&cmd_start,
	'stop'     => \&cmd_stop,
	'ssh'      => \&cmd_ssh,
	'console'  => \&cmd_console,
	'expect'   => \&cmd_expect,
	'wait'     => \&cmd_wait,
	'image'    => \&cmd_image,
	'cache'    => \&cmd_cache,
	'snapshot' => \&cmd_snapshot,
	'disk'     => \&cmd_disk,
	'init'     => \&cmd_init,
	'help'     => \&cmd_help,
);

sub new ( $class, %opts )
{
	my $mode =
	    $opts{quiet} ? FuguLib::Log::MODE_QUIET : FuguLib::Log::MODE_STDERR;
	my $log = FuguLib::Log->new(
		mode  => $mode,
		level => 'info',
		ident => 'openhvf',
	);

	my $self = bless {
		vm_name => $opts{vm} // 'default',
		project => $opts{project},
		quiet   => $opts{quiet}   // 0,
		emulate => $opts{emulate} // 0,
		log     => $log,
	}, $class;

	return $self;
}

sub run ( $class, @argv )
{
	my %opts;
	my $parser = Getopt::Long::Parser->new;
	$parser->configure( 'require_order', 'bundling' );

	$parser->getoptionsfromarray(
		\@argv,
		'vm=s'      => \$opts{vm},
		'project=s' => \$opts{project},
		'quiet|q'   => \$opts{quiet},
		'verbose|v' => \$opts{verbose},
		'emulate'   => \$opts{emulate},
		'help|h'    => \$opts{help},
	) or return EXIT_INVALID_ARGS;

	if ( $opts{help} && !@argv ) {
		return cmd_help($class);
	}

	my $command = shift @argv // 'help';

	if ( !exists $commands{$command} ) {
		warn "openhvf: unknown command: $command\n";
		return EXIT_INVALID_ARGS;
	}

	my $self = $class->new(%opts);

	# Load config if not init command
	if ( $command ne 'init' && $command ne 'help' ) {
		my $project_root = $opts{project}
		    // OpenHVF::Config->find_project_root;
		if ( !defined $project_root ) {
			$self->{log}->error(
"Not in an OpenHVF project. Run 'openhvf init' first."
			);
			return EXIT_CONFIG_ERROR;
		}

		# Validate project path exists
		if ( !-d $project_root ) {
			$self->{log}->error(
				"Project path does not exist: $project_root");
			return EXIT_CONFIG_ERROR;
		}
		$self->{config} = OpenHVF::Config->new($project_root);
		$self->{state} =
		    OpenHVF::State->new( $self->{config}->state_dir,
			$self->{vm_name} );
		if ( !defined $self->{state} ) {
			$self->{log}->error(
"Cannot initialize state for VM '$self->{vm_name}'"
			);
			return EXIT_ERROR;
		}
	}

	return $commands{$command}->( $self, @argv );
}

sub _load_vm ( $self, %opts )
{
	my $vm_config = $self->{config}->load_vm( $self->{vm_name} );
	if ( !defined $vm_config ) {
		$self->{log}->error("VM '$self->{vm_name}' not found");
		return;
	}

	return OpenHVF::VM->new(
		config   => $vm_config,
		state    => $self->{state},
		log      => $self->{log},
		emulate  => $self->{emulate},
		no_cache => $opts{no_cache} // 0,
	);
}

# Idempotent: ensure VM is running
sub cmd_up ( $self, @args )
{
	my $no_cache = 0;
	my $parser   = Getopt::Long::Parser->new;
	$parser->configure('bundling');
	$parser->getoptionsfromarray( \@args, 'no-cache' => \$no_cache )
	    or return EXIT_INVALID_ARGS;

	my $vm = $self->_load_vm( no_cache => $no_cache )
	    or return EXIT_VM_NOT_FOUND;
	return $vm->up;
}

# Stop VM gracefully
sub cmd_down ( $self, @args )
{
	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	return $vm->down;
}

# Stop VM and delete disk image
sub cmd_destroy ( $self, @args )
{
	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	return $vm->destroy;
}

# Show VM status
sub cmd_status ( $self, @args )
{
	my $vm     = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	my $status = $vm->status;

	# Format and log status data
	for my $key ( sort keys %$status ) {
		my $value = $status->{$key} // '';
		$self->{log}->info("$key: $value");
	}

	return EXIT_SUCCESS;
}

# Start VM in background
sub cmd_start ( $self, @args )
{
	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	return $vm->start;
}

# Stop VM
sub cmd_stop ( $self, @args )
{
	my $force  = 0;
	my $parser = Getopt::Long::Parser->new;
	$parser->configure('bundling');
	$parser->getoptionsfromarray( \@args, 'force|f' => \$force, )
	    or return EXIT_INVALID_ARGS;

	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	return $vm->stop($force);
}

# SSH into VM or run command
sub cmd_ssh ( $self, @args )
{
	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;

	# Uses SSH agent for authentication. Connect over IPv4: QEMU
	# forwards the guest SSH port on 127.0.0.1 only, but 'localhost'
	# resolves to ::1 first on dual-stack hosts (e.g. CI runners).
	my $ssh = OpenHVF::SSH->new(
		host => '127.0.0.1',
		port => $vm->ssh_port,
		user => 'root',
	);

	if (@args) {
		my $result = $ssh->run_command( join( ' ', @args ) );
		print $result->{stdout}        if $result->{stdout};
		print STDERR $result->{stderr} if $result->{stderr};
		return $result->{exit_code};
	}
	else {
		return $ssh->interactive;
	}
}

# Show console connection info
sub cmd_console ( $self, @args )
{
	my $vm   = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	my $port = $vm->console_port;
	$self->{log}->info("Connect with: telnet localhost $port");
	$self->{log}->info("type: telnet");
	$self->{log}->info("host: localhost");
	$self->{log}->info("port: $port");
	return EXIT_SUCCESS;
}

# Run expect script
sub cmd_expect ( $self, @args )
{
	my $script = shift @args;
	if ( !defined $script ) {
		$self->{log}->error("Usage: openhvf expect <script> [args...]");
		return EXIT_INVALID_ARGS;
	}

	my $vm     = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	my $expect = OpenHVF::Expect->new(
		host => 'localhost',
		port => $vm->console_port,
	);

	my $result = $expect->run_script( $script, @args );
	return $result ? EXIT_SUCCESS : EXIT_EXPECT_FAILED;
}

# Wait for SSH to become available
sub cmd_wait ( $self, @args )
{
	my $timeout = 120;
	my $parser  = Getopt::Long::Parser->new;
	$parser->configure('bundling');
	$parser->getoptionsfromarray( \@args, 'timeout=s' => \$timeout, )
	    or return EXIT_INVALID_ARGS;

	# Validate timeout is a positive integer
	if ( $timeout !~ /^\d+$/ ) {
		$self->{log}->error("Invalid timeout value: $timeout");
		return EXIT_INVALID_ARGS;
	}
	$timeout = int($timeout);
	if ( $timeout <= 0 ) {
		$self->{log}->error("Timeout must be a positive number");
		return EXIT_INVALID_ARGS;
	}

	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;

	if ( !$vm->wait_ssh($timeout) ) {
		$self->{log}->error("Timeout waiting for SSH");
		return EXIT_TIMEOUT;
	}

	$self->{log}->info("VM ready");
	return EXIT_SUCCESS;
}

# Image management
sub cmd_image ( $self, @args )
{
	my $action = shift @args;
	if ( !defined $action || $action !~ /^(download|list)$/ ) {
		$self->{log}->error("Usage: openhvf image <download|list>");
		return EXIT_INVALID_ARGS;
	}

	my $cache_dir = $self->{config}->cache_dir;

	my $image = OpenHVF::Image->new($cache_dir);

	if ( $action eq 'list' ) {
		my $images = $image->list;
		if ( ref $images eq 'ARRAY' && @$images ) {
			for my $img (@$images) {
				$self->{log}->info("  - $img");
			}
		}
		else {
			$self->{log}->info("No cached images");
		}
		return EXIT_SUCCESS;
	}

	# 'download' action - show URL for manual download
	# Images are cached by the proxy when VM boots
	my $version = shift @args // '7.8';
	my $path    = $image->path($version);

	if ( defined $path ) {
		$self->{log}->info("Cached: $path");
	}
	else {
		my $url = $image->url($version);
		$self->{log}->info("Image not cached. URL: $url");
		$self->{log}->info("Run 'openhvf up' to download via proxy.");
	}
	return EXIT_SUCCESS;
}

# Installed-image cache management
sub cmd_cache ( $self, @args )
{
	my $action = shift @args;
	if ( !defined $action || $action !~ /^(list|clear)$/ ) {
		$self->{log}
		    ->error("Usage: openhvf cache <list|clear [--stale]>");
		return EXIT_INVALID_ARGS;
	}

	my $cache = OpenHVF::ImageCache->new( $self->{config}->cache_dir );

	return $self->_cache_list($cache) if $action eq 'list';
	return $self->_cache_clear( $cache, @args );
}

# $self->_cache_list($cache):
#	One line per cached entry, marking the one the invoked VM's
#	configuration currently derives, then what the proxy holds.
sub _cache_list ( $self, $cache )
{
	my $entries = $cache->list;
	if ( !@$entries ) {
		$self->{log}->info("No cached images");
		return $self->_proxy_list;
	}

	my $current = $self->_current_cache_key($cache);

	for my $entry (@$entries) {
		my $created =
		    defined $entry->{created_at}
		    ? scalar localtime $entry->{created_at}
		    : 'unknown';
		my $marker = defined $current
		    && $entry->{key} eq $current ? ' (current)' : '';

		$self->{log}->info(
			sprintf(
				'  - %s  %s  %s  snapshots: %d%s',
				$entry->{key},
				_format_size( $entry->{size} ),
				$created,
				scalar @{ $entry->{snapshots} },
				$marker
			) );
	}

	return $self->_proxy_list;
}

# $self->_proxy_list:
#	What the proxy's download cache holds, one line per OpenBSD
#	version. Reported by 'cache list' because it shares cache_dir with
#	the images and is pruned by the same 'cache clear': a half of the
#	directory that nothing printed was a half nobody knew to bound.
sub _proxy_list ($self)
{
	my $cache = OpenHVF::Proxy::Cache->new( $self->{config}->cache_dir );
	my $files = $cache->list;

	if ( !@$files ) {
		$self->{log}->info('No proxy downloads');
		return EXIT_SUCCESS;
	}

	# Per version, since that is the granularity 'clear --stale'
	# prunes at. A URL naming no version - nothing is_cacheable()
	# admits today - is counted under '-' rather than dropped, so an
	# unprunable entry is still visible as one.
	my %bytes;
	for my $file (@$files) {
		my ($version) =
		    $file->{url} =~ m{/pub/OpenBSD/(?:syspatch/)?([0-9.]+)/};
		$bytes{ $version // '-' } += $file->{size};
	}

	$self->{log}->info(
		sprintf 'Proxy downloads (%s):',
		_format_size( $cache->size ) );

	for my $version ( sort keys %bytes ) {
		$self->{log}->info( sprintf '  - OpenBSD %s  %s',
			$version, _format_size( $bytes{$version} ) );
	}

	return EXIT_SUCCESS;
}

# $self->_cache_clear($cache, @args):
#	Remove cached entries. Bare 'clear' removes them all; --stale
#	keeps the one the VM named by --vm derives. Because the key inputs
#	'version' and 'disk_size' are per-VM, --stale run for one VM does
#	prune bases another VM would have hit.
sub _cache_clear ( $self, $cache, @args )
{
	my $stale  = 0;
	my $parser = Getopt::Long::Parser->new;
	$parser->configure('bundling');
	$parser->getoptionsfromarray( \@args, 'stale' => \$stale )
	    or return EXIT_INVALID_ARGS;

	# Interrupted stores leave partial trees behind whichever form ran
	my $swept = $cache->sweep_temp;
	$self->{log}->info("Removed $swept incomplete cache entries")
	    if $swept;

	my $keep = $stale ? $self->_current_cache_key($cache) : undef;
	if ( $stale && !defined $keep ) {
		$self->{log}->error(
"Cannot determine the current cache key; refusing to prune"
		);
		return EXIT_ERROR;
	}

	my $removed = 0;
	for my $entry ( @{ $cache->list } ) {
		next if defined $keep && $entry->{key} eq $keep;

		my $users   = $self->_disks_backed_by( $entry->{dir} );
		my @running = grep { $_->{running} } @$users;
		if (@running) {
			$self->{log}->error(
				sprintf(
"Cannot remove %s: VM '%s' is running on it",
					$entry->{key}, $running[0]{vm} ) );
			return EXIT_VM_RUNNING;
		}

		# A stopped disk can be rebuilt with 'openhvf destroy', so
		# this is a warning. It cannot cover checkouts other than
		# this one, which share cache_dir but not state_dir.
		for my $user (@$users) {
			$self->{log}->warning(
				sprintf(
"Removing %s orphans the disk of VM '%s'; run 'openhvf destroy' for it",
					$entry->{key}, $user->{vm} ) );
		}

		if ( !$cache->remove( $entry->{key} ) ) {
			return EXIT_ERROR;
		}
		$self->{log}->info("Removed $entry->{key}");
		$removed++;
	}

	$self->{log}->info(
		$removed
		? "Removed $removed cached images"
		: "No cached images removed"
	);

	return $self->_proxy_clear($stale);
}

# $self->_proxy_clear($stale):
#	The other half of cache_dir: the proxy's download cache. Bare
#	'clear' empties it, --stale keeps the OpenBSD version the invoked
#	VM installs - the same one-VM scope the image prune above has.
#
#	Not reachable from the image loop, which is why this is a second
#	pass rather than a branch inside it: the two caches share nothing
#	but cache_dir, and the images have running-VM and orphaned-disk
#	checks that a re-downloadable file set does not need.
sub _proxy_clear ( $self, $stale )
{
	my $cache = OpenHVF::Proxy::Cache->new( $self->{config}->cache_dir );

	if ( !$stale ) {
		my $size = $cache->size;
		if ( !$cache->clear ) {
			$self->{log}->error("Cannot clear proxy downloads");
			return EXIT_ERROR;
		}
		$self->{log}->info( sprintf 'Removed %s of proxy downloads',
			_format_size($size) );

		return EXIT_SUCCESS;
	}

	# --stale got this far, so the VM resolves; keeping its version is
	# the point of the flag.
	my $vm      = $self->{config}->load_vm( $self->{vm_name} );
	my $removed = $cache->prune( $vm->{version} );

	for my $entry (@$removed) {
		$self->{log}->info(
			sprintf 'Removed %s of downloads for OpenBSD %s',
			_format_size( $entry->{size} ),
			$entry->{version} );
	}
	$self->{log}->info('No proxy downloads removed') if !@$removed;

	return EXIT_SUCCESS;
}

# $self->_current_cache_key($cache):
#	The key the invoked VM's configuration derives, or undef when the
#	VM or one of the key inputs cannot be resolved.
sub _current_cache_key ( $self, $cache )
{
	my $vm_config = $self->{config}->load_vm( $self->{vm_name} );
	return if !defined $vm_config;

	return $cache->key($vm_config);
}

# $self->_disks_backed_by($entry_dir):
#	Every VM in this checkout whose working disk hangs off an image in
#	$entry_dir, as [ { vm => name, running => bool } ]. Enumerated
#	from the state directory rather than the configuration, so a disk
#	counts whether or not a 'vm' block still declares it.
sub _disks_backed_by ( $self, $entry_dir )
{
	my $state_dir = $self->{config}->state_dir;
	return [] if !-d $state_dir;

	opendir my $dh, $state_dir or return [];
	my @names =
	    sort grep { !/^\./ && -f "$state_dir/$_/disk.qcow2" } readdir $dh;
	closedir $dh;

	my $disk = OpenHVF::Disk->new($state_dir);
	my @users;

	for my $name (@names) {
		my $backing = $disk->backing_file($name);
		next if !defined $backing;
		next if index( $backing, "$entry_dir/" ) != 0;

		my $state = OpenHVF::State->new( $state_dir, $name );
		push @users,
		    {
			vm      => $name,
			running => $state && $state->is_vm_running ? 1 : 0,
		    };
	}

	return \@users;
}

sub _format_size ( $bytes = undef )
{
	return '?' if !defined $bytes;

	my @units = ( 'B', 'K', 'M', 'G', 'T' );
	my $size  = $bytes;
	my $unit  = 0;

	while ( $size >= 1024 && $unit < $#units ) {
		$size /= 1024;
		$unit++;
	}

	return $unit == 0
	    ? sprintf( '%d%s',   $size, $units[$unit] )
	    : sprintf( '%.1f%s', $size, $units[$unit] );
}

# Named snapshot layers over a cached base image
sub cmd_snapshot ( $self, @args )
{
	my $action = shift @args;
	if ( !defined $action || $action !~ /^(save|restore|list|rm)$/ ) {
		$self->{log}->error(
"Usage: openhvf snapshot <save|restore|rm> <name> | list [--names]"
		);
		return EXIT_INVALID_ARGS;
	}

	my $cache = OpenHVF::ImageCache->new( $self->{config}->cache_dir );

	return $self->_snapshot_list( $cache, @args ) if $action eq 'list';

	my $name = shift @args;
	if ( !$cache->valid_snapshot_name($name) ) {
		$self->{log}->error(
			"Invalid snapshot name: " . ( $name // '(missing)' ) );
		return EXIT_INVALID_ARGS;
	}

	return $self->_snapshot_save( $cache, $name ) if $action eq 'save';
	return $self->_snapshot_restore( $cache, $name )
	    if $action eq 'restore';
	return $self->_snapshot_remove( $cache, $name );
}

# $self->_snapshot_save($cache, $name):
#	Flatten the stopped working disk into the cache under the base it
#	was built on. A live overlay is not consistent, so a running VM is
#	refused rather than copied.
sub _snapshot_save ( $self, $cache, $name )
{
	my $vm = $self->_load_vm or return EXIT_VM_NOT_FOUND;

	if ( $vm->is_running ) {
		$self->{log}->error("Stop the VM before saving a snapshot");
		return EXIT_VM_RUNNING;
	}

	if ( !$self->{state}->disk_exists ) {
		$self->{log}->error("No disk image. Run 'openhvf up' first.");
		return EXIT_ERROR;
	}

	if ( !$self->{state}->is_installed ) {
		$self->{log}->error("VM is not installed yet");
		return EXIT_ERROR;
	}

	# The snapshot belongs under whichever base the disk actually
	# hangs off, directly or through another snapshot - re-saving
	# after a restore is normal.
	my $key = $self->_disk_cache_key($cache);
	if ( !defined $key ) {
		$self->{log}->error(
"This disk is not built on a cached image, so it cannot be snapshotted."
		);
		$self->{log}->error(
"It was created with --no-cache or 'image_cache no'; recreate it with 'openhvf destroy' and 'openhvf up'."
		);
		return EXIT_ERROR;
	}

	$self->{log}->info("Saving snapshot '$name' of $key...");

	my $state = $self->{state};
	my $path  = $cache->snapshot_store(
		$key, $name,
		$state->disk_path,
		{
			installed            => 1,
			installed_ssh_pubkey =>
			    $state->get_installed_ssh_pubkey,
		} );
	if ( !defined $path ) {
		$self->{log}->error("Failed to save snapshot '$name'");
		return EXIT_ERROR;
	}

	$self->{log}->info("Saved snapshot '$name': $path");
	return EXIT_SUCCESS;
}

# $self->_snapshot_restore($cache, $name):
#	Replace the working disk with a fresh overlay on a snapshot and
#	reseed the state that disk embodies. Works from nothing - no disk,
#	no state - so a fresh checkout can restore before its first 'up'.
sub _snapshot_restore ( $self, $cache, $name )
{
	my $vm    = $self->_load_vm or return EXIT_VM_NOT_FOUND;
	my $state = $self->{state};

	if ( $vm->is_running ) {
		$self->{log}->error("Stop the VM before restoring a snapshot");
		return EXIT_VM_RUNNING;
	}

	my $key = $self->_current_cache_key($cache);
	if ( !defined $key ) {
		$self->{log}->error("Cannot determine the current cache key");
		return EXIT_ERROR;
	}

	my $found = $cache->snapshot_lookup( $key, $name );
	if ( !defined $found ) {
		$self->{log}->error("No snapshot '$name' for $key");
		return EXIT_SNAPSHOT_NOT_FOUND;
	}

	# Disk::create returns early on an existing path, so without this
	# a restore would report success and change nothing.
	my $disk_path = $state->disk_path;
	if ( -f $disk_path ) {
		unlink $disk_path or do {
			$self->{log}->error("Cannot remove $disk_path: $!");
			return EXIT_ERROR;
		};
	}

	my $vm_config = $self->{config}->load_vm( $self->{vm_name} );
	my $disk      = OpenHVF::Disk->new( $self->{config}->state_dir );
	my $created =
	    $disk->create( $vm_config->{name}, undef, $found->{path}, 'qcow2' );
	if ( !defined $created ) {
		$self->{log}->error("Failed to overlay snapshot '$name'");
		return EXIT_ERROR;
	}

	# Reseed what the disk embodies. A checkout whose SSH key differs
	# from the saved one is reconciled by the next 'openhvf up'.
	my $meta = $found->{meta};
	$state->mark_installed;
	$state->set_root_password( $meta->{root_password} )
	    if defined $meta->{root_password};
	$state->mark_ssh_key_installed( $meta->{installed_ssh_pubkey} )
	    if defined $meta->{installed_ssh_pubkey};
	$state->{data}{cached_from} = "$key/$name";
	$state->save;

	$self->{log}->info("Restored snapshot '$name' of $key");
	return EXIT_SUCCESS;
}

sub _snapshot_list ( $self, $cache, @args )
{
	my $names  = 0;
	my $parser = Getopt::Long::Parser->new;
	$parser->configure('bundling');
	$parser->getoptionsfromarray( \@args, 'names' => \$names )
	    or return EXIT_INVALID_ARGS;

	my $key = $self->_current_cache_key($cache);
	if ( !defined $key ) {
		$self->{log}->error("Cannot determine the current cache key");
		return EXIT_ERROR;
	}

	my $snapshots = $cache->snapshot_list($key);

	# --names writes bare names to stdout, where a shell can read
	# them. The human listing goes through the logger, which writes
	# to stderr and prefixes every line.
	if ($names) {
		say $_->{name} for @$snapshots;
		return EXIT_SUCCESS;
	}

	if ( !@$snapshots ) {
		$self->{log}->info("No snapshots for $key");
		return EXIT_SUCCESS;
	}

	for my $snapshot (@$snapshots) {
		my $created =
		    defined $snapshot->{created_at}
		    ? scalar localtime $snapshot->{created_at}
		    : 'unknown';
		$self->{log}->info(
			sprintf( '  - %s  %s  %s',
				$snapshot->{name},
				_format_size( $snapshot->{size} ),
				$created ) );
	}

	return EXIT_SUCCESS;
}

sub _snapshot_remove ( $self, $cache, $name )
{
	my $key = $self->_current_cache_key($cache);
	if ( !defined $key ) {
		$self->{log}->error("Cannot determine the current cache key");
		return EXIT_ERROR;
	}

	if ( !defined $cache->snapshot_lookup( $key, $name ) ) {
		$self->{log}->error("No snapshot '$name' for $key");
		return EXIT_SNAPSHOT_NOT_FOUND;
	}

	if ( !$cache->snapshot_remove( $key, $name ) ) {
		return EXIT_ERROR;
	}

	$self->{log}->info("Removed snapshot '$name'");
	return EXIT_SUCCESS;
}

# $self->_disk_cache_key($cache):
#	The cache entry the working disk is built on, whether directly on
#	its base image or through a snapshot of it.
sub _disk_cache_key ( $self, $cache )
{
	my $vm_config = $self->{config}->load_vm( $self->{vm_name} );
	return if !defined $vm_config;

	# Scalar context: backing_file returns an empty list for a
	# standalone disk, which would reach key_for_path as no argument
	# at all rather than as undef.
	my $disk    = OpenHVF::Disk->new( $self->{config}->state_dir );
	my $backing = $disk->backing_file( $vm_config->{name} );

	return $cache->key_for_path($backing);
}

# Disk management
sub cmd_disk ( $self, @args )
{
	my $action = shift @args;
	if ( !defined $action || $action !~ /^(check|repair|info)$/ ) {
		$self->{log}->error("Usage: openhvf disk <check|repair|info>");
		return EXIT_INVALID_ARGS;
	}

	my $disk = OpenHVF::Disk->new( $self->{state}{state_dir} );

	if ( $action eq 'info' ) {
		my $info = $disk->info( $self->{vm_name} );
		if ( !defined $info ) {
			$self->{log}->error("Disk not found");
			return EXIT_ERROR;
		}

		# Print info in a readable format
		for my $key ( sort keys %$info ) {
			$self->{log}->info("$key: $info->{$key}");
		}
		return EXIT_SUCCESS;
	}

	if ( $action eq 'check' ) {
		$self->{log}->info("Checking disk image...");
		my $result = $disk->check( $self->{vm_name} );
		if ( !defined $result ) {
			$self->{log}->error("Disk not found");
			return EXIT_ERROR;
		}

		if ( $result->{status} eq 'ok' ) {
			$self->{log}->info("Disk image OK");
			return EXIT_SUCCESS;
		}

		$self->{log}->error("Disk image has errors");
		print $result->{output} if $result->{output};
		return EXIT_ERROR;
	}

	if ( $action eq 'repair' ) {
		$self->{log}->info("Repairing disk image...");

		# Check if VM is running first
		my $vm = $self->_load_vm;
		if ( defined $vm && $vm->is_running ) {
			$self->{log}
			    ->error("Cannot repair disk while VM is running");
			return EXIT_ERROR;
		}

		my $ok = $disk->repair( $self->{vm_name} );
		if ($ok) {

			# Clear unclean shutdown state after successful repair
			$self->{state}->clear_shutdown_state;
			$self->{log}->info("Disk repaired");
			return EXIT_SUCCESS;
		}

		$self->{log}->error("Disk repair failed");
		return EXIT_ERROR;
	}

	return EXIT_ERROR;
}

# Initialize project
sub cmd_init ( $self, @args )
{
	my $dir         = shift @args // '.';
	my $openhvf_dir = "$dir/.openhvf";
	my $config_file = "$dir/.openhvfrc";

	if ( -f $config_file ) {
		$self->{log}->info("OpenHVF already initialized in $dir");
		return EXIT_SUCCESS;
	}

	# Check if directory is writable
	if ( !-d $dir ) {
		$self->{log}->error("Directory does not exist: $dir");
		return EXIT_ERROR;
	}
	if ( !-w $dir ) {
		$self->{log}->error("Cannot write to directory: $dir");
		return EXIT_ERROR;
	}

	require File::Path;
	eval {
		File::Path::make_path( "$openhvf_dir/vms",
			"$openhvf_dir/state" );
	};
	if ($@) {
		my $err = $@;
		$err =~ s/ at \S+ line \d+.*//s;
		$self->{log}->error("Cannot create directory: $err");
		return EXIT_ERROR;
	}

	# Create project config
	_write_file( $config_file, <<'EOF' );
# OpenHVF project configuration

cache_dir = ~/.cache/openhvf
state_dir = .openhvf/state
default_vm = default
EOF

	# Create default VM config
	_write_file( "$openhvf_dir/vms/default.conf", <<"EOF" );
# Default OpenBSD VM

name = openbsd-default
version = 7.8
memory = 2048
disk_size = 8G

ssh_port = 2222
console_port = 4444
EOF

	# Create .gitignore
	_write_file( "$openhvf_dir/.gitignore", <<'EOF' );
state/
*.log
EOF

	$self->{log}->info("Initialized OpenHVF in $dir");
	return EXIT_SUCCESS;
}

sub cmd_help ( $, @ )
{
	print <<'EOF';
Usage: openhvf [--vm <name>] <command> [options]

Commands:
  up [--no-cache]     Ensure VM is running (download, create, start)
  down                Stop VM gracefully
  destroy             Stop VM and delete disk image
  status              Show VM status
  start               Start VM in background
  stop [--force]      Stop VM
  ssh [command]       Open SSH session or run command
  console             Show console connection info
  expect <script>     Run expect script against console
  wait [--timeout=N]  Wait for VM to be ready (SSH available)
  image <cmd>         Manage images (download, list)
  cache <cmd>         Manage installed images (list, clear [--stale])
  snapshot <cmd>      Manage snapshots (save, restore, rm <name>;
                      list [--names])
  disk <cmd>          Manage disk (check, repair, info)
  init [dir]          Initialize .openhvf/ directory
  help                Show this help

Global Options:
  --vm <name>     VM to operate on (default: "default")
  --project <dir> Project root (default: auto-discover)
  --quiet, -q     Suppress informational output
  --emulate       Force TCG emulation instead of hardware acceleration
  --help, -h      Show help

Examples:
  openhvf init
  openhvf up
  openhvf ssh "uname -a"
  openhvf wait --timeout=300
  openhvf --vm minimal up
EOF
	return EXIT_SUCCESS;
}

sub _write_file ( $path, $content )
{
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}

1;
