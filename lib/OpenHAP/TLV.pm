use v5.36;

package OpenHAP::TLV;

# TLV8 encoding/decoding for HomeKit Accessory Protocol
# Type-Length-Value with 8-bit type and length fields
# Values > 255 bytes are split into multiple chunks with same type

# TLV Type for separator (used in List Pairings responses)
use constant kTLVType_Separator => 0xFF;

# encode(@items) - Encode type-value pairs in order
# Takes a list of type, value pairs preserving insertion order
# Example: encode(0x06, $state, 0x03, $pubkey)
sub encode (@items)
{
	my $out = '';

	while ( @items >= 2 ) {
		my $type  = shift @items;
		my $value = shift @items;

		# Handle undefined values as empty
		$value //= '';

		# Handle empty values (e.g., separator 0xFF)
		if ( length($value) == 0 ) {
			$out .= pack( 'CC', $type, 0 );
			next;
		}

		# Split values > 255 bytes into chunks
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

# decode($data) - Decode TLV8 buffer into a type => value hash
# Consecutive records with the same type are concatenated (fragmentation).
# Returns the empty list if the buffer is malformed: a truncated record
# header or a length field pointing past the end of the buffer.
sub decode ($data)
{
	my %items;
	my $pos = 0;

	while ( $pos < length($data) ) {

		# Reject a truncated record header
		return if $pos + 2 > length($data);
		my ( $type, $len ) = unpack( 'CC', substr( $data, $pos, 2 ) );
		$pos += 2;

		# Reject a length running past the end of the buffer
		return if $pos + $len > length($data);
		my $value = substr( $data, $pos, $len );
		$pos += $len;

		# Concatenate chunks with same type
		$items{$type} = ( $items{$type} // '' ) . $value;
	}

	return %items;
}

1;
