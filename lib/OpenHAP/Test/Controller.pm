# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@senzilla.io>
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

package OpenHAP::Test::Controller;

use IO::Socket::INET;
use IO::Select;
use Protocol::HAP::Crypto;
use Protocol::HAP::HTTP;
use Protocol::HAP::TLV;
use Protocol::HAP::Pairing;
use OpenHAP::Test::Controller::SRP;

# This module is a minimal HomeKit controller for tests. It completes
# pair-setup (SRP M1-M6) and pair-verify (X25519). It uses the
# encrypted session framing. It connects to a live accessory over
# TCP, or runs in-process through an injected transport code ref.

use constant MAX_FRAME => 1024;

# The bound on one response that the controller accumulates. The
# accessory database of a bridge with many accessories is the largest
# message HAP sends, so the limit is well above the server's own
# request limit.
use constant MAX_MESSAGE => 1048576;

sub new ( $class, %args )
{
	my $self = bless {
		host      => $args{host} // '127.0.0.1',
		port      => $args{port} // 51827,
		pin       => $args{pin}  // '031-45-154',
		transport => $args{transport},

		# Socket read timeout. The default is correct for fast
		# in-process and native runs. Under TCG emulation, one
		# SRP modexp can take many seconds. Thus integration
		# tests against a real daemon raise the timeout with
		# OPENHAP_TEST_TIMEOUT.
		timeout => $args{timeout} // $ENV{OPENHAP_TEST_TIMEOUT} // 5,

		controller_id => $args{controller_id} // 'openhap-test-ctrl',

		# Controller long-term identity. new makes it once.
		ltsk => undef,
		ltpk => undef,

		# pair_setup sets these values.
		accessory_ltpk => undef,
		accessory_id   => undef,

		# Session state after pair-verify
		encrypted     => 0,
		encrypt_key   => undef,
		decrypt_key   => undef,
		encrypt_count => 0,
		decrypt_count => 0,

		socket     => undef,
		inbuf      => '',
		rawbuf     => '',
		last_error => undef,
	}, $class;

	( $self->{ltsk}, $self->{ltpk} ) =
	    Protocol::HAP::Crypto->ed25519_keypair;

	return $self;
}

# $self->last_error():
#	Return the TLV error code or message string of the last
#	failed exchange.
sub last_error ($self)
{
	return $self->{last_error};
}

sub is_encrypted ($self)
{
	return $self->{encrypted};
}

# --- transport ---------------------------------------------------------

sub _connect ($self)
{
	return 1 if $self->{transport} || $self->{socket};

	my $socket = IO::Socket::INET->new(
		PeerAddr => $self->{host},
		PeerPort => $self->{port},
		Proto    => 'tcp',
		Timeout  => $self->{timeout},
	);
	unless ( defined $socket ) {
		$self->{last_error} = "connect: $!";
		return;
	}

	$self->{socket} = $socket;
	return 1;
}

sub close ($self)
{
	if ( $self->{socket} ) {
		$self->{socket}->close;
		$self->{socket} = undef;
	}
	$self->{encrypted} = 0;
	$self->{inbuf}     = '';
	$self->{rawbuf}    = '';
	return 1;
}

# $self->_round_trip($request_bytes):
#	Send the raw bytes and return the raw response bytes of one
#	HTTP response. Encrypted responses stay encrypted.
sub _round_trip ( $self, $request )
{
	if ( $self->{transport} ) {
		return $self->{transport}->($request);
	}

	return unless $self->_connect;

	my $socket = $self->{socket};
	$socket->syswrite($request);

	# Read until the buffer holds a full, decodable HTTP response
	my $select = IO::Select->new($socket);
	my $raw    = '';
	while (1) {
		last unless $select->can_read( $self->{timeout} );
		my $bytes = $socket->sysread( my $chunk, 65535 );
		unless ($bytes) {
			$self->{last_error} = 'connection closed';
			last;
		}
		$raw .= $chunk;

		my $plain =
		      $self->{encrypted}
		    ? $self->_decrypt_peek($raw)
		    : $raw;
		last
		    if defined $plain
		    && Protocol::HAP::HTTP::message_complete( $plain,
			max_size => MAX_MESSAGE );
	}

	return $raw;
}

