use v5.36;

package OpenHAP::SRP;

# Prefer the GMP backend. The 3072-bit modular exponentiation of
# SRP is impractically slow in the pure-Perl Calc backend. It
# takes seconds per operation, and far more under emulation.
# 'try' falls back to Calc silently when Math::BigInt::GMP is
# not installed. Thus the module stays correct everywhere.
use Math::BigInt try => 'GMP';
use Digest::SHA qw(sha512);
use OpenHAP::Crypto;
use OpenHAP::PIN qw(normalize_pin);

# SRP-6a implementation for HAP
# The module uses the 3072-bit group from RFC 5054.

# N_len: Length of N in bytes (3072 bits / 8 = 384 bytes)
use constant N_LEN => 384;

# _bigint_to_bytes($bigint, $length = undef) - Convert BigInt to bytes
# The function removes the '0x' prefix from as_hex(). It pads
# the bytes to a fixed length if the caller gives $length.
sub _bigint_to_bytes ( $bigint, $length = undef )
{
	my $hex = $bigint->as_hex();
	$hex =~ s/^0x//;    # Remove the 0x prefix

	# Make the number of hex digits even
	$hex = '0' . $hex if length($hex) % 2;

	my $bytes = pack( 'H*', $hex );

	# Pad with zeros on the left if the caller gives a length
	if ( defined $length && length($bytes) < $length ) {
		$bytes = ( "\x00" x ( $length - length($bytes) ) ) . $bytes;
	}

	return $bytes;
}

sub new ( $class, %args )
{

	my $self = bless {
		username => $args{username}                  // 'Pair-Setup',
		password => normalize_pin( $args{password} ) // $args{password},

		# Group parameters (from OpenHAP::Crypto)
		N => Math::BigInt->from_hex(
			unpack( 'H*', $OpenHAP::Crypto::N_3072 )
		),
		g => Math::BigInt->new($OpenHAP::Crypto::g),

		# Session state
		salt => undef,
		v    => undef,
		b    => undef,
		B    => undef,
		A    => undef,
		S    => undef,
		K    => undef,
		M1   => undef,
		M2   => undef,
	}, $class;

	return $self;
}

sub generate_salt ($self)
{
	$self->{salt} = OpenHAP::Crypto::generate_random_bytes(16);
	return $self->{salt};
}

sub compute_verifier ( $self, $salt = undef, $password = undef )
{
	$salt     //= $self->{salt};
	$password //= $self->{password};

	# x = H(salt | H(username | ":" | password))
	my $inner   = sha512( $self->{username} . ':' . $password );
	my $x_bytes = sha512( $salt . $inner );
	my $x       = Math::BigInt->from_hex( unpack( 'H*', $x_bytes ) );

	# v = g^x mod N
	# bmodpow mutates its invocant. Thus work on a copy of g.
	my $v = $self->{g}->copy->bmodpow( $x, $self->{N} );

	$self->{v} = $v;
	return $v;
}

sub generate_server_public ($self)
{

	# Generate a random b (256 bits)
	my $b_bytes = OpenHAP::Crypto::generate_random_bytes(32);
	$self->{b} = Math::BigInt->from_hex( unpack( 'H*', $b_bytes ) );

	# k = H(N | PAD(g))
	# PAD(g) pads g to the same length as N (384 bytes for 3072-bit)
	my $N_bytes  = _bigint_to_bytes( $self->{N} );
	my $N_len    = length($N_bytes);
	my $g_padded = _bigint_to_bytes( $self->{g}, $N_len );
	my $k_bytes  = sha512( $N_bytes . $g_padded );
	my $k        = Math::BigInt->from_hex( unpack( 'H*', $k_bytes ) );

	# B = (k*v + g^b) mod N
	# bmodpow mutates its invocant. Thus work on a copy of g.
	my $B =
	    ( $k * $self->{v} +
		    $self->{g}->copy->bmodpow( $self->{b}, $self->{N} ) )
	    % $self->{N};

	$self->{B} = $B;
	return $B;
}

sub compute_session_key ( $self, $A_bytes )
{
	my $A = Math::BigInt->from_hex( unpack( 'H*', $A_bytes ) );

	# Security: verify A mod N != 0. This is an SRP-6a
	# requirement per HAP-Pairing.md §2.6. A malicious
	# controller can send A = 0, N, or 2N to make the shared
	# secret predictable and thus bypass authentication.
	return if ( $A % $self->{N} )->is_zero();

	$self->{A} = $A;

	# u = H(PAD(A) | PAD(B))
	# Pad both A and B to N_LEN per HAP-Pairing.md §2.6 and the
	# SRP-6a spec.
	my $A_padded = _bigint_to_bytes( $self->{A}, N_LEN );
	my $B_padded = _bigint_to_bytes( $self->{B}, N_LEN );
	my $u_bytes  = sha512( $A_padded . $B_padded );
	my $u        = Math::BigInt->from_hex( unpack( 'H*', $u_bytes ) );

	# S = (A * v^u)^b mod N
	# bmodpow mutates its invocant. Thus work on a copy of v.
	# The multiplication result is a fresh object. It is safe
	# to mutate.
	my $S =
	    ( $self->{A} * $self->{v}->copy->bmodpow( $u, $self->{N} ) )
	    ->bmodpow( $self->{b}, $self->{N} );

	$self->{S} = $S;

	# K = H(S)
	my $S_bytes = _bigint_to_bytes($S);
	$self->{K} = sha512($S_bytes);

	return $self->{K};
}

sub verify_client_proof ( $self, $M1_client )
{

	# M1 = H(H(N) XOR H(g) | H(username) | salt | A | B | K)
	# Use the string xor operator. v5.36 enables the 'bitwise'
	# feature. Under that feature, plain ^ is numeric-only.
	my $N_hash = sha512( _bigint_to_bytes( $self->{N} ) );
	my $g_hash = sha512( _bigint_to_bytes( $self->{g} ) );
	my $xor    = $N_hash ^. $g_hash;

	my $user_hash = sha512( $self->{username} );

	# M1 = H(H(N) XOR H(g) | H(I) | s | PAD(A) | PAD(B) | K)
	# Pad A and B to N_LEN per HAP-Pairing.md §2.5.
	my $A_bytes = _bigint_to_bytes( $self->{A}, N_LEN );
	my $B_bytes = _bigint_to_bytes( $self->{B}, N_LEN );

	my $M1 =
	    sha512(   $xor
		    . $user_hash
		    . $self->{salt}
		    . $A_bytes
		    . $B_bytes
		    . $self->{K} );

	$self->{M1} = $M1;

	return $M1 eq $M1_client;
}

sub generate_server_proof ($self)
{
	die "SRP: M1 not set (verify_client_proof not called)"
	    if !defined $self->{M1};
	die "SRP: K not set (compute_session_key not called)"
	    if !defined $self->{K};

	# M2 = H(PAD(A) | M1 | K)
	# Pad A to N_LEN per HAP-Pairing.md §2.6.
	my $A_bytes = _bigint_to_bytes( $self->{A}, N_LEN );
	my $M2      = sha512( $A_bytes . $self->{M1} . $self->{K} );

	$self->{M2} = $M2;

	return $M2;
}

sub get_session_key ($self)
{
	return $self->{K};
}

1;
