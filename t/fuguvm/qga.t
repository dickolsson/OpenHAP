#!/usr/bin/env perl
# ex:ts=8 sw=4:
# The guest-agent command set. The transport belongs to
# Fugu::JSONSocket and is proven in t/fugu/jsonsocket.t.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use IO::Socket::UNIX;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use_ok('FuguVM::QGA');

# paired_qga(): a QGA object wired to one end of a socketpair, and the
# peer that plays the guest agent.
sub paired_qga ()
{
	my ( $ours, $theirs ) =
	    IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC );
	return if !defined $ours;

	my $qga = FuguVM::QGA->new('/tmp/test-qga.sock');
	$qga->{socket}{sock} = $ours;

	return ( $qga, $theirs );
}

# Test object creation
{
	my $qga = FuguVM::QGA->new('/tmp/test-qga.sock');
	ok( defined $qga, 'QGA object created' );
	is( $qga->socket_path, '/tmp/test-qga.sock', 'Socket path set correctly' );
}

# Test connection failure to non-existent socket
{
	my $qga = FuguVM::QGA->new('/tmp/nonexistent-qga.sock');
	is( $qga->open_connection, 0, 'Connection fails for non-existent socket' );
	ok( !$qga->is_available, 'is_available false without a socket' );
}

# Test run_command on unconnected socket returns undef
{
	my $qga = FuguVM::QGA->new('/tmp/test-qga.sock');
	is( $qga->run_command('guest-ping'),
		undef, 'run_command returns undef when not connected' );
}

# ping tells an answer from an error
{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 2 unless $qga;

		print {$peer} qq({"return":{}}\n);
		ok( $qga->ping, 'ping succeeds on a reply' );

		print {$peer} qq({"error":{"class":"CommandNotFound"}}\n);
		ok( !$qga->ping, 'and fails on an error' );
	}
}

# The freeze and thaw commands return the filesystem count
{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 5 unless $qga;

		print {$peer} qq({"return":3}\n);
		is( $qga->freeze_filesystems, 3, 'freeze reports the count' );

		print {$peer} qq({"return":3}\n);
		is( $qga->thaw_filesystems, 3, 'thaw reports the count' );

		print {$peer} qq({"return":"frozen"}\n);
		is( $qga->fsfreeze_status, 'frozen', 'the status reads back' );

		print {$peer} qq({"error":{"class":"GenericError"}}\n);
		is( $qga->freeze_filesystems, undef, 'an error is not a count' );

		print {$peer} qq({"error":{"class":"GenericError"}}\n);
		is( $qga->fsfreeze_status, undef, 'nor a status' );
	}
}

# sync runs a command in the guest and waits for it to finish. The
# guest-sync command synchronizes the protocol, not the filesystems,
# so the real sync goes through guest-exec.
{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qga;

		print {$peer} qq({"return":{"pid":42}}\n);
		print {$peer} qq({"return":{"exited":true,"exitcode":0}}\n);
		ok( $qga->sync, 'sync reports success on exit code 0' );
	}
}

{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qga;

		print {$peer} qq({"return":{"pid":42}}\n);
		print {$peer} qq({"return":{"exited":true,"exitcode":1}}\n);
		ok( !$qga->sync, 'and failure on a non-zero exit code' );
	}
}

{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 1 unless $qga;

		print {$peer} qq({"error":{"class":"GenericError"}}\n);
		ok( !$qga->sync, 'a refused guest-exec is a failed sync' );
	}
}

# shutdown sends its request and does not wait: the guest goes down at
# once and never answers.
{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 2 unless $qga;

		ok( $qga->shutdown, 'shutdown returns success with no reply' );

		my $line = <$peer>;
		like( $line, qr/guest-shutdown/, 'and the request went out' );
	}
}

# A silent peer must not stall the caller. Nothing answers when the
# guest runs no agent, because QEMU, not the guest, serves the socket.
# Thus 'fuguvm down' hung and never fell back to a force stop.
{
	my ( $qga, $peer ) = paired_qga();
	SKIP: {
		skip 'cannot create socketpair', 2 unless $qga;

		# The module's own timeout is too long for a unit test
		$qga->{socket}{timeout} = 0.5;

		my $start = time;
		ok( !$qga->ping, 'a silent peer gives a failure, not a hang' );
		ok( time - $start < 10, 'and it returned near the deadline' );
	}
}

done_testing();
