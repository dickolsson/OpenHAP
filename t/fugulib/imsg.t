#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for FuguLib::Imsg framing over a socketpair

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);

use_ok('FuguLib::Imsg');

# pair(): two FuguLib::Imsg objects over a fresh socketpair
sub pair ()
{
	socketpair( my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
	    or die "socketpair: $!";
	return (
		FuguLib::Imsg->new( fh => $a ),
		FuguLib::Imsg->new( fh => $b ),
	);
}

subtest 'round-trip over a socketpair' => sub {
	my ( $tx, $rx ) = pair();

	ok( $tx->send( type => 8, data => 'payload' ), 'send succeeds' );
	my $msg = $rx->recv( timeout => 5 );
	ok( defined $msg, 'recv returns a message' );
	is( $msg->{type}, 8,         'type round-trips' );
	is( $msg->{data}, 'payload', 'payload round-trips' );

	ok( $tx->send( type => 11 ), 'empty payload sends' );
	$msg = $rx->recv( timeout => 5 );
	is( $msg->{type}, 11, 'empty-payload type round-trips' );
	is( $msg->{data}, '', 'empty payload round-trips' );
};

subtest 'oversized payload is refused, not truncated' => sub {
	my ( $tx, $rx ) = pair();

	my $max =
	    FuguLib::Imsg::MAX_IMSGSIZE() - FuguLib::Imsg::HEADER_SIZE();
	ok( !defined $tx->send( type => 1, data => 'x' x ( $max + 1 ) ),
		'payload over the bound returns undef' );
	ok( $tx->send( type => 1, data => 'x' x $max ),
		'payload at the bound is accepted' );
	my $msg = $rx->recv( timeout => 5 );
	is( length( $msg->{data} ), $max, 'maximum payload round-trips' );
};

subtest 'truncated header then EOF returns undef' => sub {
	socketpair( my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
	    or die "socketpair: $!";
	my $rx = FuguLib::Imsg->new( fh => $b );

	syswrite $a, "\x08\x00\x00\x00\x10\x00\x00\x00";    # 8 of 16 bytes
	close $a;
	ok( !defined $rx->recv( timeout => 5 ),
		'EOF mid-header yields undef, not a hang or a die' );
};

subtest 'two messages in one read' => sub {
	my ( $tx, $rx ) = pair();

	ok( $tx->send( type => 15, data => 'first' ),  'first sent' );
	ok( $tx->send( type => 16, data => 'second' ), 'second sent' );

	my $m1 = $rx->recv( timeout => 5 );
	my $m2 = $rx->recv( timeout => 5 );
	is( $m1->{type}, 15,       'first message type' );
	is( $m1->{data}, 'first',  'first message payload' );
	is( $m2->{type}, 16,       'second message type' );
	is( $m2->{data}, 'second', 'second message payload' );
};

subtest 'write after peer close returns undef, does not die' => sub {
	my ( $tx, $rx ) = pair();
	close $rx->{fh};

	my $lived = eval {

		# The first write can land in the socket buffer. A
		# second write always raises EPIPE.
		$tx->send( type => 1, data => 'x' );
		my $r = $tx->send( type => 1, data => 'x' );
		ok( !defined $r, 'send to a closed peer returns undef' );
		1;
	};
	ok( $lived, 'no SIGPIPE death and no exception' ) or diag $@;
};

subtest 'recv timeout returns undef without data' => sub {
	my ( $tx, $rx ) = pair();

	my $start = time;
	ok( !defined $rx->recv( timeout => 0.2 ), 'timeout yields undef' );
	cmp_ok( time - $start, '<', 5, 'returned well before forever' );
};

subtest 'invalid length poisons the connection' => sub {
	socketpair( my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
	    or die "socketpair: $!";
	my $rx = FuguLib::Imsg->new( fh => $b );

	# A len of 4 is less than IMSG_HEADER_SIZE. The framing makes
	# it invalid.
	syswrite $a, pack( 'L4', 1, 4, 0, 0 );
	ok( !defined $rx->recv( timeout => 5 ), 'invalid len yields undef' );
	ok( !defined $rx->recv( timeout => 0.1 ),
		'connection stays dead afterwards' );
	ok( $rx->is_dead, 'and is_dead reports it' );
};

subtest 'the header carries peerid and pid' => sub {
	my ( $tx, $rx ) = pair();

	ok( $tx->send( type => 3, data => 'x', peerid => 4242 ),
		'send takes a peerid' );
	my $msg = $rx->recv( timeout => 5 );
	is( $msg->{peerid}, 4242, 'peerid round-trips' );
	is( $msg->{pid},    $$,   'pid names the sender' );

	# The default is 0, as the protocols that do not correlate
	# expect
	$tx->send( type => 3 );
	is( $rx->recv( timeout => 5 )->{peerid}, 0, 'the default peerid is 0' );

	# Several outstanding requests keep their own correlation
	$tx->send( type => 1, data => 'a', peerid => 1 );
	$tx->send( type => 1, data => 'b', peerid => 2 );
	is( $rx->recv( timeout => 5 )->{peerid}, 1, 'first peerid' );
	is( $rx->recv( timeout => 5 )->{peerid}, 2, 'second peerid' );
};

subtest 'close ends the connection for both sides' => sub {
	my ( $tx, $rx ) = pair();

	ok( !$tx->is_dead, 'a fresh object is not dead' );
	ok( $tx->close,    'close returns 1' );
	ok( $tx->is_dead,  'and the object is dead' );
	ok( $tx->close,    'a second close is a success' );

	ok( !defined $tx->send( type => 1 ), 'send after close fails' );

	# The peer sees the end of the stream
	ok( !defined $rx->recv( timeout => 5 ), 'the peer reads EOF' );
	ok( $rx->is_dead, 'and the peer connection is dead' );
};

done_testing();
