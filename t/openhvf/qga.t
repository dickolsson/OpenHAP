#!/usr/bin/env perl
# ex:ts=8 sw=4:

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use IO::Socket::UNIX;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);

use_ok('OpenHVF::QGA');

# A QGA object wired to one end of a socketpair, with the peer returned
# so the test can play the guest agent. Built through IO::Socket so both
# ends autoflush exactly as the sockets the module itself opens do.
sub paired_qga
{
	my ($ours, $theirs) =
	    IO::Socket::UNIX->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	return if !defined $ours;

	my $qga = OpenHVF::QGA->new('/tmp/test-qga.sock');
	$qga->{sock} = $ours;

	return ($qga, $theirs);
}

# Test object creation
{
	my $qga = OpenHVF::QGA->new('/tmp/test-qga.sock');
	ok(defined $qga, 'QGA object created');
	is($qga->socket_path, '/tmp/test-qga.sock', 'Socket path set correctly');
	is($qga->{connected}, 0, 'Not connected initially');
}

# Test connection failure to non-existent socket
{
	my $qga = OpenHVF::QGA->new('/tmp/nonexistent-qga.sock');
	is($qga->open_connection, 0, 'Connection fails for non-existent socket');
	ok(!$qga->is_available, 'is_available false without a socket');
}

# Test run_command on unconnected socket returns undef
{
	my $qga = OpenHVF::QGA->new('/tmp/test-qga.sock');
	is($qga->run_command('guest-ping'), undef,
	    'run_command returns undef when not connected');
}

# A silent peer must not stall the caller. IO::Socket's timeout() does
# not bound a read, so this used to block forever - and nothing answers
# whenever the guest runs no agent, because QEMU, not the guest, serves
# the socket. That is how 'openhvf down' hung instead of falling back to
# a force stop. Bounded here directly: the module's own READ_TIMEOUT is
# too long to spend in a unit test.
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

# A complete line is returned without its terminator, and anything the
# peer sent past the newline stays for the next read.
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

# A line split across segments is reassembled rather than truncated
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