# --- session framing (HAP-Encryption.md §2-§5) -------------------------

sub _encrypt ( $self, $data )
{
	my $out = '';
	while ( length($data) > 0 ) {
		my $chunk = substr( $data, 0, MAX_FRAME, '' );
		my $aad   = pack( 'v',      length($chunk) );
		my $nonce = pack( 'x[4]Q<', $self->{encrypt_count}++ );
		my ( $ciphertext, $tag ) =
		    Protocol::HAP::Crypto->chacha20poly1305_encrypt(
			$self->{encrypt_key},
			$nonce, $chunk, $aad );
		$out .= $aad . $ciphertext . $tag;
	}
	return $out;
}

# _decrypt_peek($data):
#	Decrypt the data but do not consume the counter state. The
#	socket read loop uses this while it accumulates frames.
sub _decrypt_peek ( $self, $data )
{
	my $count = $self->{decrypt_count};
	my $plain = $self->_decrypt($data);
	$self->{decrypt_count} = $count;
	return $plain;
}

sub _decrypt ( $self, $data )
{
	my $out = '';
	my $pos = 0;
	while ( $pos < length($data) ) {
		return if $pos + 2 > length($data);
		my $length = unpack( 'v', substr( $data, $pos, 2 ) );
		my $aad    = substr( $data, $pos, 2 );
		$pos += 2;
		return if $length > MAX_FRAME;
		return if $pos + $length + 16 > length($data);
		my $ciphertext = substr( $data, $pos, $length );
		$pos += $length;
		my $tag = substr( $data, $pos, 16 );
		$pos += 16;

		my $nonce = pack( 'x[4]Q<', $self->{decrypt_count}++ );
		my $plain =
		    Protocol::HAP::Crypto->chacha20poly1305_decrypt(
			$self->{decrypt_key}, $nonce, $ciphertext, $tag, $aad );
		return unless defined $plain;
		$out .= $plain;
	}
	return $out;
}

# --- HTTP --------------------------------------------------------------

sub _build_request ( $self, $method, $path, $body = undef, $headers = {} )
{
	return Protocol::HAP::HTTP::build_request(
		method  => $method,
		path    => $path,
		body    => $body,
		headers => { Host => "$self->{host}:$self->{port}", %$headers },
	);
}

sub _parse_response ( $self, $raw )
{
	unless ( defined $raw && length $raw ) {
		$self->{last_error} = 'no response';
		return;
	}

	my $response = Protocol::HAP::HTTP::parse_response($raw);
	unless ( defined $response ) {
		$self->{last_error} = 'malformed response';
		return;
	}

	return $response;
}

# $self->request($method, $path, $body?, $headers?):
#	Send one HTTP request over the session. After pair-verify
#	completes, the session uses the encrypted framing. Return a
#	hash ref with status, headers and body. Return undef on a
#	transport error.
sub request ( $self, $method, $path, $body = undef, $headers = {} )
{
	my $raw = $self->_build_request( $method, $path, $body, $headers );
	$raw = $self->_encrypt($raw) if $self->{encrypted};

	my $response = $self->_round_trip($raw);
	return unless defined $response && length $response;

	if ( $self->{encrypted} ) {
		$response = $self->_decrypt($response);
		unless ( defined $response ) {
			$self->{last_error} = 'response decryption failed';
			return;
		}
	}

	# Keep the bytes after the first complete message for
	# next_event. For example, an event can arrive back-to-back
	# with the response.
	my $length =
	    Protocol::HAP::HTTP::message_complete( $response,
		max_size => MAX_MESSAGE );
	if ($length) {
		$self->{inbuf} .= substr( $response, $length );
		$response = substr( $response, 0, $length );
	}

	return $self->_parse_response($response);
}

# --- pairing ------------------------------------------------------------

