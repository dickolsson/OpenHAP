# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2025 Dick Olsson <hi@senzilla.io>
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

package FuguLib::Privdrop;

use POSIX qw(setuid setgid);

# $class->drop_privileges(%args):
#	Drop privileges from root to the specified user and group.
#	This is a common pattern in OpenBSD daemons. The daemon starts
#	as root to bind privileged ports and fork privileged
#	processes. It then drops to an unprivileged user for the main
#	event loop.
#
#	%args:
#		user  => $username  # Username to drop to (required)
#		group => $groupname # Group to drop to (optional, default: the user's primary group)
#
#	The method returns 1 on success. It dies on error.
#
#	Example:
#		# Start as root. Do the privileged operations.
#		$state->chown_runtime_files();
#
#		# Drop privileges before you start the event loop
#		FuguLib::Privdrop->drop_privileges(user => '_openhap');
#
#		# The process now runs as _openhap
#		$server->run();
sub drop_privileges ( $class, %args )
{
	my $user = $args{user}
	    or die "user parameter required for drop_privileges";
	my $group = $args{group};

	# If the process is already non-root, there is nothing to do
	return 1 if $> != 0;

	# Get the user info
	my ( $uid, $gid ) = ( getpwnam($user) )[ 2, 3 ];
	unless ( defined $uid ) {
		die "Cannot get UID for user '$user': $!";
	}

	# Get the group info if the caller gives a group. Otherwise
	# use the user's primary group.
	if ( defined $group ) {
		$gid = getgrnam($group);
		unless ( defined $gid ) {
			die "Cannot get GID for group '$group': $!";
		}
	}

	# Drop the group privileges first. Do this before setuid.
	unless ( POSIX::setgid($gid) ) {
		die "Cannot setgid to $gid: $!";
	}
	$( = $gid;    # Set the effective GID
	$) = $gid;    # Set the real GID

	# Drop the user privileges
	unless ( POSIX::setuid($uid) ) {
		die "Cannot setuid to $uid: $!";
	}
	$< = $uid;    # Set the effective UID
	$> = $uid;    # Set the real UID

	# Make sure the process cannot get root back
	if ( $> == 0 || $< == 0 ) {
		die "Failed to drop privileges - still running as root";
	}

	# Try to escalate. The attempt must fail.
	eval {
		POSIX::setuid(0);
		if ( $> == 0 || $< == 0 ) {
			die "Privilege drop failed - able to regain root";
		}
	};

	return 1;
}

1;
