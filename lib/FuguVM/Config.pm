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

package FuguVM::Config;

use File::Spec;
use File::Basename;

use constant {
	DEFAULT_MEMORY       => 2048,
	DEFAULT_DISK_SIZE    => '8G',
	DEFAULT_SSH_PORT     => 2222,
	DEFAULT_CONSOLE_PORT => 4444,
	DEFAULT_VERSION      => '7.8',
	DATA_DIR             => '.fuguvm',
	GLOBAL_CONFIG        => '.fuguvmrc',
	PROJECT_CONFIG       => '.fuguvmrc',
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

# Walk up the directory tree to find .fuguvmrc
sub find_project_root ($class)
{
	my $dir = File::Spec->rel2abs('.');

	while (1) {
		my $config_file = "$dir/" . PROJECT_CONFIG;
		return $dir if -f $config_file;

		my $parent = dirname($dir);
		last if $parent eq $dir;    # The walk reached the root
		$dir = $parent;
	}

	return;
}

sub _load_configs ($self)
{
	# Load the global config from the home directory
	my $home          = $ENV{HOME} // '/root';
	my $global_config = "$home/" . GLOBAL_CONFIG;
	$self->{global} =
	    -f $global_config ? $self->_parse_config($global_config) : {};

	# Load the project config from the project root
	my $project_config = "$self->{project_root}/" . PROJECT_CONFIG;
	$self->{project} =
	    -f $project_config ? $self->_parse_config($project_config) : {};

	return $self;
}

# Parse an OpenBSD-style config with the optional block syntax:
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
		s/#.*//;           # Remove the comments
		s/^\s+|\s+$//g;    # Trim the whitespace
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

		# A key-value pair, inside or outside a block. The parser
		# supports both the "key value" and the "key = value"
		# syntax.
		if (/^(\w+)\s+(.+)$/) {
			my ( $key, $value ) = ( $1, $2 );
			$value =~ s/^=\s*//;       # Remove a leading '=' if any
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
	# First check for a VM block in the project config. Then check
	# the global config.
	my $vm = $self->{project}{vm}{$name} // $self->{global}{vm}{$name};

	# Fall back to a separate VM file for backwards compatibility
	if ( !defined $vm ) {
		my $vm_file = "$self->{data_dir}/vms/$name.conf";
		$vm = $self->_parse_config($vm_file) if -f $vm_file;
	}

	return if !defined $vm;

	# Apply the defaults
	$vm->{name}         //= $name;
	$vm->{version}      //= DEFAULT_VERSION;
	$vm->{memory}       //= DEFAULT_MEMORY;
	$vm->{disk_size}    //= DEFAULT_DISK_SIZE;
	$vm->{ssh_port}     //= DEFAULT_SSH_PORT;
	$vm->{console_port} //= DEFAULT_CONSOLE_PORT;

	# Include ssh_pubkey from the global or project config
	$vm->{ssh_pubkey} //= $self->ssh_pubkey;

	# Include the resolved cache_dir. Then the VM operations, the
	# proxy cache and the installed-image cache, all use the
	# configured location. Without it, 'fuguvm up' would write its
	# images under $HOME while the cache subcommands worked on a
	# different tree.
	$vm->{cache_dir} //= $self->cache_dir;

	# Normalize the installed-image cache switch, whether it came from
	# the VM block or the enclosing configuration
	$vm->{image_cache} =
	    defined $vm->{image_cache}
	    ? _parse_bool( $vm->{image_cache}, 1 )
	    : $self->image_cache;

	return $vm;
}

sub cache_dir ($self)
{
	my $dir = $self->{project}{cache_dir} // $self->{global}{cache_dir}
	    // '~/.cache/fuguvm';

	# Expand ~
	$dir =~ s/^~/$ENV{HOME}/;

	return $dir;
}

# $self->image_cache:
#	Return whether 'fuguvm up' may use the installed-image cache.
#	The project configuration wins over the global one. The default
#	is on.
sub image_cache ($self)
{
	my $value = $self->{project}{image_cache}
	    // $self->{global}{image_cache};
	return 1 if !defined $value;

	return _parse_bool( $value, 1 );
}

# _parse_bool($value, $default):
#	Accept the spellings that an OpenBSD-style configuration file
#	uses for a switch. An unrecognized value warns and falls back.
#	It does not silently mean its opposite.
sub _parse_bool ( $value, $default )
{
	my $normalized = lc $value;
	$normalized =~ s/^\s+|\s+$//g;

	return 1
	    if $normalized eq 'yes'
	    || $normalized eq 'true'
	    || $normalized eq 'on'
	    || $normalized eq '1';
	return 0
	    if $normalized eq 'no'
	    || $normalized eq 'false'
	    || $normalized eq 'off'
	    || $normalized eq '0';

	warn "Not a yes/no value: $value\n";
	return $default;
}

sub state_dir ($self)
{
	my $dir = $self->{project}{state_dir} // "$self->{data_dir}/state";

	# Make relative paths absolute to the project root
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
