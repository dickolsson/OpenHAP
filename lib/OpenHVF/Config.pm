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

package OpenHVF::Config;

use File::Spec;
use File::Basename;

use constant {
	DEFAULT_MEMORY       => 2048,
	DEFAULT_DISK_SIZE    => '8G',
	DEFAULT_SSH_PORT     => 2222,
	DEFAULT_CONSOLE_PORT => 4444,
	DEFAULT_VERSION      => '7.8',
	DATA_DIR             => '.openhvf',
	GLOBAL_CONFIG        => '.openhvfrc',
	PROJECT_CONFIG       => '.openhvfrc',
};

sub new ( $class, $project_root )
{
	my $self = bless {
		project_root => $project_root,
		data_dir     => "$project_root/" . DATA_DIR,
	}, $class;

	$self->_load_configs;
	return $self;
}

# Walk up directory tree looking for .openhvfrc
sub find_project_root ($class)
{
	my $dir = File::Spec->rel2abs('.');

	while (1) {
		my $config_file = "$dir/" . PROJECT_CONFIG;
		return $dir if -f $config_file;

		my $parent = dirname($dir);
		last if $parent eq $dir;    # Reached root
		$dir = $parent;
	}

	return;
}

sub _load_configs ($self)
{
	# Load global config from home directory
	my $home          = $ENV{HOME} // '/root';
	my $global_config = "$home/" . GLOBAL_CONFIG;
	$self->{global} =
	    -f $global_config ? $self->_parse_config($global_config) : {};

	# Load project config from project root
	my $project_config = "$self->{project_root}/" . PROJECT_CONFIG;
	$self->{project} =
	    -f $project_config ? $self->_parse_config($project_config) : {};

	return $self;
}

# Parse OpenBSD-style config with optional block syntax:
#
#   key value
#
#   vm "name" { ... }
#   vm name { ... }
#
sub _parse_config ( $self, $path )
{
	my %config;

	open my $fh, '<', $path or do {
		warn "Cannot open $path: $!";
		return \%config;
	};

	my $block_type;
	my $block_name;
	my $block_data;

	while (<$fh>) {
		chomp;
		s/#.*//;           # Remove comments
		s/^\s+|\s+$//g;    # Trim whitespace
		next if $_ eq '';

		# Block start: vm "name" { or vm name {
		if (       /^(\w+)\s+"([^"]+)"\s*\{$/
			|| /^(\w+)\s+(\S+)\s*\{$/ )
		{
			$block_type = $1;
			$block_name = $2;
			$block_data = {};
			next;
		}

		# Block end
		if ( $_ eq '}' ) {
			if ( defined $block_type ) {
				$config{$block_type}{$block_name} = $block_data;
				$block_type                       = undef;
				$block_name                       = undef;
				$block_data                       = undef;
			}
			next;
		}

		# Key-value pair (inside or outside block)
		# Supports both "key value" and "key = value" syntax
		if (/^(\w+)\s+(.+)$/) {
			my ( $key, $value ) = ( $1, $2 );
			$value =~ s/^=\s*//;      # Strip leading '=' if present
			$value =~ s/^\s+|\s+$//g;
			$value =~ s/^"(.*)"$/$1/;
			if ( defined $block_data ) {
				$block_data->{$key} = $value;
			}
			else {
				$config{$key} = $value;
			}
		}
	}

	close $fh;
	return \%config;
}

sub load_vm ( $self, $name )
{
	# First check for VM block in project config, then global config
	my $vm = $self->{project}{vm}{$name} // $self->{global}{vm}{$name};

	# Fall back to separate VM file for backwards compatibility
	if ( !defined $vm ) {
		my $vm_file = "$self->{data_dir}/vms/$name.conf";
		$vm = $self->_parse_config($vm_file) if -f $vm_file;
	}

	return if !defined $vm;

	# Apply defaults
	$vm->{name}         //= $name;
	$vm->{version}      //= DEFAULT_VERSION;
	$vm->{memory}       //= DEFAULT_MEMORY;
	$vm->{disk_size}    //= DEFAULT_DISK_SIZE;
	$vm->{ssh_port}     //= DEFAULT_SSH_PORT;
	$vm->{console_port} //= DEFAULT_CONSOLE_PORT;

	# Include ssh_pubkey from global/project config
	$vm->{ssh_pubkey} //= $self->ssh_pubkey;

	# Include the resolved cache_dir so VM operations (proxy cache,
	# installed-image cache) all use the configured location. Without
	# it 'openhvf up' would write its images under $HOME while the
	# cache subcommands worked on a different tree.
	$vm->{cache_dir} //= $self->cache_dir;

	return $vm;
}

sub cache_dir ($self)
{
	my $dir = $self->{project}{cache_dir} // $self->{global}{cache_dir}
	    // '~/.cache/openhvf';

	# Expand ~
	$dir =~ s/^~/$ENV{HOME}/;

	return $dir;
}

sub state_dir ($self)
{
	my $dir = $self->{project}{state_dir} // "$self->{data_dir}/state";

	# Make relative paths absolute to project root
	if ( $dir !~ m{^/} ) {
		$dir = "$self->{project_root}/$dir";
	}

	return $dir;
}

sub default_vm ($self)
{
	return $self->{project}{default_vm} // $self->{global}{default_vm}
	    // 'default';
}

sub ssh_pubkey ($self)
{
	return $self->{project}{ssh_pubkey} // $self->{global}{ssh_pubkey};
}

sub project_root ($self)
{
	return $self->{project_root};
}

1;