sub _tlv_request ( $self, $path, %tlv_items )
{
	my $body     = Protocol::HAP::TLV::encode(%tlv_items);
	my $response = $self->request( 'POST', $path, $body,
		{ 'Content-Type' => 'application/pairing+tlv8' } );
	return unless defined $response;

	unless ( $response->{status} == 200 ) {
		$self->{last_error} = "HTTP $response->{status}";
		return;
	}

	my %tlv   = Protocol::HAP::TLV::decode( $response->{body} );
	my $error = $tlv{ Protocol::HAP::Pairing::kTLVType_Error() };
	if ( defined $error ) {
		$self->{last_error} = unpack( 'C', $error );
		return;
	}

	return \%tlv;
}

# $self->pair_setup():
#	Complete SRP pair-setup M1-M6. On success, store the
#	accessory LTPK and return true. On a protocol error, return
#	undef and put the TLV error code in last_error.
sub pair_setup ($self)
{
	$self->{last_error} = undef;

	# M1 -> M2
	my $m2 = $self->_tlv_request(
		'/pair-setup',
		Protocol::HAP::Pairing::kTLVType_State()  => pack( 'C', 1 ),
		Protocol::HAP::Pairing::kTLVType_Method() => pack( 'C', 0 ),
	) or return;

	my $salt = $m2->{ Protocol::HAP::Pairing::kTLVType_Salt() };
	my $B    = $m2->{ Protocol::HAP::Pairing::kTLVType_PublicKey() };
	unless ( defined $salt && defined $B ) {
		$self->{last_error} = 'M2 missing salt or public key';
		return;
	}

	# M3 -> M4
	my $srp =
	    OpenHAP::Test::Controller::SRP->new( password => $self->{pin} );
	my $A  = $srp->compute_public;
	my $M1 = $srp->compute_proof( $salt, $B );
	unless ( defined $M1 ) {
		$self->{last_error} = 'bogus server public key';
		return;
	}

	my $m4 = $self->_tlv_request(
		'/pair-setup',
		Protocol::HAP::Pairing::kTLVType_State()     => pack( 'C', 3 ),
		Protocol::HAP::Pairing::kTLVType_PublicKey() => $A,
		Protocol::HAP::Pairing::kTLVType_Proof()     => $M1,
	) or return;

	my $M2 = $m4->{ Protocol::HAP::Pairing::kTLVType_Proof() };
	unless ( $srp->verify_server_proof($M2) ) {
		$self->{last_error} = 'server proof verification failed';
		return;
	}

	# M5 -> M6
	my $K           = $srp->session_key;
	my $encrypt_key = Protocol::HAP::Crypto->hkdf_sha512( $K,
		'Pair-Setup-Encrypt-Salt', 'Pair-Setup-Encrypt-Info', 32 );

	my $ios_x = Protocol::HAP::Crypto->hkdf_sha512(
		$K,
		'Pair-Setup-Controller-Sign-Salt',
		'Pair-Setup-Controller-Sign-Info', 32
	);
	my $signature = Protocol::HAP::Crypto->ed25519_sign(
		$ios_x . $self->{controller_id} . $self->{ltpk},
		$self->{ltsk}, $self->{ltpk} );

	my $inner = Protocol::HAP::TLV::encode(
		Protocol::HAP::Pairing::kTLVType_Identifier() =>
		    $self->{controller_id},
		Protocol::HAP::Pairing::kTLVType_PublicKey() => $self->{ltpk},
		Protocol::HAP::Pairing::kTLVType_Signature() => $signature,
	);
	my ( $encrypted, $tag ) =
	    Protocol::HAP::Crypto->chacha20poly1305_encrypt( $encrypt_key,
		pack('x[4]') . 'PS-Msg05', $inner );

	my $m6 = $self->_tlv_request(
		'/pair-setup',
		Protocol::HAP::Pairing::kTLVType_State() => pack( 'C', 5 ),
		Protocol::HAP::Pairing::kTLVType_EncryptedData() => $encrypted
		    . $tag,
	) or return;

	my $m6_data = $m6->{ Protocol::HAP::Pairing::kTLVType_EncryptedData() };
	unless ( defined $m6_data && length($m6_data) > 16 ) {
		$self->{last_error} = 'M6 missing encrypted data';
		return;
	}
	my $m6_tag = substr( $m6_data, -16, 16, '' );
	my $m6_plain =
	    Protocol::HAP::Crypto->chacha20poly1305_decrypt( $encrypt_key,
		pack('x[4]') . 'PS-Msg06',
		$m6_data, $m6_tag );
	unless ( defined $m6_plain ) {
		$self->{last_error} = 'M6 decryption failed';
		return;
	}

	my %m6_inner = Protocol::HAP::TLV::decode($m6_plain);
	my $acc_id = $m6_inner{ Protocol::HAP::Pairing::kTLVType_Identifier() };
	my $acc_ltpk =
	    $m6_inner{ Protocol::HAP::Pairing::kTLVType_PublicKey() };
	my $acc_sig = $m6_inner{ Protocol::HAP::Pairing::kTLVType_Signature() };

	my $acc_x = Protocol::HAP::Crypto->hkdf_sha512(
		$K,
		'Pair-Setup-Accessory-Sign-Salt',
		'Pair-Setup-Accessory-Sign-Info', 32
	);
	unless (
		Protocol::HAP::Crypto->ed25519_verify(
			$acc_sig, $acc_x . $acc_id . $acc_ltpk, $acc_ltpk
		) )
	{
		$self->{last_error} = 'accessory signature invalid';
		return;
	}

	$self->{accessory_ltpk} = $acc_ltpk;
	$self->{accessory_id}   = $acc_id;

	return 1;
}

