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

package OpenHVF::Expect;

use File::Basename;
use FindBin qw($RealBin);

sub new ( $class, %args )
{
	my $self = bless {
		host    => $args{host} // 'localhost',
		port    => $args{port},
		timeout => $args{timeout} // $ENV{OPENHVF_TIMEOUT} // 180,
	}, $class;

	return $self;
}

sub run_script ( $self, $script, @args )
{
	if ( !-f $script ) {

		# Check in share/openhvf/expect/
		my $share_script = "$RealBin/../share/openhvf/expect/$script";
		if ( -f $share_script ) {
			$script = $share_script;
		}
		else {
			warn "Expect script not found: $script\n";
			return 0;
		}
	}

	if ( !-x $script ) {
		warn "Expect script not executable: $script\n";
		return 0;
	}

	my @cmd    = ( $script, $self->{host}, $self->{port}, @args );
	my $result = system(@cmd);

	return $result == 0;
}

sub _find_script ( $self, $script_name )
{
	my @search_paths = (
		"$RealBin/../share/openhvf/expect/$script_name",
		"share/openhvf/expect/$script_name",
	);

	for my $path (@search_paths) {
		return $path if -f $path;
	}

	return;
}

sub run_install ( $self, $config )
{
	my $script = $self->_find_script('install.exp')
	    // "$RealBin/../share/openhvf/expect/install.exp";

	if ( !-f $script ) {
		warn "Install script not found: $script\n";
		return 0;
	}

	# Pass timeout via environment variable
	local $ENV{OPENHVF_TIMEOUT} = $self->{timeout};

	my @cmd = (
		'expect', $script, $self->{host}, $self->{port},
		$config->{root_password} // 'openbsd',
		$config->{proxy_url}     // 'none',
	);

	my $result = system(@cmd);
	return $result == 0;
}

sub install_ssh_key ( $self, $password, $ssh_pubkey )
{
	if ( !defined $ssh_pubkey || $ssh_pubkey eq '' ) {
		warn "No SSH public key provided\n";
		return 0;
	}

	my $script = $self->_find_script('install-ssh-key.exp');
	if ( !defined $script ) {
		warn "install-ssh-key.exp script not found\n";
		return 0;
	}

	# Pass timeout via environment variable for expect script
	local $ENV{OPENHVF_TIMEOUT} = $self->{timeout};

	my @cmd = (
		'expect',  $script, $self->{host}, $self->{port},
		$password, $ssh_pubkey
	);

	my $result = system(@cmd);
	return $result == 0;
}

sub halt_system ( $self, $password )
{
	my $script = $self->_find_script('command.exp');
	if ( !defined $script ) {
		warn "command.exp script not found\n";
		return 0;
	}

	# Pass timeout via environment variable
	local $ENV{OPENHVF_TIMEOUT} = $self->{timeout};

	my @cmd = (
		'expect',  $script, $self->{host}, $self->{port},
		'halt -p', 'root',  $password
	);

	my $result = system(@cmd);
	return $result == 0;
}

1;
