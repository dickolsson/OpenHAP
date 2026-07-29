#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Integration test: the daemon really pledges and unveils.
#
# A pledge violation kills the process, so "the daemon is alive and its
# trace shows no violation" is satisfied identically by a correctly
# pledged daemon and a completely unpledged one - a null test. What is
# observable is the syscall itself: this file traces the daemon from
# exec with ktrace(1) and asserts that pledge(2) is called with exactly
# the production promise set, that unveil(2) is called for the
# inventory and then locked, and that startup still succeeds in the
# configurations that worked before the sandbox existed. Remove the
# pledge or unveil call from bin/openhapd and the corresponding
# syscall is simply absent from the trace.
#
# Enforcement semantics (a violation aborts; a path outside the view
# is unreachable) are proven by t/fugulib/sandbox.t's forked children.
# No operator-supplied read path exists to probe enforcement through
# the running daemon itself, so this file deliberately does not
# pretend to: the trace proves the daemon's participation, the unit
# tier proves the kernel's.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;
use Time::HiRes qw(sleep);

my $env = OpenHAP::Test::Integration->new;
$env->setup;

my $config_file = '/etc/openhapd.conf';
my $trace       = "/tmp/openhapd-ktrace-$$";
my $daemon      = -x '/usr/local/bin/openhapd'
    ? '/usr/local/bin/openhapd'
    : '/usr/local/sbin/openhapd';

# The traced instance needs the HAP port, so stop the rc daemon first
system('rcctl stop openhapd >/dev/null 2>&1');
sleep 1;

# Run the daemon in the foreground under ktrace; -i follows any
# children (there must be none, and that is asserted below)
my $pid = fork // die "fork: $!";
if ($pid == 0) {
	exec 'ktrace', '-i', '-f', $trace, $daemon, '-f', '-c', $config_file;
	die "exec ktrace: $!";
}

ok($env->wait_for_hap_port, 'traced daemon serves HAP')
    or diag 'daemon did not open the HAP port under ktrace';

# No child processes while it runs (phase 2's contract; what keeps
# proc/exec out of the promise set)
chomp(my $children = `pgrep -P $pid 2>/dev/null`);
is($children, '', 'traced daemon has no child processes');

kill 'TERM', $pid;
waitpid $pid, 0;

my $kdump = `kdump -f $trace 2>&1`;
ok(length $kdump, 'kdump produced a trace');

# The pledge syscall, with the promise-string argument exactly the
# production set: an empty string, a typo, or a stray "proc exec"
# all fail here. The kernel ktraces the copied-in promise string as a
# structure record, which kdump renders as STRU promise="..."
# (sys/kern/kern_pledge.c parsepledges, usr.bin/kdump/ktrstruct.c).
# OpenBSD::Pledge dedupes and sorts the promises before the syscall,
# so the on-the-wire string is the sorted form of the production set.
my $promises = join ' ',
    sort qw(stdio rpath wpath cpath fattr flock inet dns unix);
like($kdump, qr/CALL\s+pledge\(/, 'pledge(2) is called');
like($kdump, qr/STRU\s+promise="\Q$promises\E"/,
     'the promise string is exactly the production set');
unlike($kdump, qr/STRU\s+promise="[^"]*\b(?:proc|exec)\b[^"]*"/,
       'no promise set in the trace grants proc, exec or prot_exec');

# The unveil syscalls: the daemon really builds a view (the permission
# strings appear as STRU flags= records, and db_path's rwc is unique
# to unveil - unlike a NAMI, which any open(2) would also leave), and
# a final unveil(2) with both arguments NULL locks it
my @unveils = $kdump =~ /CALL\s+unveil\(([^)]*)\)/g;
cmp_ok(scalar @unveils, '>=', 3,
       'unveil(2) called for the inventory');
like($kdump, qr/STRU\s+flags="rwc"/,
     'the state directory is unveiled read-write-create');
like($kdump, qr/CALL\s+unveil\(0,0\)/, 'the view is locked');
is($unveils[-1], '0,0', 'the lock is the last unveil call');

# pledge comes after the lock, closing the ordering the call site
# promises
my ($lock_pos, $pledge_pos) = (-1, -1);
while ($kdump =~ /CALL\s+unveil\(0,0\)/g) { $lock_pos   = $-[0] }
while ($kdump =~ /CALL\s+pledge\(/g)      { $pledge_pos = $-[0] }
cmp_ok($lock_pos, '>=', 0, 'lock found in trace');
cmp_ok($pledge_pos, '>', $lock_pos, 'pledge applied after the lock');

unlink $trace;

# Startup still succeeds in every configuration that worked before
# the sandbox: a missing config file must be an optional unveil entry,
# never a refusal to boot ...
my $absent_conf = "/tmp/absent-openhapd-$$.conf";
$pid = fork // die "fork: $!";
if ($pid == 0) {
	open STDOUT, '>', '/dev/null';
	open STDERR, '>', '/dev/null';
	exec $daemon, '-f', '-c', $absent_conf;
	die "exec: $!";
}
ok($env->wait_for_hap_port, 'daemon serves with no config file at all');
kill 'TERM', $pid;
waitpid $pid, 0;

# ... and -f on a host with no daemon log file (the row is optional;
# -f never creates it). The rc daemon holds its own fd, so removing
# the file underneath it is safe, and rcctl start recreates it below.
unlink '/var/log/openhapd.log';
$pid = fork // die "fork: $!";
if ($pid == 0) {
	open STDOUT, '>', '/dev/null';
	open STDERR, '>', '/dev/null';
	exec $daemon, '-f', '-c', $config_file;
	die "exec: $!";
}
ok($env->wait_for_hap_port,
   'daemon serves in -f mode with no /var/log/openhapd.log');
kill 'TERM', $pid;
waitpid $pid, 0;

# Restore the shared daemon for the files that run after this one
system('rcctl start openhapd >/dev/null 2>&1');
$env->wait_for_hap_port or die "daemon not serving after restore\n";

$env->teardown;
done_testing();
