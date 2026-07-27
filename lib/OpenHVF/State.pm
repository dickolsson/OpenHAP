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

package OpenHVF::State;

use File::Path qw(make_path);
use JSON::XS;

use constant { MAX_VM_NAME_LENGTH => 255, };

sub new ( $class, $state_dir, $vm_name, %opts )
{
	# Validate VM name length
	if ( length($vm_name) > MAX_VM_NAME_LENGTH ) {
		warn "VM name too long (max "
		    . MAX_VM_NAME_LENGTH
		    . " characters)\n";
		return;
	}

	# Validate VM name characters (no path separators or null bytes)
	if ( $vm_name =~ m{[/\x00]} ) {
		warn "VM name contains invalid characters\n";
		return;
	}

	my $vm_state_dir = "$state_dir/$vm_name";

	my $self = bless {
		state_dir      => $state_dir,
		vm_name        => $vm_name,
		vm_state_dir   => $vm_state_dir,
		vm_pid_file    => "$vm_state_dir/vm.pid",
		proxy_pid_file => "$vm_state_dir/proxy.pid",
		status_file    => "$vm_state_dir/status",
		disk_path      => "$vm_state_dir/disk.qcow2",
	}, $class;

	if ( !$self->_ensure_dir ) {
		return;
	}
	$self->load;

	return $self;
}

sub _ensure_dir ($self)
{
	my $dir = $self->{vm_state_dir};

	# Check for symlinks (refuse to follow for security)
	if ( -l $dir ) {
		warn "State directory is a symlink: $dir\n";
		return 0;
	}

	# Check if path exists but is not a directory
	if ( -e $dir && !-d $dir ) {
		warn "State path exists but is not a directory: $dir\n";
		return 0;
	}

	if ( !-d $dir ) {
		eval { make_path($dir) };
		if ($@) {

			# Extract the error message without exposing internals
			my $err = $@;
			$err =~ s/ at \S+ line \d+.*//s;
			warn "Cannot create state directory: $err\n";
			return 0;
		}
	}
	return 1;
}

sub load ($self)
{
	if ( -f $self->{status_file} ) {
		open my $fh, '<', $self->{status_file} or return;
		local $/;
		my $json = <$fh>;
		close $fh;

		eval { $self->{data} = decode_json($json); };
		if ($@) {
			warn "State file corrupted: $self->{status_file}: $@";
			$self->{data} = {};
		}
	}
	else {
		$self->{data} = {};
	}

	return $self;
}

sub save ($self)
{
	open my $fh, '>', $self->{status_file} or do {
		warn "Cannot write $self->{status_file}: $!\n";
		return;
	};

	print $fh encode_json( $self->{data} );
	close $fh;

	return $self;
}

# VM PID management
sub set_vm_pid ( $self, $pid )
{
	open my $fh, '>', $self->{vm_pid_file} or do {
		warn "Cannot write $self->{vm_pid_file}: $!";
		return;
	};
	print $fh "$pid\n";
	close $fh;

	return $self;
}

sub get_vm_pid ($self)
{
	open my $fh, '<', $self->{vm_pid_file} or return;
	my $pid = <$fh>;
	close $fh;

	chomp $pid  if defined $pid;
	return $pid if $pid && $pid =~ /^\d+$/;
	return;
}

sub clear_vm_pid ($self)
{
	unlink $self->{vm_pid_file};
	return $self;
}

sub is_vm_running ($self)
{
	my $pid = $self->get_vm_pid;
	return 0 if !defined $pid;

	# Check if process is alive
	return kill( 0, $pid ) ? 1 : 0;
}

# Proxy PID management
sub set_proxy_pid ( $self, $pid )
{
	open my $fh, '>', $self->{proxy_pid_file} or do {
		warn "Cannot write $self->{proxy_pid_file}: $!";
		return;
	};
	print $fh "$pid\n";
	close $fh;

	return $self;
}

sub get_proxy_pid ($self)
{
	open my $fh, '<', $self->{proxy_pid_file} or return;
	my $pid = <$fh>;
	close $fh;

	chomp $pid  if defined $pid;
	return $pid if $pid && $pid =~ /^\d+$/;
	return;
}

sub clear_proxy_pid ($self)
{
	unlink $self->{proxy_pid_file};
	return $self;
}

sub is_proxy_running ($self)
{
	my $pid = $self->get_proxy_pid;
	return 0 if !defined $pid;

	# Check if process is alive
	return kill( 0, $pid ) ? 1 : 0;
}

# Proxy port management
sub set_proxy_port ( $self, $port )
{
	$self->{data}{proxy_port} = $port;
	$self->save;
	return $self;
}

