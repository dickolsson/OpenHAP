# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2024 Author Name <email@example.org>
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

# OpenHVF::VM - OpenBSD VM management for macOS/arm64
#
# Opinionated VM controller for running OpenBSD guests on Apple Silicon.
# Uses QMP for reliable VM lifecycle management.

package OpenHVF::VM;

use File::Path  qw(make_path);
use POSIX       qw(setsid);
use Time::HiRes qw(usleep);

use OpenHVF::Image;
use OpenHVF::Disk;
use OpenHVF::SSH;
use OpenHVF::Expect;
use OpenHVF::Util;
use OpenHVF::QMP;
use OpenHVF::QGA;

use constant {
	EXIT_SUCCESS        => 0,
	EXIT_ERROR          => 1,
	EXIT_VM_RUNNING     => 5,
	EXIT_VM_NOT_RUNNING => 6,
	EXIT_TIMEOUT        => 7,

	# Fixed configuration for OpenBSD arm64 guests
	QEMU_BINARY    => 'qemu-system-aarch64',
	MEMORY_DEFAULT => '1G',
	CPU_COUNT      => 2,

	# Guest CPU model under TCG emulation (no host passthrough)
	TCG_CPU => 'cortex-a57',
};

sub new ( $class, %args )
{
	my $self = bless {
		config  => $args{config},
		state   => $args{state},
		log     => $args{log},
		emulate => $args{emulate} // 0,
	}, $class;

	return $self;
}

