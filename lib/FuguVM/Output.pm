# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2024 Dick Olsson <hi@senzilla.io>
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

package FuguVM::Output;

use FuguLib::Log;

sub new ( $class, $quiet = 0 )
{
	my $mode =
	    $quiet ? FuguLib::Log::MODE_QUIET : FuguLib::Log::MODE_STDERR;
	my $log = FuguLib::Log->new(
		mode  => $mode,
		level => 'info',
		ident => 'fuguvm',
	);

	bless { log => $log }, $class;
}

sub info ( $self, $message )
{
	$self->{log}->info($message);
}

sub error ( $self, $message )
{
	$self->{log}->error($message);
}

sub warn ( $self, $message )
{
	$self->{log}->warning($message);
}

sub success ( $self, $message )
{
	$self->{log}->info($message);
}

sub data ( $self, $hashref )
{
	$self->_format_data($hashref);
}

sub _format_data ( $self, $data, $indent = 0 )
{
	my $prefix = '  ' x $indent;
	my @lines;

	for my $key ( sort keys %$data ) {
		my $value = $data->{$key};

		if ( ref $value eq 'HASH' ) {
			push @lines, "$prefix$key:";
			push @lines,
			    $self->_format_data_lines( $value, $indent + 1 );
		}
		elsif ( ref $value eq 'ARRAY' ) {
			push @lines, "$prefix$key:";
			for my $item (@$value) {
				if ( ref $item ) {
					push @lines,
					    $self->_format_data_lines( $item,
						$indent + 1 );
				}
				else {
					push @lines, "$prefix  - $item";
				}
			}
		}
		else {
			$value //= '';
			push @lines, "$prefix$key: $value";
		}
	}

	if ( $indent == 0 ) {

		# Top level: log all the lines
		for my $line (@lines) {
			$self->{log}->info($line);
		}
	}
	else {

		# Nested: return the lines to the parent
		return @lines;
	}
}

sub _format_data_lines ( $self, $data, $indent = 0 )
{
	my $prefix = '  ' x $indent;
	my @lines;

	for my $key ( sort keys %$data ) {
		my $value = $data->{$key};

		if ( ref $value eq 'HASH' ) {
			push @lines, "$prefix$key:";
			push @lines,
			    $self->_format_data_lines( $value, $indent + 1 );
		}
		elsif ( ref $value eq 'ARRAY' ) {
			push @lines, "$prefix$key:";
			for my $item (@$value) {
				if ( ref $item ) {
					push @lines,
					    $self->_format_data_lines( $item,
						$indent + 1 );
				}
				else {
					push @lines, "$prefix  - $item";
				}
			}
		}
		else {
			$value //= '';
			push @lines, "$prefix$key: $value";
		}
	}

	return @lines;
}

sub pid ( $self, $name, $pid )
{
	$self->{log}->info("Started $name (PID: $pid)");
}

1;
