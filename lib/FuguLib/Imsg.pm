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

package FuguLib::Imsg;

use Errno qw(EBADMSG EMSGSIZE EPIPE);
use IO::Select;
use Time::HiRes qw(time);

# FuguLib::Imsg - the base-system imsg(3) framing over a connected
# stream socket. Each message is a fixed native-endian header followed
# by a payload. The module does serialization only. It never opens or
# names a socket itself, and it never logs. The callers decide what an
# error means.
#
# The wire format is in spec/MDNS-Imsg.md in the OpenHAP repository.
# That document is a curated reference, not an installed manual.

# Header and size constants per spec/MDNS-Imsg.md §1-§2. The header
# has four native uint32 fields: type, len, peerid, pid. The len field
# counts the whole message, and MAX_IMSGSIZE bounds it. The
# HEADER_TEMPLATE pack template pins the field order and widths.
# Change them only against the spec.
use constant {
	HEADER_SIZE     => 16,
	HEADER_TEMPLATE => 'L4',    # type, len, peerid, pid; native order
	MAX_IMSGSIZE    => 16384,
};
use constant MAX_PAYLOAD => MAX_IMSGSIZE - HEADER_SIZE;

# The high bit of len marks fd-passing messages [MDNS-Imsg §2]. The
# protocols this module serves never set it. But a receiver must mask
# it off before it trusts the length.
use constant FD_MARK => 0x80000000;

# FuguLib::Imsg->new(%args):
#	fh => $fh	connected stream socket (required)
#	Make a framing object over an already-connected handle.
sub new ( $class, %args )
{
	my $fh = $args{fh} or die 'fh parameter required';
	binmode $fh;

	return bless {
		fh     => $fh,
		buffer => '',
		dead   => 0,
	}, $class;
}

# _encode_header($type, $len, $peerid, $pid):
#	Encode one header [MDNS-Imsg §1]. This internal seam lets the
#	tests assert the encoded bytes. The tests do not have to
#	scrape a socketpair.
sub _encode_header ( $type, $len, $peerid, $pid )
{
	return pack( HEADER_TEMPLATE, $type, $len, $peerid, $pid );
}

# _decode_header($bytes):
#	Decode one header. The function returns ($type, $len, $peerid,
#	$pid).
sub _decode_header ($bytes)
{
	return unpack( HEADER_TEMPLATE, $bytes );
}

# $self->send(%args):
#	type   => $n	message type (required)
#	data   => $bytes payload (default empty)
#	peerid => $n	caller-chosen correlation value (default 0)
#	Frame and write one message. The method returns 1 on success.
#	It returns undef, with $! set, on an oversized payload, a dead
#	connection, or a write error. A peer that closed the socket
#	shows as EPIPE, not as a fatal SIGPIPE.
#
#	The peerid field is opaque to this module [MDNS-Imsg §1]. A
#	request and response protocol puts its correlation value there
#	and reads it back from recv.
sub send ( $self, %args )
{
	my $type   = $args{type}   // die 'type parameter required';
	my $data   = $args{data}   // '';
	my $peerid = $args{peerid} // 0;

	if ( $self->{dead} ) {
		$! = EPIPE;
		return;
	}
	if ( length($data) > MAX_PAYLOAD ) {
		$! = EMSGSIZE;
		return;
	}

	my $msg =
	    _encode_header( $type, HEADER_SIZE + length($data), $peerid, $$ )
	    . $data;

	local $SIG{PIPE} = 'IGNORE';
	my $off = 0;
	while ( $off < length($msg) ) {
		my $n =
		    syswrite( $self->{fh}, $msg, length($msg) - $off, $off );
		if ( !defined $n ) {
			next if $!{EINTR};
			$self->{dead} = 1;
			return;
		}
		$off += $n;
	}

	return 1;
}

# $self->recv(%args):
#	timeout => $seconds	how long to wait (undef blocks forever)
#	Return one whole message as a hashref with type, peerid, pid
#	and data. The method accumulates short reads across calls. It
#	returns undef on timeout, clean EOF, or an unrecoverable
#	framing error. For a framing error, it sets $! to EBADMSG and
#	marks the connection dead per spec/MDNS-Imsg.md §4.
#
#	A timeout of 0 takes what already arrived and returns. This is
#	the form for an event loop, which knows the socket is readable
#	and must not sit in this call. A partial message stays in the
#	buffer for the next call.
sub recv ( $self, %args )
{
	my $timeout  = $args{timeout};
	my $deadline = defined $timeout ? time + $timeout : undef;
	my $polled   = 0;

	while (1) {
		if ( my $msg = $self->_extract_message ) {
			return $msg;
		}
		return if $self->{dead};

		if ( defined $deadline ) {
			my $remaining = $deadline - time;

			# A zero timeout still gets one poll. The
			# caller asked for what already arrived, not
			# for nothing at all, and by the time the
			# deadline is computed it has already passed.
			$remaining = 0 if $remaining < 0 && !$polled;
			return         if $remaining < 0;

			# can_read(0) polls and does not wait
			my @ready =
			    IO::Select->new( $self->{fh} )
			    ->can_read($remaining);
			$polled++;
			return unless @ready;
		}

		my $n = sysread( $self->{fh}, my $chunk, 65536 );
		if ( !defined $n ) {
			next if $!{EINTR};
			$self->{dead} = 1;
			return;
		}
		if ( $n == 0 ) {

			# A clean EOF occurs only on a message boundary.
			# An EOF with buffered bytes is a truncated
			# message either way.
			$self->{dead} = 1;
			return;
		}
		$self->{buffer} .= $chunk;
	}
}

# $self->_extract_message:
#	Pop one complete message off the buffer. Return undef when
#	more bytes are necessary. An invalid length marks the
#	connection dead [MDNS-Imsg §2].
sub _extract_message ($self)
{
	return if length( $self->{buffer} ) < HEADER_SIZE;

	my ( $type, $len, $peerid, $pid ) =
	    _decode_header( substr( $self->{buffer}, 0, HEADER_SIZE ) );
	$len &= ~FD_MARK;

	if ( $len < HEADER_SIZE || $len > MAX_IMSGSIZE ) {
		$self->{dead} = 1;
		$! = EBADMSG;
		return;
	}
	return if length( $self->{buffer} ) < $len;

	my $data = substr( $self->{buffer}, HEADER_SIZE, $len - HEADER_SIZE );
	substr( $self->{buffer}, 0, $len ) = '';

	return {
		type   => $type,
		peerid => $peerid,
		pid    => $pid,
		data   => $data,
	};
}

# $self->close:
#	Close the socket and mark the connection dead. The method is
#	idempotent and returns 1. A caller that owns the socket closes
#	it here, and never by reaching into the object.
sub close ($self)
{
	if ( $self->{fh} ) {
		CORE::close $self->{fh};
		$self->{fh} = undef;
	}
	$self->{dead}   = 1;
	$self->{buffer} = '';

	return 1;
}

# $self->is_dead:
#	Report if the connection can no longer carry a message. A
#	close, an EOF, a write error, or a framing error all lead
#	here.
sub is_dead ($self)
{
	return $self->{dead} ? 1 : 0;
}

1;