# Idempotent: ensure VM is running
sub up ($self)
{
	my $config = $self->{config};
	my $state  = $self->{state};
	my $log    = $self->{log};

	# Check if already running
	if ( $self->_is_running ) {

		# If VM is running but SSH key needs to be installed or updated
		# (first boot failed, or key changed in config)
		if ( $state->is_installed && $self->_needs_ssh_key_update ) {
			return $self->_complete_ssh_setup;
		}

		$log->info("VM '$config->{name}' is already running");
		return EXIT_SUCCESS;
	}

	# Check for unclean shutdown and verify disk integrity
	if ( $state->was_unclean_shutdown ) {
		$log->warning("Detected unclean shutdown, checking disk...");
		my $disk  = OpenHVF::Disk->new( $state->{state_dir} );
		my $check = $disk->check( $config->{name} );

		if ( defined $check && $check->{status} ne 'ok' ) {
			$log->error(
"Disk corruption detected. Run 'openhvf disk repair' to fix"
			);
			return EXIT_ERROR;
		}
		$state->clear_shutdown_state;
	}

	# Start caching proxy for VM installation (packages downloaded by VM)
	# Also used for downloading the miniroot image on first run
	my $cache_dir = $self->_cache_dir;
	my $proxy     = $state->ensure_proxy($cache_dir);
	my $proxy_vm_url;    # For VM-side downloads (inside OpenBSD)

	if ( defined $proxy ) {
		$proxy_vm_url = $proxy->guest_url;
		$log->info("Proxy started: $proxy_vm_url");
	}
	else {
		$log->info(
			"Proxy not available, VM downloads will not be cached");
	}

	# Ensure image is available (download via proxy if needed)
	$log->info("Checking OpenBSD image...");
	my $image      = OpenHVF::Image->new( $cache_dir, $proxy );
	my $image_path = $image->ensure( $config->{version} );

	if ( !defined $image_path ) {
		my $url = $image->url( $config->{version} );
		$log->error(
"Failed to download image for OpenBSD $config->{version}"
		);
		$log->error("URL: $url");
		$log->error("Try downloading manually: curl -fLO $url");
		return EXIT_ERROR;
	}
	else {
		$log->info("Using cached image: $image_path");
	}

	# Ensure disk exists
	my $disk_path = $state->disk_path;

	if ( !$state->disk_exists ) {
		$log->info("Creating disk image ($config->{disk_size})...");
		my $disk = OpenHVF::Disk->new( $state->{state_dir} );
		my $result =
		    $disk->create( $config->{name}, $config->{disk_size} );
		if ( !defined $result ) {
			$log->error("Failed to create disk");
			return EXIT_ERROR;
		}
	}

	# Start VM
	$log->info("Starting VM...");

	# Only attach install media if not already installed
	my $boot_image = $state->is_installed ? undef : $image_path;
	my $pid        = $self->_start_qemu($boot_image);
	if ( !defined $pid ) {
		$log->error("Failed to start VM");
		return EXIT_ERROR;
	}

	$log->info("Started $config->{name} (PID: $pid)");

	# Install if needed
	if ( !$state->is_installed ) {

      # Proxy is already running (started above for image download)
      # Use VM-accessible URL for installation (VM connects to host via gateway)
		my $install_proxy_url = $proxy_vm_url // 'none';

		# Generate a strong random password for this installation
		my $root_password = OpenHVF::Util->generate_password(32);
		$state->set_root_password($root_password);
		$log->info("Generated secure root password");

		$log->info("Installing OpenBSD...");
		my $expect = OpenHVF::Expect->new(
			host => '127.0.0.1',
			port => $config->{console_port},
		);

		# Use the generated password for installation
		my $install_config = {
			%$config,
			root_password => $root_password,
			proxy_url     => $install_proxy_url,
		};
		my $ok = $expect->run_install($install_config);
		if ( !$ok ) {
			$log->error("Installation failed");
			return EXIT_ERROR;
		}

		$state->mark_installed;
		$log->info("Installation complete");

		# Stop VM via QMP (graceful)
		$log->info("Stopping installation VM...");
		$self->_qmp_quit;
		$self->_wait_exit(5);
		$state->clear_vm_pid;

		# Restart VM without install media
		$log->info("Restarting installed system...");
		$pid = $self->_start_qemu;    # No boot image, no exit_on_halt
		if ( !defined $pid ) {
			$log->error("Failed to restart VM");
			return EXIT_ERROR;
		}
		$log->info("Started $config->{name} (PID: $pid)");

		# Wait for SSH with password auth
		$log->info("Waiting for SSH...");
		if ( !$self->_wait_ssh_password( $root_password, 120 ) ) {
			$log->error("Timeout waiting for SSH");
			return EXIT_TIMEOUT;
		}

		# Install SSH authorized key for future key-based auth
		if ( !$self->_install_ssh_key($root_password) ) {
			$log->error("Failed to install SSH key");
			return EXIT_ERROR;
		}
		$log->info("SSH key installed");

		$log->info("VM ready");
		return EXIT_SUCCESS;
	}

	# VM is installed - check if SSH key needs to be installed or updated
	if ( $self->_needs_ssh_key_update ) {

		# SSH key not installed or changed in config
		# Use password auth to wait for SSH and install the key
		return $self->_complete_ssh_setup;
	}

	# Wait for SSH (key-based auth for already installed VMs)
	$log->info("Waiting for SSH...");
	if ( !$self->wait_ssh(120) ) {
		$log->error("Timeout waiting for SSH");
		return EXIT_TIMEOUT;
	}

	$log->info("VM ready");
	return EXIT_SUCCESS;
}

sub down ($self)
{
	my $state  = $self->{state};
	my $log    = $self->{log};
	my $config = $self->{config};

	# Stop proxy if running
	my $cache_dir = $self->_cache_dir;
	if ( $state->is_proxy_running ) {
		$state->stop_proxy($cache_dir);
		$log->info("Proxy stopped");
	}

	if ( !$self->_is_running ) {
		$log->info("VM '$config->{name}' is not running");
		return EXIT_SUCCESS;
	}

	$log->info("Shutting down VM...");

	# Try graceful shutdown with filesystem sync
	if ( $self->_graceful_shutdown ) {
		$state->mark_clean_shutdown;
		$state->clear_vm_pid;
		$log->info("VM stopped");
		return EXIT_SUCCESS;
	}

	# Emergency force quit - filesystem may be corrupted
	$log->warning(
		"Graceful shutdown failed, force stopping (risk of corruption)"
	);
	$state->mark_unclean_shutdown;
	$self->_qmp_quit;
	$state->clear_vm_pid;
	$log->info("VM stopped");

	return EXIT_SUCCESS;
}

