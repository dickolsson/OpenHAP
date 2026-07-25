use v5.36;

package OpenHAP::Session;
use OpenHAP::Crypto;

sub new ( $class, %args )
{

	my $self = bless {
		socket        => $args{socket},
		encrypted     => 0,
		verified      => 0,
		controller_id => undef,

		# Session keys (set after pair-verify)
		encrypt_key => undef,
		decrypt_key => undef,

		# Counters for nonce generation
		encrypt_count => 0,
		decrypt_count => 0,

		# Temporary pairing state
		pairing_state => {},
	}, $class;

	return $self;
}

sub set_encryption ( $self, $encrypt_key, $decrypt_key )
{

	$self->{encrypt_key}   = $encrypt_key;
	$self->{decrypt_key}   = $decrypt_key;
	$self->{encrypted}     = 1;
	$self->{encrypt_count} = 0;
	$self->{decrypt_count} = 0;
	$OpenHAP::logger->debug('Session encryption enabled');
}

sub encrypt ( $self, $data )
{

	return $data unless $self->{encrypted};

	my $encrypted = '';

	# HAP encrypts data in chunks with AAD containing length
	while ( length($data) > 0 ) {
		my $chunk  = substr( $data, 0, 1024, '' );
		my $length = length($chunk);

		# AAD is 2-byte length in little-endian
		my $aad = pack( 'v', $length );

		# Nonce is 4 bytes zero + 8 bytes counter (little-endian)
		my $nonce = pack( 'x[4]Q<', $self->{encrypt_count}++ );

		my ( $ciphertext, $tag ) =
		    OpenHAP::Crypto::chacha20_poly1305_encrypt(
			$self->{encrypt_key},
			$nonce, $chunk, $aad );

		# Frame format: length (2 bytes) + ciphertext + tag (16 bytes)
		$encrypted .= $aad . $ciphertext . $tag;
	}

	return $encrypted;
}

sub decrypt ( $self, $data )
{

	return $data unless $self->{encrypted};

	my $decrypted = '';
	my $pos       = 0;

	# HAP decrypts data in frames; a truncated frame or a frame
	# claiming more than 1024 bytes of plaintext is an error
	# (HAP-Encryption.md §9)
	while ( $pos < length($data) ) {

		# Read frame header (2-byte length)
		return if $pos + 2 > length($data);
		my $length = unpack( 'v', substr( $data, $pos, 2 ) );
		my $aad    = substr( $data, $pos, 2 );
		$pos += 2;

		return if $length > 1024;

		# Read ciphertext + tag
		return if $pos + $length + 16 > length($data);
		my $ciphertext = substr( $data, $pos, $length );
		$pos += $length;
		my $tag = substr( $data, $pos, 16 );
		$pos += 16;

		# Nonce is 4 bytes zero + 8 bytes counter (little-endian)
		my $nonce = pack( 'x[4]Q<', $self->{decrypt_count}++ );

		my $plaintext =
		    OpenHAP::Crypto::chacha20_poly1305_decrypt(
			$self->{decrypt_key}, $nonce, $ciphertext, $tag, $aad );

		return unless defined $plaintext;
		$decrypted .= $plaintext;
	}

	return $decrypted;
}

sub is_encrypted ($self)
{
	return $self->{encrypted};
}

sub is_verified ($self)
{
	return $self->{verified};
}

sub set_verified ( $self, $controller_id )
{
	$self->{verified}      = 1;
	$self->{controller_id} = $controller_id;
	$OpenHAP::logger->debug( 'Session verified for controller: %s',
		$controller_id );

	return;
}

sub controller_id ($self)
{
	return $self->{controller_id};
}

1;