# $self->pair_verify():
#	Complete pair-verify M1-M4 and switch the connection to the
#	encrypted session framing. This requires a completed
#	pair_setup, or an accessory_ltpk from the caller.
sub pair_verify ($self)
{
	$self->{last_error} = undef;

	my ( $secret, $public ) = Protocol::HAP::Crypto->x25519_keypair;

	# M1 -> M2
	my $m2 = $self->_tlv_request(
		'/pair-verify',
		Protocol::HAP::Pairing::kTLVType_State()     => pack( 'C', 1 ),
		Protocol::HAP::Pairing::kTLVType_PublicKey() => $public,
	) or return;

	my $acc_public = $m2->{ Protocol::HAP::Pairing::kTLVType_PublicKey() };
	my $m2_data = $m2->{ Protocol::HAP::Pairing::kTLVType_EncryptedData() };
	unless ( defined $acc_public && defined $m2_data ) {
		$self->{last_error} = 'M2 missing public key or data';
		return;
	}

	my $shared =
	    Protocol::HAP::Crypto->x25519_shared_secret( $secret, $acc_public );
	my $pv_key = Protocol::HAP::Crypto->hkdf_sha512( $shared,
		'Pair-Verify-Encrypt-Salt', 'Pair-Verify-Encrypt-Info', 32 );

	my $m2_tag = substr( $m2_data, -16, 16, '' );
	my $m2_plain =
	    Protocol::HAP::Crypto->chacha20poly1305_decrypt( $pv_key,
		pack('x[4]') . 'PV-Msg02',
		$m2_data, $m2_tag );
	unless ( defined $m2_plain ) {
		$self->{last_error} = 'M2 decryption failed';
		return;
	}

	my %m2_inner = Protocol::HAP::TLV::decode($m2_plain);
	my $acc_id = $m2_inner{ Protocol::HAP::Pairing::kTLVType_Identifier() };
	my $acc_sig = $m2_inner{ Protocol::HAP::Pairing::kTLVType_Signature() };

	# Verify the accessory signature when the controller knows
	# the accessory LTPK
	if ( defined $self->{accessory_ltpk} ) {
		unless (
			Protocol::HAP::Crypto->ed25519_verify(
				$acc_sig,
				$acc_public . $acc_id . $public,
				$self->{accessory_ltpk} ) )
		{
			$self->{last_error} = 'accessory signature invalid';
			return;
		}
	}

	# M3 -> M4
	my $signature = Protocol::HAP::Crypto->ed25519_sign(
		$public . $self->{controller_id} . $acc_public,
		$self->{ltsk}, $self->{ltpk} );
	my $inner = Protocol::HAP::TLV::encode(
		Protocol::HAP::Pairing::kTLVType_Identifier() =>
		    $self->{controller_id},
		Protocol::HAP::Pairing::kTLVType_Signature() => $signature,
	);
	my ( $encrypted, $tag ) =
	    Protocol::HAP::Crypto->chacha20poly1305_encrypt( $pv_key,
		pack('x[4]') . 'PV-Msg03', $inner );

	$self->_tlv_request(
		'/pair-verify',
		Protocol::HAP::Pairing::kTLVType_State() => pack( 'C', 3 ),
		Protocol::HAP::Pairing::kTLVType_EncryptedData() => $encrypted
		    . $tag,
	) or return;

	# Session keys: the controller writes with the Write key and
	# reads with the Read key (HAP-Encryption.md §1)
	$self->{encrypt_key} =
	    Protocol::HAP::Crypto->hkdf_sha512( $shared, 'Control-Salt',
		'Control-Write-Encryption-Key', 32 );
	$self->{decrypt_key} =
	    Protocol::HAP::Crypto->hkdf_sha512( $shared, 'Control-Salt',
		'Control-Read-Encryption-Key', 32 );
	$self->{encrypt_count} = 0;
	$self->{decrypt_count} = 0;
	$self->{encrypted}     = 1;

	return 1;
}

