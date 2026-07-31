#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use IO::Socket::UNIX;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);

use_ok('FuguVM::QMP');

# A QMP object wired to one end of a socketpair, with the peer returned
# so the test can play QEMU. Built through IO::Socket so both ends
# autoflush exactly as the sockets the module itself opens do.
sub paired_qmp
{
	my ($ours, $theirs) =
	    IO::Socket::UNIX->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	return if !defined $ours;

	my $qmp = FuguVM::QMP->new('/tmp/test-qmp.sock');
	$qmp->{sock} = $ours;

	return ($qmp, $theirs);
}

# Test object creation
{
	my $qmp = FuguVM::QMP->new('/tmp/test-qmp.sock');
	ok(defined $qmp, 'QMP object created');
	is($qmp->{socket_path}, '/tmp/test-qmp.sock', 'Socket path set correctly');
	is($qmp->{connected}, 0, 'Not connected initially');
}

# Test connection failure to non-existent socket
{
	my $qmp = FuguVM::QMP->new('/tmp/nonexistent-qmp.sock');
	my $result = $qmp->open_connection;
	is($result, 0, 'Connection fails for non-existent socket');
}

# Test disconnect on unconnected socket
{
	my $qmp = FuguVM::QMP->new('/tmp/test-qmp.sock');
	my $result = $qmp->disconnect;
	ok(defined $result, 'Disconnect returns object');
	is($qmp->{connected}, 0, 'Still not connected after disconnect');
}

# Test run_command on unconnected socket returns undef
{
	my $qmp = FuguVM::QMP->new('/tmp/test-qmp.sock');
	my $result = $qmp->run_command('query-status');
	is($result, undef, 'run_command returns undef when not connected');
}

# A silent peer must not stall the caller. IO::Socket's timeout() does
# not bound a read, so this used to block forever: 'fuguvm down' hung
# instead of falling back to a force stop.
{
	my ($qmp, $peer) = paired_qmp();
	SKIP: {
		skip 'cannot create socketpair', 2 unless $qmp;

		my $start = time;
		my $line = $qmp->_read_line(0.5);
		my $spent = time - $start;

		is($line, undef, 'read returns undef when nothing answers');
		ok($spent < 10, sprintf('read is bounded (%.1fs)', $spent));
	}
}

# A complete line is returned without its terminator, and anything the
# peer sent past the newline stays for the next read.
{
	my ($qmp, $peer) = paired_qmp();
	SKIP: {
		skip 'cannot create socketpair', 3 unless $qmp;

		print $peer qq({"QMP":{}}\n{"return":{}}\n);

		is($qmp->_read_line(5), '{"QMP":{}}', 'first line read');
		is($qmp->_read_line(5), '{"return":{}}',
		    'second line served from the buffer, not lost');

		close $peer;
		is($qmp->_read_line(0.5), undef, 'undef at EOF');
	}
}

# Whole-response path: a well-formed reply decodes, a silent peer does
# not hang run_command.
{
	my ($qmp, $peer) = paired_qmp();
	SKIP: {
		skip 'cannot create socketpair', 3 unless $qmp;

		print $peer qq({"return":{"running":true}}\n);
		my $result = $qmp->run_command('query-status');
		ok($result && $result->{return}{running},
		    'run_command decodes a reply');

		my $start = time;
		is($qmp->run_command('query-status'), undef,
		    'run_command returns undef when the peer is silent');
		ok(time - $start < 30, 'and does so under its read timeout');
	}
}

# disconnect must not leave a stale buffer behind for a later connection
{
	my ($qmp, $peer) = paired_qmp();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qmp;

		print $peer qq({"a":1}\n{"b":2}\n);
		$qmp->_read_line(5);
		$qmp->disconnect;
		is($qmp->{buffer}, '', 'disconnect clears the read buffer');
	}
}

done_testing();