sub get_proxy_port ($self)
{
	return $self->{data}{proxy_port};
}

sub clear_proxy_port ($self)
{
	delete $self->{data}{proxy_port};
	$self->save;
	return $self;
}

# Proxy lifecycle management
# $self->ensure_proxy($cache_dir):
#	Start proxy if not running, return Proxy object
#	Returns undef if proxy cannot be started
sub ensure_proxy ( $self, $cache_dir )
{
	require OpenHVF::Proxy;

	my $proxy = OpenHVF::Proxy->new( $self, $cache_dir );

	# Already running? Return existing proxy
	if ( $proxy->is_running ) {
		return $proxy;
	}

	# Start the proxy
	my $port = $proxy->start;
	return if !defined $port;

	return $proxy;
}

# $self->get_proxy($cache_dir):
#	Get Proxy object if running, undef if not
sub get_proxy ( $self, $cache_dir )
{
	require OpenHVF::Proxy;

	my $proxy = OpenHVF::Proxy->new( $self, $cache_dir );
	return $proxy->is_running ? $proxy : undef;
}

# $self->stop_proxy($cache_dir):
#	Stop proxy if running
sub stop_proxy ( $self, $cache_dir )
{
	require OpenHVF::Proxy;

	my $proxy = OpenHVF::Proxy->new( $self, $cache_dir );
	if ( $proxy->is_running ) {
		$proxy->stop;
	}

	return $self;
}

# Disk state
sub disk_path ($self)
{
	return $self->{disk_path};
}

sub disk_exists ($self)
{
	return -f $self->{disk_path};
}

# Installation state
sub is_installed ($self)
{
	return $self->{data}{installed} ? 1 : 0;
}

sub mark_installed ($self)
{
	$self->{data}{installed}    = 1;
	$self->{data}{installed_at} = time;
	$self->save;
	return $self;
}

# Root password management (stored securely in state for initial setup)
sub set_root_password ( $self, $password )
{
	$self->{data}{root_password} = $password;
	$self->save;
	return $self;
}

sub get_root_password ($self)
{
	return $self->{data}{root_password};
}

# SSH key installation state
# Tracks both whether an SSH key has been installed and which specific key
# was installed. This allows the system to detect when the configured SSH
# key has changed and automatically reinstall the new key.
sub is_ssh_key_installed ($self)
{
	return $self->{data}{ssh_key_installed} ? 1 : 0;
}

sub mark_ssh_key_installed ( $self, $ssh_pubkey = undef )
{
	$self->{data}{ssh_key_installed}    = 1;
	$self->{data}{ssh_key_installed_at} = time;
	$self->{data}{installed_ssh_pubkey} = $ssh_pubkey
	    if defined $ssh_pubkey;
	$self->save;
	return $self;
}

sub get_installed_ssh_pubkey ($self)
{
	return $self->{data}{installed_ssh_pubkey};
}

sub ssh_key_matches ( $self, $ssh_pubkey )
{
	return 0 if !$self->is_ssh_key_installed;
	my $installed = $self->get_installed_ssh_pubkey;
	return 0 if !defined $installed;
	return $installed eq $ssh_pubkey;
}

sub vm_state_dir ($self)
{
	return $self->{vm_state_dir};
}

sub data ($self)
{
	return $self->{data};
}

# Shutdown state tracking
# Tracks whether VM was shutdown cleanly to detect filesystem corruption risk

sub mark_clean_shutdown ($self)
{
	$self->{data}{shutdown_clean} = 1;
	$self->{data}{shutdown_at}    = time;
	delete $self->{data}{running};
	$self->save;
	return $self;
}

sub mark_unclean_shutdown ($self)
{
	$self->{data}{shutdown_clean} = 0;
	$self->{data}{shutdown_at}    = time;
	delete $self->{data}{running};
	$self->save;
	return $self;
}

sub mark_running ($self)
{
	$self->{data}{running}    = 1;
	$self->{data}{started_at} = time;
	delete $self->{data}{shutdown_clean};
	$self->save;
	return $self;
}

sub was_unclean_shutdown ($self)
{
	# If explicitly marked as unclean
	if ( exists $self->{data}{shutdown_clean}
		&& !$self->{data}{shutdown_clean} )
	{
		return 1;
	}

	# If marked running but VM process is dead = crashed/killed
	if ( $self->{data}{running} && !$self->is_vm_running ) {
		return 1;
	}

	return 0;
}

sub clear_shutdown_state ($self)
{
	delete $self->{data}{shutdown_clean};
	delete $self->{data}{running};
	$self->save;
	return $self;
}

1;
