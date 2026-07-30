# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@senzilla.io>
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

package FuguLib::MDNS;

use FuguLib::Imsg;
use IO::Socket::UNIX;
use Socket      qw(SOCK_STREAM);
use Time::HiRes qw(time);

# FuguLib::MDNS - publish services through OpenBSD's mdnsd(8) over its
# control socket, natively: no mdnsctl(8) child process. The socket is
# the advertisement's lifetime - closing it withdraws the service.
# Protocol per spec/MDNS-Control.md. The module never logs; it returns
# outcomes and keeps the last failure in ->error for the caller.

# The imsg_type enum ordinals [MDNS-Control §2]. Positional in the
# upstream header, so all of them are pinned here in order even though
# only the group subset is used.
use constant {
	IMSG_NONE                     => 0,
	IMSG_CTL_END                  => 1,
	IMSG_CTL_LOOKUP               => 2,
	IMSG_CTL_LOOKUP_FAILURE       => 3,
	IMSG_CTL_BROWSE_ADD           => 4,
	IMSG_CTL_BROWSE_DEL           => 5,
	IMSG_CTL_RESOLVE              => 6,
	IMSG_CTL_RESOLVE_FAILURE      => 7,
	IMSG_CTL_GROUP_ADD            => 8,
	IMSG_CTL_GROUP_RESET          => 9,
	IMSG_CTL_GROUP_ADD_SERVICE    => 10,
	IMSG_CTL_GROUP_COMMIT         => 11,
	IMSG_CTL_GROUP_ERR_COLLISION  => 12,
	IMSG_CTL_GROUP_ERR_NOT_FOUND  => 13,
	IMSG_CTL_GROUP_ERR_DOUBLE_ADD => 14,
	IMSG_CTL_GROUP_PROBING        => 15,
	IMSG_CTL_GROUP_ANNOUNCING     => 16,
	IMSG_CTL_GROUP_PUBLISHED      => 17,
};

# Field limits and the struct mdns_service layout [MDNS-Control §3-§4],
# LP64 as measured for OpenBSD 7.8/openmdns-0.7p3 (the LIST_ENTRY width
# and the 864-byte total are LP64-specific). NAME_MAX etc. are the
# usable lengths: one byte of each field is the terminating NUL.
use constant {
	GROUP_NAME_LEN => 256,    # char[MAXHOSTNAMELEN] [MDNS-Control §3.1]
	SERVICE_LEN    => 864,    # sizeof(struct mdns_service)
	APP_MAX        => 63,
	NAME_MAX       => 255,
	TXT_MAX        => 255,
};

# struct mdns_service, one template [MDNS-Control §4]: 16 zero bytes of
# LIST_ENTRY, app[64], proto[4], name[256], target[256] (zeros: mdnsd
# substitutes its own hostname), u16 priority/weight/port native order,
# txt[256], 2 bytes padding, in_addr (zeros: INADDR_ANY, mdnsd patches
# in the interface address).
use constant SERVICE_TEMPLATE => 'x16 Z64 Z4 Z256 x256 S S S Z256 x2 x4';

# FuguLib::MDNS->new(%args):
#	socket_path => $path	control socket (default /var/run/mdnsd.sock)
#	timeout     => $secs	reply deadline (default 10; PUBLISHED
#				takes ~4-4.5s [MDNS-Control §6.2])
sub new ( $class, %args )
{
	return bless {
		socket_path => $args{socket_path} // '/var/run/mdnsd.sock',
		timeout     => $args{timeout}     // 10,
		imsg        => undef,
		published   => 0,
		service     => undef,
		error       => undef,
	}, $class;
}

# $self->connect:
#	Connect to mdnsd's control socket. Returns 1, or undef when
#	the socket is missing or refuses - mdnsd not running is a
#	normal condition the caller decides about [MDNS-Control §1].
sub connect ($self)
{
	my $sock = IO::Socket::UNIX->new(
		Type => SOCK_STREAM,
		Peer => $self->{socket_path},
	    )
	    or do {
		$self->{error} = "connect $self->{socket_path}: $!";
		return;
	    };

	$self->{imsg} = FuguLib::Imsg->new( fh => $sock );

	return 1;
}

