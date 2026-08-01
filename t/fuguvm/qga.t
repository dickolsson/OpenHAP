#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use IO::Socket::UNIX;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);

use_ok('FuguVM::QGA');

# A QGA object wired to one end of a socketpair. The helper also
# returns the peer, so the test can play the guest agent. It builds
# the pair through IO::Socket. Thus both ends autoflush exactly as
# the sockets the module itself opens do.
sub paired_qga
{
	my ($ours, $theirs) =
	    IO::Socket::UNIX->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	return if !defined $ours;

	my $qga = FuguVM::QGA->new('/tmp/test-qga.sock');
	$qga->{sock} = $ours;

	return ($qga, $theirs);
}

# Test object creation
{
	my $qga = FuguVM::QGA->new('/tmp/test-qga.sock');
	ok(defined $qga, 'QGA object created');
	is($qga->socket_path, '/tmp/test-qga.sock', 'Socket path set correctly');
	is($qga->{connected}, 0, 'Not connected initially');
}

# Test connection failure to non-existent socket
{
	my $qga = FuguVM::QGA->new('/tmp/nonexistent-qga.sock');
	is($qga->open_connection, 0, 'Connection fails for non-existent socket');
	ok(!$qga->is_available, 'is_available false without a socket');
}

# Test run_command on unconnected socket returns undef
{
	my $qga = FuguVM::QGA->new('/tmp/test-qga.sock');
	is($qga->run_command('guest-ping'), undef,
	    'run_command returns undef when not connected');
}

# A silent peer must not stall the caller. IO::Socket's timeout()
# does not bound a read. Thus this used to block forever. Nothing
# answers when the guest runs no agent, because QEMU, not the guest,
# serves the socket. Thus 'fuguvm down' hung and did not fall back
# to a force stop. The test bounds the read directly. The module's
# own READ_TIMEOUT is too long for a unit test.
{
	my ($qga, $peer) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 2 unless $qga;

		my $start = time;
		my $line = $qga->_read_line(0.5);
		my $spent = time - $start;

		is($line, undef, 'read returns undef when nothing answers');
		ok($spent < 10, sprintf('read is bounded (%.1fs)', $spent));
	}
}

# The read returns a complete line without its terminator. Anything
# the peer sent past the newline stays for the next read.
{
	my ($qga, $peer) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 3 unless $qga;

		print $peer qq({"return":{}}\n{"return":{"pid":7}}\n);

		is($qga->_read_line(5), '{"return":{}}', 'first line read');
		is($qga->_read_line(5), '{"return":{"pid":7}}',
		    'second line served from the buffer, not lost');

		close $peer;
		is($qga->_read_line(0.5), undef, 'undef at EOF');
	}
}

# The read reassembles a line split across segments and does not
# truncate it
{
	my ($qga, $peer) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qga;

		print $peer '{"return":';
		print $peer qq({"pid":9}}\n);

		is($qga->_read_line(5), '{"return":{"pid":9}}',
		    'partial reads are reassembled');
	}
}

# Whole-response path: a well-formed reply decodes
{
	my ($qga, $peer) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qga;

		print $peer qq({"return":{"pid":42}}\n);
		my $result = $qga->run_command('guest-exec', {path => '/bin/sync'});
		is($result->{return}{pid}, 42, 'run_command decodes a reply');
	}
}

# disconnect must not leave a stale buffer behind for a later connection
{
	my ($qga, $peer) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qga;

		print $peer qq({"a":1}\n{"b":2}\n);
		$qga->_read_line(5);
		$qga->disconnect;
		is($qga->{buffer}, '', 'disconnect clears the read buffer');
	}
}

done_testing();
