#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Conformance tests for spec/MDNS-Imsg.md

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use_ok('FuguLib::Imsg');

# pair(): a FuguLib::Imsg endpoint and the raw peer handle. Thus
# tests can capture and inject wire bytes.
sub pair ()
{
	socketpair( my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
	    or die "socketpair: $!";
	binmode $_ for $a, $b;
	return ( FuguLib::Imsg->new( fh => $a ), $b );
}

subtest '[MDNS-Imsg §1] header is four uint32 fields in order' => sub {
	my $hdr = FuguLib::Imsg::_encode_header( 0x11223344, 0x55667788,
		0x99aabbcc, 0xddeeff00 );

	is( length($hdr), 16, 'IMSG_HEADER_SIZE is 16' );

	# Field layout, not byte order: each field is in its own 4-byte
	# slot at the measured offset. The host byte order does not
	# matter.
	is( unpack( 'L', substr( $hdr, 0, 4 ) ),
		0x11223344, 'type at offset 0' );
	is( unpack( 'L', substr( $hdr, 4, 4 ) ),
		0x55667788, 'len at offset 4' );
	is( unpack( 'L', substr( $hdr, 8, 4 ) ),
		0x99aabbcc, 'peerid at offset 8' );
	is( unpack( 'L', substr( $hdr, 12, 4 ) ),
		0xddeeff00, 'pid at offset 12' );
};

subtest '[MDNS-Imsg §2] len counts header plus payload' => sub {
	my ( $imsg, $peer ) = pair();

	ok( $imsg->send( type => 8, data => 'x' x 240 ), 'sent' );
	sysread $peer, my $wire, 4096;
	is( length($wire), 256, 'whole message is header + payload' );
	my ( $type, $len ) = unpack 'L2', $wire;
	is( $len, 256, 'len field includes the 16-byte header' );
};

subtest '[MDNS-Imsg §2] payload bound is MAX_IMSGSIZE minus header' =>
    sub {
	my ( $imsg, $peer ) = pair();

	ok( !defined $imsg->send( type => 1, data => 'x' x 16369 ),
		'payload above 16368 bytes is refused, not truncated' );
	ok( $imsg->send( type => 1, data => 'x' x 16368 ),
		'payload of exactly 16368 bytes is accepted' );
    };

subtest '[MDNS-Imsg §2] receiver masks the fd mark off len' => sub {
	my ( $imsg, $peer ) = pair();

	# A message whose len carries IMSG_FD_MARK still frames
	# correctly after the receiver masks off the mark
	my $marked = pack( 'L4', 7, ( 16 + 4 ) | 0x80000000, 0, 1 ) . 'data';
	syswrite $peer, $marked;
	my $msg = $imsg->recv( timeout => 5 );
	ok( defined $msg, 'marked message received' );
	is( $msg->{data}, 'data', 'payload length taken from masked len' );
};

subtest '[MDNS-Imsg §2] invalid len drops the connection' => sub {
	my ( $imsg, $peer ) = pair();

	syswrite $peer, pack( 'L4', 1, 15, 0, 1 );    # len < header size
	ok( !defined $imsg->recv( timeout => 5 ), 'len below 16 rejected' );
	ok( !defined $imsg->recv( timeout => 0.1 ), 'connection is dead' );

	( $imsg, $peer ) = pair();
	syswrite $peer, pack( 'L4', 1, 16385, 0, 1 );    # len > MAX_IMSGSIZE
	ok( !defined $imsg->recv( timeout => 5 ),
		'len above MAX_IMSGSIZE rejected' );
};

subtest '[MDNS-Imsg §3] pid is the sender, peerid zero' => sub {
	my ( $imsg, $peer ) = pair();

	ok( $imsg->send( type => 11, data => 'p' ), 'sent' );
	sysread $peer, my $wire, 4096;
	my ( $type, $len, $peerid, $pid ) = unpack 'L4', $wire;
	is( $peerid, 0,  'peerid sent as 0' );
	is( $pid,    $$, 'pid field carries the sending process pid' );
};

subtest '[MDNS-Imsg §4] short reads accumulate across calls' => sub {
	my ( $imsg, $peer ) = pair();

	my $wire = pack( 'L4', 15, 16 + 6, 0, 1 ) . 'abcdef';

	# Send the header split mid-field. Then send the rest.
	syswrite $peer, substr( $wire, 0, 10 );
	ok( !defined $imsg->recv( timeout => 0.1 ),
		'partial header is not a message yet' );
	syswrite $peer, substr( $wire, 10 );
	my $msg = $imsg->recv( timeout => 5 );
	is( $msg->{data}, 'abcdef', 'message assembled across reads' );
};

subtest '[MDNS-Imsg §4] several messages in one read' => sub {
	my ( $imsg, $peer ) = pair();

	my $wire = ( pack( 'L4', 15, 16 + 1, 0, 1 ) . 'a' )
	    . ( pack( 'L4', 16, 16 + 1, 0, 1 ) . 'b' );
	syswrite $peer, $wire;

	my $m1 = $imsg->recv( timeout => 5 );
	my $m2 = $imsg->recv( timeout => 5 );
	is( $m1->{type}, 15,  'first message framed' );
	is( $m2->{type}, 16,  'second message framed from the same read' );
	is( $m2->{data}, 'b', 'boundary fell exactly between messages' );
};

subtest '[MDNS-Imsg §4] EOF mid-message is an error' => sub {
	my ( $imsg, $peer ) = pair();

	syswrite $peer, pack( 'L4', 15, 16 + 100, 0, 1 ) . 'short';
	close $peer;
	ok( !defined $imsg->recv( timeout => 5 ),
		'truncated message yields undef on EOF' );
};

done_testing();
