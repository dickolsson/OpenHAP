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

package FuguVM::Util;

use MIME::Base64 ();

use constant {
	PASSWORD_LENGTH => 32,
	URANDOM_PATH    => '/dev/urandom',
};

# $class->generate_random_bytes($length):
#	Generate $length bytes of cryptographically secure random data
#	from /dev/urandom
sub generate_random_bytes ( $, $length )
{
	open my $fh, '<', URANDOM_PATH
	    or die "Cannot open " . URANDOM_PATH . ": $!";
	read $fh, ( my $bytes ), $length;
	close $fh;

	return $bytes;
}

# $class->generate_password($length):
#	Generate a strong random password of specified length using
#	base64-encoded random bytes (URL-safe variant without padding)
sub generate_password ( $class, $length = PASSWORD_LENGTH )
{
	# Generate more bytes than needed since base64 expands
	my $raw_bytes =
	    $class->generate_random_bytes( ( $length * 3 / 4 ) + 3 );

	# Use URL-safe base64 encoding (no + / = characters)
	my $encoded = MIME::Base64::encode_base64url( $raw_bytes, '' );

	# Trim to requested length
	return substr( $encoded, 0, $length );
}

1;
