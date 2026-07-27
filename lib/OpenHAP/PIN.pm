# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2025 Dick Olsson <hi@senzilla.io>
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

package OpenHAP::PIN;
use Exporter qw(import);
our @EXPORT_OK = qw(normalize_pin validate_pin);

# Invalid PINs per HAP specification
# These are sequential or trivial patterns that should not be used
use constant INVALID_PINS => qw(
    00000000 11111111 22222222 33333333 44444444
    55555555 66666666 77777777 88888888 99999999
    12345678 87654321
);

# normalize_pin($pin):
#	Strip dashes and spaces from PIN for internal use
#	Returns: 8-digit numeric string or undef if invalid format
sub normalize_pin ($pin)
{
	return unless defined $pin;

	# Strip dashes and spaces
	$pin =~ s/[-\s]//g;

	# Verify it's exactly 8 digits
	return unless $pin =~ /^\d{8}$/;

	return $pin;
}

# validate_pin($pin):
#	Validate PIN meets HAP requirements
#	Returns: 1 if valid, undef if invalid
sub validate_pin ($pin)
{
	# Normalize first
	my $normalized = normalize_pin($pin);
	return unless defined $normalized;

	# Check against invalid PINs list
	my %invalid = map { $_ => 1 } INVALID_PINS;
	return if exists $invalid{$normalized};

	return 1;
}

1;