sub destroy ($self)
{
	my $state  = $self->{state};
	my $log    = $self->{log};
	my $config = $self->{config};

	# Stop proxy if running
	my $cache_dir = $self->_cache_dir;
	if ( $state->is_proxy_running ) {
		$state->stop_proxy($cache_dir);
		$log->info("Proxy stopped");
	}

	# Stop if running
	if ( $self->_is_running ) {
		$self->stop(1);
	}

	# Remove disk
	my $disk_path = $state->disk_path;
	if ( -f $disk_path ) {
		$log->info("Removing disk image...");
		unlink $disk_path or do {
			$log->error("Cannot remove $disk_path: $!");
			return EXIT_ERROR;
		};
	}

	# Remove QMP socket
	my $qmp_path = $self->_qmp_socket_path;
	unlink $qmp_path if -S $qmp_path;

	# Clear state
	$state->{data} = {};
	$state->save;

	$log->info("VM '$config->{name}' destroyed");
	return EXIT_SUCCESS;
}

sub start ($self)
{
	my $state  = $self->{state};
	my $log    = $self->{log};
	my $config = $self->{config};

	if ( $self->_is_running ) {
		$log->error("VM '$config->{name}' is already running");
		return EXIT_VM_RUNNING;
	}

	if ( !$state->disk_exists ) {
		$log->error("No disk image. Run 'openhvf up' first.");
		return EXIT_ERROR;
	}

	my $pid = $self->_start_qemu;
	if ( !defined $pid ) {
		$log->error("Failed to start VM");
		return EXIT_ERROR;
	}

	$log->info("Started $config->{name} (PID: $pid)");
	return EXIT_SUCCESS;
}

sub stop ( $self, $force = 0 )
{
	my $state  = $self->{state};
	my $log    = $self->{log};
	my $config = $self->{config};

	if ( !$self->_is_running ) {
		$log->info("VM '$config->{name}' is not running");
		return EXIT_SUCCESS;
	}

	if ($force) {
		$log->warning(
			"Force stopping VM (filesystem may be corrupted)");
		$state->mark_unclean_shutdown;
		$self->_qmp_quit;
		$state->clear_vm_pid;
		$log->info("VM stopped");
		return EXIT_SUCCESS;
	}

	# Try graceful shutdown with filesystem sync
	$log->info("Shutting down VM gracefully...");
	if ( $self->_graceful_shutdown ) {
		$state->mark_clean_shutdown;
		$state->clear_vm_pid;
		$log->info("VM stopped");
		return EXIT_SUCCESS;
	}

	# If graceful shutdown times out, force stop
	$log->warning(
"Graceful shutdown timed out, force stopping (risk of corruption)"
	);
	$state->mark_unclean_shutdown;
	$self->_qmp_quit;
	$state->clear_vm_pid;
	$log->info("VM stopped");
	return EXIT_SUCCESS;
}