# $self->publish_service(%args):
#	name    => $instance	service instance name (also the group
#				name; mdnsd requires them equal
#				[MDNS-Control §7])
#	app     => $app		application protocol, no underscore
#	proto   => $proto	'tcp' or 'udp'
#	port    => $port	port number
#	txt     => $string	formatted TXT string [MDNS-Control §5]
#	timeout => $secs	overrides the object default
#	Send the ADD/ADD_SERVICE/COMMIT sequence and wait for
#	GROUP_PUBLISHED. Returns 1 once published; undef on invalid
#	arguments, no connection, an error reply, EOF, or timeout,
#	with the reason in ->error.
sub publish_service ( $self, %args )
{
	my $service = $self->_check_service(%args) or return;

	# Republishing on a held connection must go through update_txt:
	# mdnsd silently ignores the duplicate GROUP_ADD, drops the
	# ADD_SERVICE, and answers the COMMIT with a success-looking
	# reply sequence for the old records [MDNS-Control §8]
	if ( $self->{published} ) {
		$self->{error} = 'already published';
		return;
	}

	if ( !$self->{imsg} ) {
		$self->{error} = 'not connected';
		return;
	}

	$self->{service} = $service;

	return $self->_publish( $args{timeout} // $self->{timeout} );
}

# $self->update_txt(%args):
#	txt     => $string	replacement TXT string
#	timeout => $secs	overrides the object default
#	Re-advertise with a new TXT record. Same-socket replacement
#	does not work [MDNS-Control §8], so this withdraws and
#	republishes over a fresh connection, reusing the service
#	parameters from publish_service. A no-op returning 1 while
#	unpublished, mirroring the old mdnsctl wrapper.
sub update_txt ( $self, %args )
{
	return 1 unless $self->{published};

	my $txt = $args{txt} // '';
	if ( length($txt) > TXT_MAX ) {
		$self->{error} = 'txt too long';
		return;
	}

	$self->withdraw;
	$self->{service}{txt} = $txt;
	$self->connect or return;

	return $self->_publish( $args{timeout} // $self->{timeout} );
}

# $self->withdraw:
#	Close the control socket. That is the entire operation: mdnsd
#	kills the connection's groups and sends goodbyes
#	[MDNS-Control §6].
sub withdraw ($self)
{
	if ( $self->{imsg} ) {
		close $self->{imsg}{fh};
		$self->{imsg} = undef;
	}
	$self->{published} = 0;

	return 1;
}

# $self->is_published:
#	True while the service is advertised on a held connection.
sub is_published ($self)
{
	return $self->{published};
}

# $self->error:
#	The most recent failure, for the caller to log.
sub error ($self)
{
	return $self->{error};
}

# $self->_check_service(%args):
#	Validate lengths against the wire field limits - over-length
#	input is an error, never a silent truncation [MDNS-Control §4]
#	- and return the parameter set publish and update reuse.
sub _check_service ( $self, %args )
{
	my %service = (
		name  => $args{name}  // '',
		app   => $args{app}   // '',
		proto => $args{proto} // '',
		port  => $args{port}  // 0,
		txt   => $args{txt}   // '',
	);

	my %max = (
		name => NAME_MAX,
		app  => APP_MAX,
		txt  => TXT_MAX,
	);
	for my $field ( sort keys %max ) {
		next if length( $service{$field} ) <= $max{$field};
		$self->{error} = "$field too long";
		return;
	}
	if ( !length $service{name} ) {
		$self->{error} = 'name required';
		return;
	}
	if ( $service{proto} ne 'tcp' && $service{proto} ne 'udp' ) {
		$self->{error} = 'proto must be tcp or udp';
		return;
	}

	# The wire field is a u16 [MDNS-Control §4]; pack would
	# silently truncate anything wider
	if ( $service{port} !~ /^\d+$/ || $service{port} > 65535 ) {
		$self->{error} = 'port out of range';
		return;
	}

	return \%service;
}

# $self->_publish($timeout):
#	The three-message publish conversation and its reply loop
#	[MDNS-Control §6]. On any failure the connection is closed so
#	mdnsd forgets the half-built group.
sub _publish ( $self, $timeout )
{
	my $s     = $self->{service};
	my $group = pack( 'Z' . GROUP_NAME_LEN, $s->{name} );

	$self->{error} = undef;

	# ADD must precede COMMIT on this connection, unconditionally:
	# committing an unknown group crashes mdnsd [MDNS-Control §9]
	my $sent = $self->{imsg}->send(
		type => IMSG_CTL_GROUP_ADD,
		data => $group
	    )
	    && $self->{imsg}->send(
		type => IMSG_CTL_GROUP_ADD_SERVICE,
		data => $self->_encode_service
	    )
	    && $self->{imsg}->send(
		type => IMSG_CTL_GROUP_COMMIT,
		data => $group
	    );
	if ( !$sent ) {
		$self->{error} = "send: $!";
		$self->withdraw;
		return;
	}

	my $deadline = time + $timeout;
	while (1) {
		my $remaining = $deadline - time;
		if ( $remaining <= 0 ) {
			$self->{error} = 'timeout waiting for reply';
			$self->withdraw;
			return;
		}

		my $reply = $self->{imsg}->recv( timeout => $remaining );
		if ( !defined $reply ) {
			$self->{error} =
			    time >= $deadline
			    ? 'timeout waiting for reply'
			    : 'connection closed by mdnsd';
			$self->withdraw;
			return;
		}

		my $type = $reply->{type};
		if ( $type == IMSG_CTL_GROUP_PUBLISHED ) {
			$self->{published} = 1;
			$self->{error}     = undef;
			return 1;
		}

		# Progress reports are not terminal [MDNS-Control §6.1]
		next
		    if $type == IMSG_CTL_GROUP_PROBING
		    || $type == IMSG_CTL_GROUP_ANNOUNCING;

		$self->{error} =
		      $type == IMSG_CTL_GROUP_ERR_COLLISION ? 'name collision'
		    : $type == IMSG_CTL_GROUP_ERR_NOT_FOUND ? 'group not found'
		    : $type == IMSG_CTL_GROUP_ERR_DOUBLE_ADD
		    ? 'group added twice'
		    : "unexpected reply type $type";
		$self->withdraw;
		return;
	}
}

# $self->_encode_service:
#	Encode the stored parameters as one struct mdns_service
#	[MDNS-Control §4]. Lengths were validated in _check_service,
#	so the Z templates never truncate.
sub _encode_service ($self)
{
	my $s   = $self->{service};
	my $buf = pack( SERVICE_TEMPLATE,
		$s->{app}, $s->{proto}, $s->{name}, 0, 0, $s->{port},
		$s->{txt} );

	die 'encoded struct mdns_service is not ' . SERVICE_LEN . ' bytes'
	    if length($buf) != SERVICE_LEN;

	return $buf;
}

1;