# --- pairings management (HAP-Pairing.md §7) ----------------------------

sub add_pairing ( $self, $identifier, $ltpk, $permissions = 0 )
{
	$self->{last_error} = undef;

	my $result = $self->_tlv_request(
		'/pairings',
		Protocol::HAP::Pairing::kTLVType_State()  => pack( 'C', 1 ),
		Protocol::HAP::Pairing::kTLVType_Method() => pack( 'C', 3 ),
		Protocol::HAP::Pairing::kTLVType_Identifier()  => $identifier,
		Protocol::HAP::Pairing::kTLVType_PublicKey()   => $ltpk,
		Protocol::HAP::Pairing::kTLVType_Permissions() =>
		    pack( 'C', $permissions ),
	) or return;

	return 1;
}

sub remove_pairing ( $self, $identifier = undef )
{
	$self->{last_error} = undef;
	$identifier //= $self->{controller_id};

	my $result = $self->_tlv_request(
		'/pairings',
		Protocol::HAP::Pairing::kTLVType_State()      => pack( 'C', 1 ),
		Protocol::HAP::Pairing::kTLVType_Method()     => pack( 'C', 4 ),
		Protocol::HAP::Pairing::kTLVType_Identifier() => $identifier,
	) or return;

	return 1;
}

sub list_pairings ($self)
{
	$self->{last_error} = undef;

	my $body = Protocol::HAP::TLV::encode(
		Protocol::HAP::Pairing::kTLVType_State()  => pack( 'C', 1 ),
		Protocol::HAP::Pairing::kTLVType_Method() => pack( 'C', 5 ),
	);
	my $response = $self->request( 'POST', '/pairings', $body,
		{ 'Content-Type' => 'application/pairing+tlv8' } );
	return unless defined $response;

	unless ( $response->{status} == 200 ) {
		$self->{last_error} = "HTTP $response->{status}";
		return;
	}

	# Split the entries on the zero-length separator. Without
	# the split, TLV::decode concatenates the repeated
	# Identifier/PublicKey types.
	my @pairings;
	for my $entry ( split /\xFF\x00/, $response->{body} ) {
		my %tlv = Protocol::HAP::TLV::decode($entry);
		my $id  = $tlv{ Protocol::HAP::Pairing::kTLVType_Identifier() };
		next unless defined $id;

		my $error = $tlv{ Protocol::HAP::Pairing::kTLVType_Error() };
		if ( defined $error ) {
			$self->{last_error} = unpack( 'C', $error );
			return;
		}

		push @pairings,
		    {
			identifier => $id,
			ltpk       => $tlv{
				Protocol::HAP::Pairing::kTLVType_PublicKey()
			},
			permissions => unpack(
				'C',
				$tlv{
					Protocol::HAP::Pairing::kTLVType_Permissions(
					)
				} // "\x00"
			),
		    };
	}

	# A lone error TLV with no identifiers means the request failed
	if ( !@pairings ) {
		my %tlv   = Protocol::HAP::TLV::decode( $response->{body} );
		my $error = $tlv{ Protocol::HAP::Pairing::kTLVType_Error() };
		if ( defined $error ) {
			$self->{last_error} = unpack( 'C', $error );
			return;
		}
	}

	return \@pairings;
}