sub status ($self)
{
	my $state  = $self->{state};
	my $config = $self->{config};

	my $running = $self->_is_running;
	my $pid     = $state->get_vm_pid;

	# Query QEMU status via QMP if running
	my $qemu_status;
	if ($running) {
		my $qmp = $self->_qmp_connect;
		if ($qmp) {
			my $status = $qmp->query_status;
			$qemu_status = $status->{status} if $status;
			$qmp->disconnect;
		}
	}

	return {
		name  => $config->{name},
		state => $running ? ( $qemu_status // 'running' ) : 'stopped',
		pid   => $pid,
		ssh_port     => $config->{ssh_port},
		console_port => $config->{console_port},
		installed    => $state->is_installed ? 1 : 0,
		disk_exists  => $state->disk_exists  ? 1 : 0,
	};
}

sub is_running ($self)
{
	return $self->_is_running;
}

sub pid ($self)
{
	return $self->{state}->get_vm_pid;
}

sub ssh_port ($self)
{
	return $self->{config}{ssh_port};
}

sub console_port ($self)
{
	return $self->{config}{console_port};
}

# Wait operations
sub wait_ssh ( $self, $timeout = 120, $sig = undef )
{
	my $config = $self->{config};

	# Uses SSH agent for authentication
	my $ssh = OpenHVF::SSH->new(
		host => '127.0.0.1',
		port => $config->{ssh_port},
		user => 'root',
	);

	return $ssh->wait_available( $timeout, $sig );
}

# $self->_wait_ssh_password($password, $timeout):
#	Wait for SSH to become available using password authentication
#	Used during initial installation before SSH key is installed
sub _wait_ssh_password ( $self, $password, $timeout = 120 )
{
	my $config = $self->{config};

	my $ssh = OpenHVF::SSH->new(
		host     => '127.0.0.1',
		port     => $config->{ssh_port},
		user     => 'root',
		password => $password,
	);

	return $ssh->wait_available($timeout);
}

# $self->_needs_ssh_key_update:
#	Check if SSH key needs to be installed or updated.
#	Returns true if no key is installed, or if the configured key
#	differs from the installed key.
sub _needs_ssh_key_update ($self)
{
	my $config = $self->{config};
	my $state  = $self->{state};

	my $configured_key = $config->{ssh_pubkey};
	my $installed_key  = $state->get_installed_ssh_pubkey;

	# No key configured - nothing to install
	return 0 if !defined $configured_key || $configured_key eq '';

	# No key installed yet
	return 1 if !defined $installed_key;

	# Compare keys (normalize whitespace for comparison)
	my $configured_normalized = $configured_key =~ s/\s+/ /gr;
	my $installed_normalized  = $installed_key  =~ s/\s+/ /gr;

	return $configured_normalized ne $installed_normalized;
}

# $self->_complete_ssh_setup():
#	Install or update the SSH key on the VM.
#	Uses the stored root password to authenticate.
#	Called when recovering from a failed first boot or when the
#	configured SSH key has changed.
sub _complete_ssh_setup ($self)
{
	my $state  = $self->{state};
	my $config = $self->{config};
	my $log    = $self->{log};

	my $root_password = $state->get_root_password;
	if ( !defined $root_password ) {
		$log->error(
			"No root password stored - cannot complete SSH setup");
		return EXIT_ERROR;
	}

	$log->info("Updating SSH key...");

	# Wait for SSH with password auth
	$log->info("Waiting for SSH...");
	if ( !$self->_wait_ssh_password( $root_password, 120 ) ) {
		$log->error("Timeout waiting for SSH");
		return EXIT_TIMEOUT;
	}

	# Install SSH authorized key
	if ( !$self->_install_ssh_key($root_password) ) {
		$log->error("Failed to install SSH key");
		return EXIT_ERROR;
	}
	$log->info("SSH key installed");

	$log->info("VM ready");
	return EXIT_SUCCESS;
}

# $self->_install_ssh_key($password):
#	Install the SSH public key from config into authorized_keys
#	Uses password authentication since key is not yet installed
sub _install_ssh_key ( $self, $password )
{
	my $config = $self->{config};
	my $state  = $self->{state};
	my $log    = $self->{log};

	# Get SSH public key from config
	my $ssh_pubkey = $config->{ssh_pubkey};
	if ( !defined $ssh_pubkey || $ssh_pubkey eq '' ) {
		$log->error("No ssh_pubkey configured in ~/.openhvfrc");
		return 0;
	}

	# Connect with password
	my $ssh = OpenHVF::SSH->new(
		host     => '127.0.0.1',
		port     => $config->{ssh_port},
		user     => 'root',
		password => $password,
	);

	# Create .ssh directory
	my $result =
	    $ssh->run_command('mkdir -p /root/.ssh && chmod 700 /root/.ssh');
	if ( $result->{exit_code} != 0 ) {
		return 0;
	}

	# Write authorized_keys file
	my $authkeys_content = $ssh_pubkey . "\n";
	if (
		$ssh->write_file(
			'/root/.ssh/authorized_keys', $authkeys_content,
			0600
		) != 0
	    )
	{
		return 0;
	}

	# Store which pubkey was installed for future comparison
	$state->mark_ssh_key_installed($ssh_pubkey);
	return 1;
}

# P1: Graceful shutdown with filesystem sync
# Tries multiple methods in order of reliability:
# 1. SSH sync + ACPI powerdown (sync via SSH, powerdown via QMP)
# 2. QGA guest-shutdown (if available)
# 3. Direct ACPI powerdown
sub _graceful_shutdown ($self)
{
	my $config = $self->{config};
	my $log    = $self->{log};

	# Method 1: SSH sync + ACPI powerdown
	# First sync filesystems via SSH, then use QMP to send ACPI power button
	# This avoids the problem of SSH connection being killed by halt
	my $ssh = OpenHVF::SSH->new(
		host => '127.0.0.1',
		port => $config->{ssh_port},
		user => 'root',
	);

	# Try to sync filesystems via SSH (non-blocking command)
	my $sync_result = $ssh->run_command('sync; sync; sync');

	if ( $sync_result->{exit_code} == 0 ) {

		# Synced successfully, now use ACPI powerdown via QMP
		if ( $self->_qmp_powerdown ) {
			if ( $self->_wait_exit(60) ) {
				$log->info(
					"Shutdown via SSH sync + ACPI powerdown"
				);
				return 1;
			}
		}
	}

	# Method 2: Try QGA shutdown (if guest agent is available)
	my $qga = $self->_qga_connect;
	if ($qga) {

		# Sync filesystems first
		$qga->sync;

		# Request shutdown via guest agent
		$qga->shutdown('powerdown');
		$qga->disconnect;

		if ( $self->_wait_exit(60) ) {
			$log->info("Shutdown via QEMU Guest Agent");
			return 1;
		}
	}

	# Method 3: Try direct ACPI powerdown as last resort
	if ( $self->_qmp_powerdown ) {
		if ( $self->_wait_exit(30) ) {
			$log->info("Shutdown via ACPI powerdown");
			return 1;
		}
	}

	return 0;
}

# QGA methods
sub _qga_socket_path ($self)
{
	return $self->{state}{vm_state_dir} . '/qga.sock';
}

sub _qga_connect ($self)
{
	my $qga = OpenHVF::QGA->new( $self->_qga_socket_path );
	return if !$qga->is_available;
	return $qga->open_connection ? $qga : undef;
}

# QMP methods
sub _qmp_socket_path ($self)
{
	return $self->{state}{vm_state_dir} . '/qmp.sock';
}

sub _qmp_connect ($self)
{
	my $qmp = OpenHVF::QMP->new( $self->_qmp_socket_path );
	return $qmp->open_connection ? $qmp : undef;
}

sub _qmp_powerdown ($self)
{
	my $qmp    = $self->_qmp_connect or return 0;
	my $result = $qmp->powerdown;
	$qmp->disconnect;
	return $result;
}

sub _qmp_quit ($self)
{
	my $qmp = $self->_qmp_connect or return 0;
	return $qmp->quit;
}

sub _is_running ($self)
{
	my $pid = $self->{state}->get_vm_pid;
	return 0 if !defined $pid;

	# Check if process is alive
	return 0 if !kill( 0, $pid );

	# Optionally verify via QMP (more reliable)
	my $qmp = $self->_qmp_connect;
	if ($qmp) {
		my $running = $qmp->is_running;
		$qmp->disconnect;
		return $running;
	}

	# Fall back to process check
	return 1;
}

sub _wait_exit ( $self, $timeout )
{
	my $start = time;
	while ( time - $start < $timeout ) {
		my $pid = $self->{state}->get_vm_pid;
		return 1 if !defined $pid || !kill( 0, $pid );
		sleep 1;
	}
	return 0;
}

# QEMU startup
sub _start_qemu ( $self, $boot_image = undef )
{
	my $config = $self->{config};
	my $state  = $self->{state};

	my @cmd = (QEMU_BINARY);

	# Machine type for arm64, acceleration by host capability
	push @cmd, '-M', 'virt,highmem=off';
	push @cmd, $self->_accel_args;

	# Memory and CPU
	push @cmd, '-m',   $config->{memory} // MEMORY_DEFAULT;
	push @cmd, '-smp', CPU_COUNT;

	# EFI firmware for arm64
	my $bios = $self->_find_efi_firmware;
	if ( defined $bios ) {
		push @cmd, '-bios', $bios;
	}

	# Main disk with safe cache mode (writethrough syncs on each write)
	my $disk_path = $state->disk_path;
	push @cmd, '-drive',
	    "file=$disk_path,format=qcow2,if=virtio,cache=writethrough";

	# Boot image (CD-ROM) for installation
	if ( defined $boot_image ) {
		push @cmd, '-drive',
		    "file=$boot_image,format=raw,if=virtio,readonly=on";
	}

	# QEMU Guest Agent virtio-serial channel
	my $qga_path = $self->_qga_socket_path;
	unlink $qga_path if -S $qga_path;
	push @cmd, '-device', 'virtio-serial-pci';
	push @cmd, '-chardev',
	    "socket,path=$qga_path,server=on,wait=off,id=qga0";
	push @cmd, '-device',
	    'virtserialport,chardev=qga0,name=org.qemu.guest_agent.0';

	# Network with port forwarding
	my $ssh_port = $config->{ssh_port};
	push @cmd, '-device', 'virtio-net-pci,netdev=net0';
	push @cmd, '-netdev', "user,id=net0,hostfwd=tcp::$ssh_port-:22";

	# Serial console on telnet
	my $console_port = $config->{console_port};
	push @cmd, '-serial', "tcp::$console_port,server,telnet,nowait";

	# QMP control socket
	my $qmp_path = $self->_qmp_socket_path;
	unlink $qmp_path if -S $qmp_path;
	push @cmd, '-qmp', "unix:$qmp_path,server,nowait";

	# PID file for reliable tracking
	push @cmd, '-pidfile', $state->{vm_pid_file};

	# No graphics display (headless)
	push @cmd, '-display', 'none';

	# Spawn QEMU using FuguLib::Process
	my $log_file = "$state->{vm_state_dir}/qemu.log";
	my $result   = FuguLib::Process->spawn_command(
		cmd         => \@cmd,
		daemonize   => 1,
		stdout      => $log_file,
		stderr      => $log_file,
		check_alive => 0,    # Don't check, QEMU writes its own PID file
	);

	return unless $result->{success};

	# Wait for QEMU to write PID file
	my $start = time;
	my $pid;
	while ( time - $start < 5 ) {
		if ( -f $state->{vm_pid_file} ) {
			my $qemu_pid = $state->get_vm_pid;
			if ( defined $qemu_pid && kill( 0, $qemu_pid ) ) {
				$pid = $qemu_pid;
				last;
			}
		}
		usleep(100_000);    # 0.1 seconds
	}

	# Fallback: use forked PID from FuguLib::Process
	unless ( defined $pid ) {
		my $forked = $result->{pid};
		if ( kill( 0, $forked ) ) {
			$state->set_vm_pid($forked);
			$state->mark_running;
			$pid = $forked;
		}
	}

	unless ( defined $pid ) {
		$self->_dump_qemu_log($log_file);
		return;
	}

	# Confirm QEMU is actually accepting console connections before the
	# installer tries to attach. A QEMU that exited at startup (bad
	# accelerator, missing firmware) leaves the port closed; catching
	# that here fails fast with the QEMU log instead of a long telnet
	# timeout later.
	unless ( $self->_wait_console_ready( $config->{console_port}, 30 ) ) {
		$self->{log}
		    ->error( 'QEMU console port %d not listening after start',
			$config->{console_port} );
		$self->_dump_qemu_log($log_file);
		return;
	}

	return $pid;
}

# $self->_wait_console_ready($port, $timeout):
#	Poll the console TCP port until it accepts a connection, so the
#	installer's telnet attaches to a live console. The bind happens
#	at QEMU startup (before guest boot), so this is quick when QEMU
#	is healthy and bounded when it is not.
sub _wait_console_ready ( $self, $port, $timeout )
{
	require IO::Socket::INET;

	my $start = time;
	while ( time - $start < $timeout ) {
		my $sock = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => 2,
		);
		if ( defined $sock ) {
			$sock->close;
			return 1;
		}

		# Give up early if QEMU has already exited
		my $qemu_pid = $self->{state}->get_vm_pid;
		return 0 if defined $qemu_pid && !kill( 0, $qemu_pid );

		usleep(200_000);    # 0.2 seconds
	}

	return 0;
}

