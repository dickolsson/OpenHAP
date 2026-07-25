use v5.36;

package OpenHAP::SRP;
use Math::BigInt;
use Digest::SHA qw(sha512);
use OpenHAP::Crypto;
use OpenHAP::PIN qw(normalize_pin);

# SRP-6a implementation for HAP
# Uses 3072-bit group from RFC 5054

# N_len: Length of N in bytes (3072 bits / 8 = 384 bytes)
use constant N_LEN => 384;

# _bigint_to_bytes($bigint, $length = undef) - Convert BigInt to bytes
# Strips '0x' prefix from as_hex() and optionally pads to fixed length
sub _bigint_to_bytes ( $bigint, $length = undef )
{
	my $hex = $bigint->as_hex();
	$hex =~ s/^0x//;    # Strip 0x prefix

	# Ensure even number of hex digits
	$hex = '0' . $hex if length($hex) % 2;

	my $bytes = pack( 'H*', $hex );

	# Left-pad with zeros if length specified
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
	# bmodpow mutates its invocant, so work on a copy of g
	my $v = $self->{g}->copy->bmodpow( $x, $self->{N} );

	$self->{v} = $v;
	return $v;
}

sub generate_server_public ($self)
{

	# Generate random b (256 bits)
	my $b_bytes = OpenHAP::Crypto::generate_random_bytes(32);
	$self->{b} = Math::BigInt->from_hex( unpack( 'H*', $b_bytes ) );

	# k = H(N | PAD(g))
	# PAD(g) must be padded to the same length as N (384 bytes for 3072-bit)
	my $N_bytes  = _bigint_to_bytes( $self->{N} );
	my $N_len    = length($N_bytes);
	my $g_padded = _bigint_to_bytes( $self->{g}, $N_len );
	my $k_bytes  = sha512( $N_bytes . $g_padded );
	my $k        = Math::BigInt->from_hex( unpack( 'H*', $k_bytes ) );

	# B = (k*v + g^b) mod N
	# bmodpow mutates its invocant, so work on a copy of g
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

    # Security: Verify A mod N != 0 (SRP-6a requirement per HAP-Pairing.md §2.6)
    # A malicious controller could send A = 0, N, or 2N to make the shared
    # secret predictable, bypassing authentication.
	return if ( $A % $self->{N} )->is_zero();

	$self->{A} = $A;

	# u = H(PAD(A) | PAD(B)) - Both A and B must be padded to N_LEN
	# per HAP-Pairing.md §2.6 and SRP-6a spec
	my $A_padded = _bigint_to_bytes( $self->{A}, N_LEN );
	my $B_padded = _bigint_to_bytes( $self->{B}, N_LEN );
	my $u_bytes  = sha512( $A_padded . $B_padded );
	my $u        = Math::BigInt->from_hex( unpack( 'H*', $u_bytes ) );

	# S = (A * v^u)^b mod N
	# bmodpow mutates its invocant, so work on a copy of v; the
	# multiplication result is a fresh object, safe to mutate
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
	# use the string xor operator: v5.36 enables the 'bitwise'
	# feature, under which plain ^ is numeric-only
	my $N_hash = sha512( _bigint_to_bytes( $self->{N} ) );
	my $g_hash = sha512( _bigint_to_bytes( $self->{g} ) );
	my $xor    = $N_hash ^. $g_hash;

	my $user_hash = sha512( $self->{username} );

	# M1 = H(H(N) XOR H(g) | H(I) | s | PAD(A) | PAD(B) | K)
	# A and B must be padded to N_LEN per HAP-Pairing.md §2.5
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

   # M2 = H(PAD(A) | M1 | K) - A must be padded to N_LEN per HAP-Pairing.md §2.6
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