# --- events -------------------------------------------------------------

# $self->next_event($timeout?):
#	Wait for an EVENT/1.0 message on the socket, then decrypt
#	and parse it. Return { status, headers, body }, or undef on
#	timeout. Without an explicit $timeout, the session timeout
#	bounds the wait. That timeout honors OPENHAP_TEST_TIMEOUT.
#	Pass a literal only for short negative probes. This requires
#	a socket connection, not an injected transport.
sub next_event ( $self, $timeout = undef )
{
	return unless $self->{socket};

	$timeout //= $self->{timeout};

	my $select = IO::Select->new( $self->{socket} );
	my $end    = time + $timeout;

	while (1) {

		# The buffer can already hold a complete event
		if ( $self->{inbuf} =~ s{\A(EVENT/1\.0.*?\r\n\r\n)}{}s ) {
			my $head = $1;
			my ($length) = $head =~ /Content-Length:\s*(\d+)/i;
			$length //= 0;
			my $body = substr( $self->{inbuf}, 0, $length, '' );

			my %headers;
			for my $line ( split /\r\n/, $head ) {
				$headers{ lc $1 } = $2
				    if $line =~ /^([^:]+):\s*(.*)$/;
			}
			my ($status) = $head =~ m{^EVENT/1\.0\s+(\d+)};

			return {
				status  => $status,
				headers => \%headers,
				body    => $body,
			};
		}

		my $remaining = $end - time;
		return if $remaining <= 0;
		next unless $select->can_read($remaining);

		my $bytes = $self->{socket}->sysread( my $chunk, 65535 );
		return unless $bytes;

		unless ( $self->{encrypted} ) {
			$self->{inbuf} .= $chunk;
			next;
		}

		# A frame can arrive split across reads. Accumulate the
		# raw bytes and decrypt only complete frames. Keep a
		# partial tail buffered. Then the nonce counter stays in
		# sync with the accessory.
		$self->{rawbuf} .= $chunk;
		my $plain = $self->_drain_frames;
		return unless defined $plain;
		$self->{inbuf} .= $plain;
	}
}

# $self->_drain_frames():
#	Decrypt and consume every complete frame at the front of the
#	raw receive buffer. A trailing partial frame stays buffered
#	for the next read. Return the decrypted plaintext, which can
#	be empty. Return undef on an authentication failure.
sub _drain_frames ($self)
{
	my $out = '';
	while ( length( $self->{rawbuf} ) >= 2 ) {
		my $length = unpack( 'v', substr( $self->{rawbuf}, 0, 2 ) );
		return if $length > MAX_FRAME;
		last   if length( $self->{rawbuf} ) < 2 + $length + 16;

		my $frame = substr( $self->{rawbuf}, 0, 2 + $length + 16, '' );
		my $aad        = substr( $frame, 0,           2 );
		my $ciphertext = substr( $frame, 2,           $length );
		my $tag        = substr( $frame, 2 + $length, 16 );

		my $nonce = pack( 'x[4]Q<', $self->{decrypt_count}++ );
		my $plain =
		    Protocol::HAP::Crypto->chacha20poly1305_decrypt(
			$self->{decrypt_key}, $nonce, $ciphertext, $tag, $aad );
		return unless defined $plain;
		$out .= $plain;
	}
	return $out;
}

1;
