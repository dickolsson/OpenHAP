# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 OpenHAP Contributors
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

package FuguLib::Signal;

# FuguLib::Signal - Robust signal handling for graceful shutdown
#
# The module gives safe signal handler registration with cleanup and
# interrupt support. It makes sure a process can stop cleanly on an
# interrupt and leave no orphaned resources.

# Global flag for interrupt detection
our $interrupted = 0;

# Stack of cleanup handlers
my @cleanup_handlers;

sub new ($class)
{
	bless {
		handlers => {},
		original => {},
	}, $class;
}

# $self->setup_graceful_exit(@signals):
#	Set up handlers for a graceful exit on the specified signals.
#	On a signal, the handler calls all registered cleanup handlers
#	and exits.
sub setup_graceful_exit ( $self, @signals )
{
	for my $sig (@signals) {
		$self->{original}{$sig} = $SIG{$sig} // 'DEFAULT';
		$SIG{$sig} = sub ($signal) {
			$interrupted = 1;
			$self->_run_cleanup_handlers($signal);
			exit 130;    # Standard exit code for SIGINT (128 + 2)
		};
		$self->{handlers}{$sig} = 1;
	}
	return $self;
}

# $self->setup_interrupt_flag(@signals):
#	Set up handlers that set the interrupt flag and do not exit.
#	Long-running operations can then check the flag and exit
#	cleanly.
sub setup_interrupt_flag ( $self, @signals )
{
	for my $sig (@signals) {
		$self->{original}{$sig} = $SIG{$sig} // 'DEFAULT';
		$SIG{$sig}              = sub ($) { $interrupted = 1; };
		$self->{handlers}{$sig} = 1;
	}
	return $self;
}

# $self->add_cleanup($handler):
#	Add a cleanup handler that runs on a signal.
#	The handler receives the signal name as its argument.
sub add_cleanup ( $self, $handler )
{
	push @cleanup_handlers, $handler;
	return $self;
}

# $self->restore():
#	Restore the original signal handlers
sub restore ($self)
{
	for my $sig ( keys %{ $self->{handlers} } ) {
		$SIG{$sig} = $self->{original}{$sig};
	}
	$self->{handlers} = {};
	return $self;
}

# check_interrupted():
#	Check if the process received an interrupt.
#	The function returns true if an interrupt signal arrived.
sub check_interrupted()
{
	return $interrupted;
}

# reset_interrupted():
#	Reset the interrupt flag. Use this for tests or manual
#	control.
sub reset_interrupted()
{
	$interrupted = 0;
}

sub _run_cleanup_handlers ( $self, $signal )
{
	for my $handler (@cleanup_handlers) {
		eval { $handler->($signal); };
	}
	@cleanup_handlers = ();
}

# DESTROY runs when the object goes out of scope
sub DESTROY ($self)
{
	$self->restore;
}

1;