# $self->_dump_qemu_log($log_file):
#	Emit the tail of the QEMU log so a startup failure is visible in
#	CI output instead of requiring shell access to the runner.
sub _dump_qemu_log ( $self, $log_file )
{
	open my $fh, '<', $log_file or return;
	my @lines = <$fh>;
	close $fh;

	@lines = splice( @lines, -40 ) if @lines > 40;
	$self->{log}->error('QEMU log tail:');
	$self->{log}->error( '  %s', $_ ) for map { chomp; $_ } @lines;

	return;
}

# $self->_accel_args():
#	Pick the QEMU accelerator for the host: HVF on macOS, KVM on
#	aarch64 Linux hosts with /dev/kvm, TCG software emulation
#	otherwise or when --emulate was given. Host CPU passthrough is
#	only valid with hardware acceleration; TCG needs a named model.
sub _accel_args ($self)
{
	my $accel;
	if ( $self->{emulate} ) {
		$accel = 'tcg';
	}
	elsif ( $^O eq 'darwin' ) {
		$accel = 'hvf';
	}
	elsif ( $^O eq 'linux' && -w '/dev/kvm' && _host_arch() eq 'aarch64' ) {
		$accel = 'kvm';
	}
	else {
		$accel = 'tcg';
	}

	$self->{log}->debug("Using QEMU accelerator: $accel")
	    if $self->{log};

	return ( '-accel', $accel, '-cpu', $accel eq 'tcg' ? TCG_CPU : 'host' );
}

# _host_arch():
#	Host machine architecture from uname
sub _host_arch ()
{
	require POSIX;
	my @uname = POSIX::uname();
	return $uname[4] // '';
}

sub _find_efi_firmware ($self)
{
	my @paths = (
		'/opt/homebrew/share/qemu/edk2-aarch64-code.fd',
		'/usr/local/share/qemu/edk2-aarch64-code.fd',
		'/usr/share/qemu-efi-aarch64/QEMU_EFI.fd',
		'/usr/share/AAVMF/AAVMF_CODE.fd',
		'/usr/share/qemu/edk2-aarch64-code.fd',
	);

	for my $path (@paths) {
		return $path if -f $path;
	}

	# Try glob for versioned Homebrew paths
	my @glob_paths =
	    glob('/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd');
	return $glob_paths[0] if @glob_paths;

	return;
}

sub _cache_dir ($self)
{
	my $home = $ENV{HOME} // '/root';
	return "$home/.cache/openhvf";
}

1;
