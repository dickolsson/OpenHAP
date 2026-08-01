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

package FuguLib::Sandbox;

# FuguLib::Sandbox - pledge(2) and unveil(2) as a platform
# abstraction. The calls are real on OpenBSD. Everywhere else they are
# no-ops that return success. Thus callers never write $^O checks. The
# class methods are stateless. They wrap two process-global syscalls.
# Failures die. A daemon that cannot restrict itself must not start.
# There is no force or warn-and-continue mode. The module never logs.
# A caller or a test uses is_supported, not a log line, to tell
# enforcement from emulation.

use constant SUPPORTED => $^O eq 'openbsd';

BEGIN {
	if (SUPPORTED) {

		# These are base-system modules. A load failure on
		# OpenBSD means a broken perl, not an unsupported
		# system. Thus the failure is deliberately fatal, not
		# a runtime fallback to "no protection".
		require OpenBSD::Pledge;
		require OpenBSD::Unveil;
	}
}

# FuguLib::Sandbox->is_supported:
#	The method returns true only where the system enforces pledge
#	and unveil.
sub is_supported ($)
{
	return SUPPORTED;
}

# FuguLib::Sandbox->pledge(%args):
#	promises => $string	space-separated promise set
#	Restrict the process to the promised syscalls. The method
#	returns 1. On failure it dies with the promise string and $!.
sub pledge ( $, %args )
{
	my $promises = $args{promises};
	die 'promises parameter required'
	    unless defined $promises && length $promises;

	return 1 unless SUPPORTED;

	OpenBSD::Pledge::pledge( split ' ', $promises )
	    or die "pledge($promises): $!";

	return 1;
}

# FuguLib::Sandbox->unveil(%args):
#	paths   => [[$path, $perms], ...]	ordered unveil list
#	on_skip => sub($path)			runs for each skipped path
#	Restrict the filesystem view. The list is ordered, not a hash.
#	unveil(2) replaces rather than merges a path's permissions.
#	Thus the parent-then-child order is load-bearing, and hash key
#	order would randomise it. Each entry may carry
#	{ optional => 1 } as a third element. The method skips a
#	missing optional path and reports it through on_skip. A
#	missing required path dies. To accept a typo'd path silently
#	is the failure mode that makes unveil useless. The method
#	returns 1, or dies and names the failing path.
sub unveil ( $, %args )
{
	my $paths = $args{paths};
	die 'paths parameter required (arrayref of pairs)'
	    unless ref $paths eq 'ARRAY';

	for my $entry (@$paths) {
		die 'unveil entry must be [$path, $perms]'
		    unless ref $entry eq 'ARRAY'
		    && defined $entry->[0]
		    && defined $entry->[1]
		    && ( @$entry < 3 || ref $entry->[2] eq 'HASH' );
	}

	return 1 unless SUPPORTED;

	# Settle every disposition before the first unveil(2) call.
	# That call already hides the rest of the filesystem. Thus a
	# later existence test would see nothing. The check also
	# carries the required-path contract. unveil(2) itself succeeds
	# on a missing final component when the parent exists. Thus the
	# syscall alone would silently accept a typo'd required path.
	my @apply;
	for my $entry (@$paths) {
		my ( $path, $perms, $opts ) = @$entry;

		if ( !-e $path ) {
			if ( $opts->{optional} ) {
				$args{on_skip}->($path) if $args{on_skip};
				next;
			}
			die "unveil($path, $perms): required path is absent";
		}
		push @apply, [ $path, $perms ];
	}

	for my $entry (@apply) {
		my ( $path, $perms ) = @$entry;

		OpenBSD::Unveil::unveil( $path, $perms )
		    or die "unveil($path, $perms): $!";
	}

	return 1;
}

# FuguLib::Sandbox->unveil_lock:
#	Forbid further unveil calls. The call must reach the C layer
#	with no arguments at all. unveil(undef, undef) arrives as
#	unveil("", "") and fails with ENOENT. The method returns 1.
#	It dies on failure.
sub unveil_lock ($)
{
	return 1 unless SUPPORTED;

	OpenBSD::Unveil::unveil()
	    or die "unveil lock: $!";

	return 1;
}

1;
