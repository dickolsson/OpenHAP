# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@ekkis.net>
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

package OpenHAP::Test::Controller::SRP;

use Math::BigInt;
use Digest::SHA qw(sha512);
use OpenHAP::Crypto;
use OpenHAP::PIN qw(normalize_pin);

# SRP-6a client role for tests (HAP-Pairing.md §2.5): the controller
# side of the exchange OpenHAP::SRP serves. Same 3072-bit RFC 5054
# group, SHA-512 hash, and 384-byte padding rules as the server.

use constant N_LEN => 384;

sub _b2i ($bytes)
{
	return Math::BigInt->from_hex( unpack( 'H*', $bytes ) );
}

sub _i2b ( $int, $length = undef )
{
	my $hex = $int->as_hex();
	$hex =~ s/^0x//;
	$hex = '0' . $hex if length($hex) % 2;
	my $bytes = pack( 'H*', $hex );
	if ( defined $length && length($bytes) < $length ) {
		$bytes = ( "\x00" x ( $length - length($bytes) ) ) . $bytes;
	}
	return $bytes;
}

sub new ( $class, %args )
{
	my $password = normalize_pin( $args{password} ) // $args{password};

	my $self = bless {
		username => $args{username} // 'Pair-Setup',
		password => $password,

		N => _b2i($OpenHAP::Crypto::N_3072),
		g => Math::BigInt->new(5),

		a  => undef,
		A  => undef,
		K  => undef,
		M1 => undef,
	}, $class;

	return $self;
}

# $self->compute_public():
#	Generate the ephemeral secret a and return the padded public
#	value A = g^a mod N (384 bytes).
sub compute_public ($self)
{
	my $a_bytes = OpenHAP::Crypto::generate_random_bytes(32);
	$self->{a} = _b2i($a_bytes);
	$self->{A} = $self->{g}->copy->bmodpow( $self->{a}, $self->{N} );

	return _i2b( $self->{A}, N_LEN );
}

# $self->compute_proof($salt, $B_bytes):
#	Complete the client side with the server's salt and public key
#	B: derive the session key K and return the client proof M1.
#	Returns undef if B mod N == 0 (bogus server value).
sub compute_proof ( $self, $salt, $B_bytes )
{
	die 'SRP: compute_public not called' unless defined $self->{A};

	my $N = $self->{N};
	my $g = $self->{g};
	my $B = _b2i($B_bytes);

	return if ( $B % $N )->is_zero();

	# u = H(PAD(A) | PAD(B))
	my $u =
	    _b2i( sha512( _i2b( $self->{A}, N_LEN ) . _i2b( $B, N_LEN ) ) );

	# x = H(s | H(I ":" P)), k = H(N | PAD(g))
	my $x = _b2i(
		sha512( $salt . sha512("$self->{username}:$self->{password}") )
	);
	my $k = _b2i( sha512( _i2b($N) . _i2b( $g, N_LEN ) ) );

	# S = (B - k*g^x)^(a + u*x) mod N
	my $gx   = $g->copy->bmodpow( $x, $N );
	my $base = ( $B - ( $k * $gx ) ) % $N;
	my $S    = $base->bmodpow( $self->{a} + $u * $x, $N );

	$self->{K} = sha512( _i2b($S) );

	# M1 = H(H(N) xor H(g) | H(I) | s | PAD(A) | PAD(B) | K)
	$self->{M1} =
	    sha512( ( sha512( _i2b($N) ) ^. sha512( _i2b($g) ) )
		. sha512( $self->{username} )
		    . $salt
		    . _i2b( $self->{A}, N_LEN )
		    . _i2b( $B,         N_LEN )
		    . $self->{K} );

	return $self->{M1};
}

# $self->verify_server_proof($M2):
#	Check the server proof M2 = H(PAD(A) | M1 | K).
sub verify_server_proof ( $self, $M2 )
{
	die 'SRP: compute_proof not called' unless defined $self->{M1};

	my $expected =
	    sha512( _i2b( $self->{A}, N_LEN ) . $self->{M1} . $self->{K} );

	return $expected eq ( $M2 // '' );
}

# $self->session_key():
#	Return the shared session key K (64 bytes).
sub session_key ($self)
{
	return $self->{K};
}

1;
