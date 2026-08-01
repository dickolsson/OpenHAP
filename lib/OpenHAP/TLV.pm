use v5.36;

package OpenHAP::TLV;

# TLV8 encoding and decoding for the HomeKit Accessory Protocol
# The format is Type-Length-Value with 8-bit type and length
# fields. The codec splits values of more than 255 bytes into
# multiple chunks with the same type.

# TLV type for the separator. List Pairings responses use it.
use constant kTLVType_Separator => 0xFF;

# encode(@items) - Encode type-value pairs in order
# The function takes a list of type, value pairs. It keeps the
# insertion order.
# Example: encode(0x06, $state, 0x03, $pubkey)
sub encode (@items)
{
	my $out = '';

	while ( @items >= 2 ) {
		my $type  = shift @items;
		my $value = shift @items;

		# Use the empty string for an undefined value
		$value //= '';

		# Encode empty values, for example the separator 0xFF
		if ( length($value) == 0 ) {
			$out .= pack( 'CC', $type, 0 );
			next;
		}

		# Split values of more than 255 bytes into chunks
		while ( length($value) > 0 ) {
			my $chunk = substr( $value, 0, 255, '' );
			$out .= pack( 'CC', $type, length($chunk) ) . $chunk;
		}
	}

	return $out;
}

# encode_separator() - Encode a TLV separator (type 0xFF, length 0)
sub encode_separator()
{
	return pack( 'CC', kTLVType_Separator, 0 );
}

# decode($data) - Decode a TLV8 buffer into a type => value hash
# The function concatenates consecutive records with the same
# type (fragmentation). It returns the empty list if the buffer
# is malformed. A malformed buffer has a truncated record header
# or a length field that points past the end of the buffer.
sub decode ($data)
{
	my %items;
	my $pos = 0;

	while ( $pos < length($data) ) {

		# Reject a truncated record header
		return if $pos + 2 > length($data);
		my ( $type, $len ) = unpack( 'CC', substr( $data, $pos, 2 ) );
		$pos += 2;

		# Reject a length that runs past the end of the buffer
		return if $pos + $len > length($data);
		my $value = substr( $data, $pos, $len );
		$pos += $len;

		# Concatenate chunks with the same type
		$items{$type} = ( $items{$type} // '' ) . $value;
	}

	return %items;
}

1;
