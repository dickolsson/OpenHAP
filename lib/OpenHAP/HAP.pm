use v5.36;

package OpenHAP::HAP;

use FuguLib::Log;
use IO::Socket::INET;
use JSON::XS;
use MIME::Base64 qw(encode_base64);
use Digest::SHA  qw(sha512);
use Time::HiRes  qw(time);
use FuguLib::EventLoop;
use FuguLib::HTTP;

use OpenHAP::Session;
use OpenHAP::Pairing;
use OpenHAP::Storage;
use FuguLib::Crypto;
use OpenHAP::Bridge;
use OpenHAP::Characteristic;
use OpenHAP::PIN qw(normalize_pin);

# How much the server reads from a client at a time.
use constant READ_SIZE => 65536;

# The largest request the server accepts: the header block plus the
# body that Content-Length declares. An unpaired client reaches
# /pair-setup, so the buffer of an unauthenticated connection needs a
# bound of its own. A HAP request is a small TLV or a short JSON
# document, so 64 KB is far above anything a controller sends.
use constant MAX_REQUEST_SIZE => 65536;

# The HAP status code for a request that arrives on an unverified
# connection [HAP-HTTP]. It is not an RFC 9110 code, so the codec does
# not know its reason phrase.
use constant STATUS_INSUFFICIENT_PRIVILEGES => 470;

# _response(%args):
#	Build a response with the HAP defaults: the connection stays
#	open, because a controller sends every request of a session
#	over one connection, and the 470 code carries a reason phrase
#	that only HAP defines.
sub _response (%args)
{
	my %headers = %{ $args{headers} // {} };
	$headers{Connection} //= 'keep-alive';

	my $status = $args{status} // 200;
	$args{status_text} //= 'Connection Authorization Required'
	    if $status == STATUS_INSUFFICIENT_PRIVILEGES;

	return FuguLib::HTTP::build_response( %args, headers => \%headers );
}

sub new ( $class, %args )
{
	my $self = bless {
		port => $args{port}                               // 51827,
		pin => normalize_pin( $args{pin} // '1995-1018' ) // '19951018',
		name         => $args{name}         // 'OpenHAP Bridge',
		storage_path => $args{storage_path} // '/var/db/openhapd',
		setup_id     => $args{setup_id},    # Optional 4-char setup ID

		bridge   => undef,
		storage  => undef,
		pairing  => undef,
		sessions => {},

		accessory_ltsk => undef,
		accessory_ltpk => undef,

		mqtt_client        => undef,
		mqtt_tick_interval => 0.1,     # MQTT poll interval in seconds

		event_subscriptions => {},     # Track event subscriptions
		event_queue         => {},     # Queued events for coalescing
		event_flush_timer   => undef,  # The pending flush, if any

		loop   => $args{loop},         # The caller can supply one
		server => undef,               # The listening socket
	}, $class;

	$self->_initialize();

	return $self;
}

sub _initialize ($self)
{
	# Initialize the storage
	$self->{storage} =
	    OpenHAP::Storage->new( db_path => $self->{storage_path} );

	# Load or generate the accessory keys
	my ( $ltsk, $ltpk ) = $self->{storage}->load_accessory_keys();
	unless ( $ltsk && $ltpk ) {
		( $ltsk, $ltpk ) = FuguLib::Crypto->ed25519_keypair;
		$self->{storage}->save_accessory_keys( $ltsk, $ltpk );
	}

	$self->{accessory_ltsk} = $ltsk;
	$self->{accessory_ltpk} = $ltpk;

	# Initialize the pairing handler
	$self->{pairing} = OpenHAP::Pairing->new(
		pin            => $self->{pin},
		storage        => $self->{storage},
		accessory_ltsk => $self->{accessory_ltsk},
		accessory_ltpk => $self->{accessory_ltpk},
	);

	# Initialize the bridge
	$self->{bridge} = OpenHAP::Bridge->new( name => $self->{name}, );

	# Deliver device-side changes as EVENT/1.0 notifications.
	# The bridge forwards the notify_change of each bridged
	# accessory and keeps the device aid (HAP-HTTP.md §14).
	$self->{bridge}->add_event_callback(
		sub ( $aid, $iid ) {
			$self->_queue_change_event( $aid, $iid );
		} );
}

# $self->_queue_change_event($aid, $iid):
#	Queue an event with the current value of the characteristic
sub _queue_change_event ( $self, $aid, $iid )
{
	my $accessory = $self->{bridge}->get_accessory($aid);
	return unless $accessory;

	my $char = $accessory->get_characteristic($iid);
	return unless $char;

	$self->queue_event( $aid, $iid, $char->json_value );

	return;
}

sub add_accessory ( $self, $accessory )
{
	$self->{bridge}->add_bridged_accessory($accessory);
}

# $self->_mqtt_resubscribe_accessories():
#	Resubscribe all accessories to their MQTT topics
sub _mqtt_resubscribe_accessories ($self)
{
	my @accessories = $self->{bridge}->get_bridged_accessories();
	for my $acc (@accessories) {
		if ( $acc->can('subscribe_mqtt') ) {
			eval { $acc->subscribe_mqtt(); };
			FuguLib::Log->default->error(
				'Failed to resubscribe accessory: %s', $@ )
			    if $@;
		}
	}
}

# $self->set_mqtt_client($mqtt):
#	Set the MQTT client for event loop integration
sub set_mqtt_client ( $self, $mqtt )
{
	$self->{mqtt_client} = $mqtt;
}

# $self->set_mdns($mdns):
#	Set the mDNS registration handle. The server re-advertises
#	the TXT record when the pairing state changes
#	(HAP-mDNS.md §8).
sub set_mdns ( $self, $mdns )
{
	$self->{mdns}              = $mdns;
	$self->{last_paired_state} = $self->is_paired() ? 1 : 0;
}

# $self->_refresh_mdns():
#	Re-advertise the TXT record when the pairing state changes
sub _refresh_mdns ($self)
{
	return unless defined $self->{mdns};

	my $paired = $self->is_paired() ? 1 : 0;
	return if ( $self->{last_paired_state} // -1 ) == $paired;

	$self->{last_paired_state} = $paired;

	# Never send an update to an unpublished handle. The daemon
	# can start while mdnsd is down. This code runs on the
	# pairing path. A write to a dead socket must not be
	# reachable there.
	return unless $self->{mdns}->is_published;

	if ( $self->{mdns}->update_txt( txt => $self->get_mdns_txt_string ) ) {
		FuguLib::Log->default->info(
			'Pairing state changed, re-advertised mDNS TXT (sf=%d)',
			$paired ? 0 : 1
		);
	}
	else {
		FuguLib::Log->default->warning(
			'mDNS TXT update failed: %s',
			$self->{mdns}->error // 'unknown'
		);
	}

	return;
}

# The interval between MQTT reconnection attempts, in seconds. A
# broker that is down stays down for a while, and a daemon that
# hammers it helps nobody.
use constant MQTT_RECONNECT_INTERVAL => 30;

# $self->loop:
#	The event loop of this server. The server makes one on demand,
#	so a caller that only wants to drive timers by hand does not
#	have to build one.
sub loop ($self)
{
	$self->{loop} //= FuguLib::EventLoop->new;

	return $self->{loop};
}

# $self->listen:
#	Open the HAP listener and register it with the loop. The method
#	returns the socket. It dies when the port is not available:
#	a HAP server that cannot listen has no reason to run.
sub listen ($self)
{
	return $self->{server} if $self->{server};

	my $server = IO::Socket::INET->new(
		LocalPort => $self->{port},
		Type      => SOCK_STREAM,
		Reuse     => 1,
		Listen    => 10,
	    )
	    or do {
		FuguLib::Log->default->error(
			'Cannot create server socket on port %d: %s',
			$self->{port}, $! );
		die "Cannot create server: $!";
	    };

	$self->{server} = $server;
	$self->loop->add_fd( $server, read => sub ($) { $self->_accept } );

	FuguLib::Log->default->info( 'OpenHAP server listening on port %d',
		$self->{port} );
	FuguLib::Log->default->debug( 'Pairing PIN: %s', $self->{pin} );

	return $server;
}

# $self->run:
#	Serve until the loop stops. The method returns when a signal
#	interrupted the loop or a callback stopped it. Thus the caller
#	runs its own shutdown, and nothing has to exit from inside a
#	signal handler.
sub run ($self)
{
	$self->listen;
	$self->_register_mqtt;
	$self->loop->run;

	FuguLib::Log->default->info('OpenHAP server stopped');

	return $self;
}

# $self->stop:
#	Ask the loop to end after the current pass.
sub stop ($self)
{
	$self->loop->stop;

	return $self;
}

# $self->shutdown:
#	Close the listener and every client connection. The caller
#	calls this after run returns.
sub shutdown ($self)
{
	for my $key ( keys %{ $self->{sessions} } ) {
		my $session = $self->{sessions}{$key};
		my $socket  = $session->{socket};
		next unless ref $socket;

		$self->loop->remove_fd($socket);
		$socket->close;
	}
	$self->{sessions} = {};

	if ( $self->{server} ) {
		$self->loop->remove_fd( $self->{server} );
		$self->{server}->close;
		$self->{server} = undef;
	}

	return $self;
}

# $self->_register_mqtt:
#	Put the MQTT client on the loop: a tick on every interval, and
#	a reconnection attempt on its own slower schedule.
#
#	The two are separate timers because they answer to different
#	clocks. Before this, one poll interval drove both, and the
#	backoff was an epoch comparison inside the pass.
sub _register_mqtt ($self)
{
	return unless $self->{mqtt_client};
	return if $self->{mqtt_timers};

	$self->{mqtt_timers} = [
		$self->loop->every(
			$self->{mqtt_tick_interval},
			sub {
				my $mqtt = $self->{mqtt_client} or return;
				$mqtt->tick(0) if $mqtt->is_connected;
			}
		),
		$self->loop->every(
			MQTT_RECONNECT_INTERVAL,
			sub { $self->_mqtt_retry }
		),
	];

	return;
}

# $self->_mqtt_retry:
#	One reconnection attempt, if the client is down.
sub _mqtt_retry ($self)
{
	my $mqtt = $self->{mqtt_client} or return;
	return if $mqtt->is_connected;

	unless ( $mqtt->reconnect ) {
		FuguLib::Log->default->debug(
			'MQTT reconnection attempt failed, will retry');
		return;
	}

	FuguLib::Log->default->info('Reconnected to MQTT broker');
	$self->_mqtt_resubscribe_accessories;

	return;
}

# $self->_accept:
#	Take one connection and put it on the loop.
sub _accept ($self)
{
	my $client = $self->{server}->accept or return;

	$self->loop->add_fd(
		$client,
		read => sub ($fh) {
			$self->_handle_client($fh);
		} );
	$self->_init_session($client);

	return;
}

sub _init_session ( $self, $socket )
{
	FuguLib::Log->default->info( 'Client connected from %s',
		$socket->peerhost );
	$self->{sessions}{ fileno $socket } =
	    OpenHAP::Session->new( socket => $socket, );
}

# $self->_handle_client($sock):
#	Read what arrived and serve every whole request in it.
#
#	A stream socket gives a reader whatever arrived, which is not a
#	request. A request can span two reads, and two requests can
#	share one. Thus the session keeps a buffer, and
#	FuguLib::HTTP::message_complete says how much of it is a
#	message.
sub _handle_client ( $self, $sock )
{
	my $session = $self->{sessions}{ fileno $sock } or return;
	my $data    = '';
	my $bytes   = $sock->sysread( $data, READ_SIZE );

	if ( !$bytes ) {

		# The connection is closed. Release the pairing lock
		# if this session holds it. Thus an aborted pair-setup
		# cannot block pairing until a restart.
		my $peer = $sock->peerhost // 'unknown';
		$self->_close_client($sock);
		FuguLib::Log->default->info( 'Client disconnected from %s',
			$peer );
		return;
	}

	# Decrypt the data if the session is encrypted. Keep a
	# record of the state. Pair-verify M4 enables encryption
	# during dispatch. But the server sends the M4 response in
	# the clear. Encryption applies only to subsequent traffic.
	my $was_encrypted = $session->is_encrypted();
	if ($was_encrypted) {
		$data = $session->decrypt($data);
		unless ( defined $data ) {
			FuguLib::Log->default->warning(
				'Decryption failed for client session');
			$self->_close_client($sock);
			return;
		}
	}

	$session->{inbuf} .= $data;

	# Serve every whole request the buffer holds. A client that
	# pipelines gets an answer to each one, in order.
	while ( length $session->{inbuf} ) {
		my $length =
		    FuguLib::HTTP::message_complete( $session->{inbuf},
			max_size => MAX_REQUEST_SIZE );

		# Over the limit. An unpaired client reaches
		# /pair-setup, so the buffer of an unauthenticated
		# connection needs a bound of its own.
		unless ( defined $length ) {
			FuguLib::Log->default->warning(
				'Request over %d bytes from %s, closing',
				MAX_REQUEST_SIZE, $sock->peerhost );
			$self->_close_client($sock);
			return;
		}
		last if $length == 0;    # More bytes are necessary

		my $message = substr $session->{inbuf}, 0, $length, '';
		$self->_serve_request( $sock, $session, $message,
			$was_encrypted );

		# The dispatch can have closed the connection
		return unless exists $self->{sessions}{ fileno $sock };
	}

	return;
}

# $self->_serve_request($sock, $session, $message, $was_encrypted):
#	Dispatch one whole request and write its response.
sub _serve_request ( $self, $sock, $session, $message, $was_encrypted )
{
	my $request = FuguLib::HTTP::parse_request($message);
	unless ( defined $request ) {
		FuguLib::Log->default->warning( 'Malformed request from %s',
			$sock->peerhost );
		$request =
		    { method => '', path => '', headers => {}, body => '' };
	}

	# Log the HTTP request with the client information
	FuguLib::Log->default->info(
		'HTTP %s %s from %s', $request->{method},
		$request->{path},     $sock->peerhost
	);

	# Dispatch the request
	my $response = $self->_dispatch( $request, $session );

	# Encrypt the response only if the session was encrypted
	# when the request arrived. See the note above.
	if ($was_encrypted) {
		$response = $session->encrypt($response);
	}

	# Send the response
	$sock->syswrite($response);

	# Re-advertise mDNS if this request changed the pairing state
	$self->_refresh_mdns;

	return;
}

# $self->_close_client($sock):
#	Drop a client and everything the server kept for it.
sub _close_client ( $self, $sock )
{
	my $key     = fileno $sock;
	my $session = defined $key ? $self->{sessions}{$key} : undef;

	OpenHAP::Pairing->clear_pairing_state($session) if $session;
	$self->_purge_event_subscriptions($session)     if $session;

	$self->loop->remove_fd($sock);
	delete $self->{sessions}{$key} if defined $key;
	$sock->close();

	return;
}

sub _dispatch ( $self, $request, $session )
{
	my $path   = $request->{path};
	my $method = $request->{method};

	# Pairing endpoints. These need no verified session.
	if ( $path eq '/pair-setup' && $method eq 'POST' ) {
		return $self->_handle_pair_setup( $request, $session );
	}

	if ( $path eq '/pair-verify' && $method eq 'POST' ) {
		return $self->_handle_pair_verify( $request, $session );
	}

	# Identify endpoint. It is for unpaired accessories only.
	if ( $path eq '/identify' && $method eq 'POST' ) {
		return $self->_handle_identify( $request, $session );
	}

	# All other endpoints need a verified session
	unless ( $session->is_verified() ) {
		return _response(
			status  => 470,    # Connection Authorization Required
			headers => { 'Content-Type' => 'application/hap+json' },
		);
	}

	# Pairings management
	if ( $path eq '/pairings' && $method eq 'POST' ) {
		return $self->_handle_pairings( $request, $session );
	}

	# Accessory endpoints
	if ( $path eq '/accessories' && $method eq 'GET' ) {
		return $self->_handle_accessories( $request, $session );
	}

	# Remove the query string for path matching
	my $base_path = $path;
	$base_path =~ s/\?.*//;

	if ( $base_path eq '/characteristics' && $method eq 'GET' ) {
		return $self->_handle_characteristics_get( $request, $session );
	}

	if ( $base_path eq '/characteristics' && $method eq 'PUT' ) {
		return $self->_handle_characteristics_put( $request, $session );
	}

	# Timed write preparation. The spec shows POST in the
	# table, but the later text uses PUT. Accept both methods
	# for compatibility.
	if ( $path eq '/prepare' && ( $method eq 'PUT' || $method eq 'POST' ) )
	{
		return $self->_handle_prepare( $request, $session );
	}

	# Not found
	return _response(
		status  => 404,
		headers => { 'Content-Type' => 'text/plain' },
		body    => 'Not Found',
	);
}

sub _handle_pair_setup ( $self, $request, $session )
{
	FuguLib::Log->default->debug('Handling pair-setup request');
	my $response_body =
	    $self->{pairing}->handle_pair_setup( $request->{body}, $session );

	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response_body,
	);
}

sub _handle_pair_verify ( $self, $request, $session )
{
	FuguLib::Log->default->debug('Handling pair-verify request');
	my $response_body =
	    $self->{pairing}->handle_pair_verify( $request->{body}, $session );

	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response_body,
	);
}

sub _handle_accessories ( $self, $request, $session )
{
	my $json = encode_json( $self->{bridge}->to_json() );

	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => $json,
	);
}

sub _handle_characteristics_get ( $self, $request, $session )
{
	# Parse the query string: ?id=1.11,1.13&meta=1&perms=1&type=1&ev=1
	my $query = $request->{path};
	$query =~ s/^.*\?//;
	FuguLib::Log->default->debug( 'Reading characteristics: %s', $query );

	my %params;
	for my $pair ( split /&/, $query ) {
		my ( $key, $value ) = split /=/, $pair, 2;
		$params{$key} = $value;
	}

	my @ids           = split /,/, ( $params{id} // '' );
	my $include_meta  = $params{meta}  // 0;
	my $include_perms = $params{perms} // 0;
	my $include_type  = $params{type}  // 0;
	my $include_ev    = $params{ev}    // 0;

	my @characteristics;
	my $has_errors = 0;

	for my $id (@ids) {
		my ( $aid, $iid ) = split /\./, $id;

		my $accessory = $self->{bridge}->get_accessory($aid);
		unless ($accessory) {
			push @characteristics,
			    {
				aid    => $aid + 0,
				iid    => $iid + 0,
				status => -70409
			    };
			$has_errors = 1;
			next;
		}

		my $char = $accessory->get_characteristic($iid);
		unless ($char) {
			push @characteristics,
			    {
				aid    => $aid + 0,
				iid    => $iid + 0,
				status => -70409
			    };
			$has_errors = 1;
			next;
		}

		my $result = {
			aid   => $aid + 0,
			iid   => $iid + 0,
			value => $char->json_value,
		};

		# Add the optional metadata if the controller requests it
		if ($include_meta) {
			$result->{format} = $char->{format};
			$result->{unit}   = $char->{unit}
			    if defined $char->{unit};
			$result->{minValue} = $char->{min}
			    if defined $char->{min};
			$result->{maxValue} = $char->{max}
			    if defined $char->{max};
			$result->{minStep} = $char->{step}
			    if defined $char->{step};
		}

		# Add the permissions if the controller requests them
		if ($include_perms) {
			$result->{perms} = $char->{perms};
		}

		# Add the type if the controller requests it
		if ($include_type) {
			$result->{type} = $char->{type};
		}

		# Add the event status if the controller requests it
		if ($include_ev) {
			$result->{ev} = $char->events_enabled() ? \1 : \0;
		}

		push @characteristics, $result;
	}

	my $json = encode_json( { characteristics => \@characteristics } );

	return _response(
		status  => $has_errors ? 207 : 200,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => $json,
	);
}

sub _handle_characteristics_put ( $self, $request, $session )
{
	FuguLib::Log->default->debug('Writing characteristics');
	my $data = eval { decode_json( $request->{body} ) };
	return _response( status => 400 ) unless $data;

	my @results;
	my $has_errors = 0;

	for my $item ( @{ $data->{characteristics} // [] } ) {
		my $aid   = $item->{aid};
		my $iid   = $item->{iid};
		my $value = $item->{value};

		my $accessory = $self->{bridge}->get_accessory($aid);
		unless ($accessory) {
			push @results,
			    {
				aid    => $aid + 0,
				iid    => $iid + 0,
				status => -70409
			    };
			$has_errors = 1;
			next;
		}

		my $char = $accessory->get_characteristic($iid);
		unless ($char) {
			push @results,
			    {
				aid    => $aid + 0,
				iid    => $iid + 0,
				status => -70409
			    };
			$has_errors = 1;
			next;
		}

		# Check if the characteristic is writable
		my $is_writable = grep { $_ eq 'pw' } @{ $char->{perms} // [] };
		if ( defined $value && !$is_writable ) {
			push @results,
			    {
				aid    => $aid + 0,
				iid    => $iid + 0,
				status => -70404
			    };
			$has_errors = 1;
			next;
		}

		# Set the value if the request contains one
		if ( defined $value ) {
			eval { $char->set_value($value) };
			if ($@) {
				push @results,
				    {
					aid    => $aid + 0,
					iid    => $iid + 0,
					status => -70402
				    };
				$has_errors = 1;
				next;
			}

			# Notify the subscribers on other connections.
			# Exclude the originating session
			# (HAP-HTTP.md §14).
			$self->queue_event( $aid, $iid, $char->json_value,
				$session );
		}

		# Enable or disable events
		if ( exists $item->{ev} ) {
			my $has_ev =
			    grep { $_ eq 'ev' } @{ $char->{perms} // [] };
			if ( !$has_ev ) {
				push @results,
				    {
					aid    => $aid + 0,
					iid    => $iid + 0,
					status => -70406
				    };
				$has_errors = 1;
				next;
			}
			$char->enable_events( $item->{ev} );

			# Record the session for event delivery
			if ( $item->{ev} ) {
				$self->_register_event_subscription( $session,
					$aid, $iid );
			}
			else {
				$self->_unregister_event_subscription( $session,
					$aid, $iid );
			}
		}

		# Success for this characteristic
		push @results,
		    { aid => $aid + 0, iid => $iid + 0, status => 0 };
	}

	# Return 204 No Content when all writes succeed
	return _response( status => 204 )
	    unless $has_errors;

	# Return 207 Multi-Status with details if some writes fail
	my $json = encode_json( { characteristics => \@results } );
	return _response(
		status  => 207,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => $json,
	);
}

sub _handle_identify ( $self, $request, $session )
{
	# Identify is only for unpaired accessories
	if ( $self->is_paired() ) {
		return _response(
			status  => 400,
			headers => { 'Content-Type' => 'application/hap+json' },
			body    => encode_json( { status => -70401 } ),
		);
	}

	FuguLib::Log->default->info('Identify request received (unpaired)');

	# Start identification on the bridge
	my $bridge = $self->{bridge};
	if ($bridge) {
		my $info_service = $bridge->get_service('AccessoryInformation');
		if ($info_service) {
			my $identify_char =
			    $info_service->get_characteristic_by_type(
				'Identify');
			if ( $identify_char && $identify_char->{on_set} ) {
				$identify_char->{on_set}->(1);
			}
		}
	}

	return _response( status => 204 );
}

sub _handle_pairings ( $self, $request, $session )
{
	my %tlv = OpenHAP::TLV::decode( $request->{body} );

	my $method_raw = $tlv{ OpenHAP::Pairing::kTLVType_Method() };
	my $method     = defined $method_raw ? unpack( 'C', $method_raw ) : -1;

	FuguLib::Log->default->debug( 'Pairings request method=%d', $method );

	# Method values: 3=Add, 4=Remove, 5=List
	if ( $method == 3 ) {
		return $self->_handle_add_pairing( \%tlv, $session );
	}
	elsif ( $method == 4 ) {
		return $self->_handle_remove_pairing( \%tlv, $session );
	}
	elsif ( $method == 5 ) {
		return $self->_handle_list_pairings( \%tlv, $session );
	}

	# Unknown method
	my $error = OpenHAP::TLV::encode(
		OpenHAP::Pairing::kTLVType_State(),
		pack( 'C', 2 ),
		OpenHAP::Pairing::kTLVType_Error(),
		pack( 'C', OpenHAP::Pairing::kTLVError_Unknown() ),
	);
	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $error,
	);
}

sub _handle_add_pairing ( $self, $tlv, $session )
{
	my $identifier = $tlv->{ OpenHAP::Pairing::kTLVType_Identifier() };
	my $ltpk       = $tlv->{ OpenHAP::Pairing::kTLVType_PublicKey() };
	my $perms      = unpack( 'C',
		$tlv->{ OpenHAP::Pairing::kTLVType_Permissions() } // "\x00" );

	FuguLib::Log->default->debug( 'Add pairing request for: %s',
		$identifier // 'unknown' );

	# Check the admin permissions. Only admins can add pairings.
	my $pairings           = $self->{storage}->load_pairings();
	my $current_controller = $session->controller_id();
	my $current_pairing    = $pairings->{$current_controller};
	unless ( $current_pairing && $current_pairing->{permissions} ) {
		my $error = OpenHAP::TLV::encode(
			OpenHAP::Pairing::kTLVType_State(),
			pack( 'C', 2 ),
			OpenHAP::Pairing::kTLVType_Error(),
			pack( 'C',
				OpenHAP::Pairing::kTLVError_Authentication() ),
		);
		return _response(
			status  => 200,
			headers =>
			    { 'Content-Type' => 'application/pairing+tlv8' },
			body => $error,
		);
	}

	# An existing identifier with a different LTPK is an error.
	# With a matching LTPK, the server updates only the
	# permissions (HAP-Pairing.md §7.4).
	my $existing = $pairings->{$identifier};
	if ( $existing && $existing->{ltpk} ne $ltpk ) {
		my $error = OpenHAP::TLV::encode(
			OpenHAP::Pairing::kTLVType_State(),
			pack( 'C', 2 ),
			OpenHAP::Pairing::kTLVType_Error(),
			pack( 'C', OpenHAP::Pairing::kTLVError_Unknown() ),
		);
		return _response(
			status  => 200,
			headers =>
			    { 'Content-Type' => 'application/pairing+tlv8' },
			body => $error,
		);
	}

	# Save the pairing
	$self->{storage}->save_pairing( $identifier, $ltpk, $perms );
	FuguLib::Log->default->info( 'Added pairing for controller: %s',
		$identifier );

	my $response = OpenHAP::TLV::encode(
		OpenHAP::Pairing::kTLVType_State(),
		pack( 'C', 2 ),
	);
	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response,
	);
}

sub _handle_remove_pairing ( $self, $tlv, $session )
{
	my $identifier = $tlv->{ OpenHAP::Pairing::kTLVType_Identifier() };

	FuguLib::Log->default->debug( 'Remove pairing request for: %s',
		$identifier // 'unknown' );

	# Check the admin permissions
	my $pairings           = $self->{storage}->load_pairings();
	my $current_controller = $session->controller_id();
	my $current_pairing    = $pairings->{$current_controller};
	unless ( $current_pairing && $current_pairing->{permissions} ) {
		my $error = OpenHAP::TLV::encode(
			OpenHAP::Pairing::kTLVType_State(),
			pack( 'C', 2 ),
			OpenHAP::Pairing::kTLVType_Error(),
			pack( 'C',
				OpenHAP::Pairing::kTLVError_Authentication() ),
		);
		return _response(
			status  => 200,
			headers =>
			    { 'Content-Type' => 'application/pairing+tlv8' },
			body => $error,
		);
	}

	# Remove the pairing
	$self->{storage}->remove_pairing($identifier);
	FuguLib::Log->default->info( 'Removed pairing for controller: %s',
		$identifier );

	# Check if any admins remain (HAP-Pairing.md §7.2). If no
	# admin remains, remove all pairings and regenerate the
	# identity.
	my $remaining = $self->{storage}->load_pairings();
	my $has_admin = grep { $_->{permissions} } values %$remaining;
	unless ( $has_admin || keys %$remaining == 0 ) {
		FuguLib::Log->default->info(
'Last admin removed - clearing all pairings and regenerating identity'
		);
		$self->{storage}->remove_all_pairings();
		$self->_regenerate_identity();
	}

	my $response = OpenHAP::TLV::encode(
		OpenHAP::Pairing::kTLVType_State(),
		pack( 'C', 2 ),
	);
	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response,
	);
}

sub _handle_list_pairings ( $self, $tlv, $session )
{
	FuguLib::Log->default->debug('List pairings request');

	# Check the admin permissions
	my $pairings           = $self->{storage}->load_pairings();
	my $current_controller = $session->controller_id();
	my $current_pairing    = $pairings->{$current_controller};
	unless ( $current_pairing && $current_pairing->{permissions} ) {
		my $error = OpenHAP::TLV::encode(
			OpenHAP::Pairing::kTLVType_State(),
			pack( 'C', 2 ),
			OpenHAP::Pairing::kTLVType_Error(),
			pack( 'C',
				OpenHAP::Pairing::kTLVError_Authentication() ),
		);
		return _response(
			status  => 200,
			headers =>
			    { 'Content-Type' => 'application/pairing+tlv8' },
			body => $error,
		);
	}

	# Build the response with all pairings. Separate them with
	# 0xFF.
	my @response_items =
	    ( OpenHAP::Pairing::kTLVType_State(), pack( 'C', 2 ) );

	my $first = 1;
	for my $id ( sort keys %$pairings ) {
		my $pairing = $pairings->{$id};

		# Add a separator between pairings
		unless ($first) {
			push @response_items,
			    OpenHAP::Pairing::kTLVType_Separator(), '';
		}
		$first = 0;

		push @response_items,
		    OpenHAP::Pairing::kTLVType_Identifier(), $id,
		    OpenHAP::Pairing::kTLVType_PublicKey(),  $pairing->{ltpk},
		    OpenHAP::Pairing::kTLVType_Permissions(),
		    pack( 'C', $pairing->{permissions} );
	}

	my $response = OpenHAP::TLV::encode(@response_items);
	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response,
	);
}

sub _handle_prepare ( $self, $request, $session )
{
	FuguLib::Log->default->debug('Timed write prepare request');
	my $data = eval { decode_json( $request->{body} ) };
	return _response( status => 400 ) unless $data;

	my $ttl = $data->{ttl};    # Time to live in ms
	my $pid = $data->{pid};    # Process ID
	my $aid = $data->{aid};
	my $iid = $data->{iid};

	# Validate the request
	unless ( defined $ttl && defined $pid ) {
		return _response(
			status  => 400,
			headers => { 'Content-Type' => 'application/hap+json' },
			body    => encode_json( { status => -70410 } ),
		);
	}

	# Store the timed write context in the session
	$session->{timed_write} = {
		ttl       => $ttl,
		pid       => $pid,
		aid       => $aid,
		iid       => $iid,
		timestamp => time(),
	};

	return _response(
		status  => 200,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => encode_json( { status => 0 } ),
	);
}

# Event subscription tracking. A subscription is filed twice: under
# the characteristic, for delivery, and on the session, so that a
# disconnect is a delete of what that connection holds and not a
# sweep of every characteristic the bridge has.
sub _register_event_subscription ( $self, $session, $aid, $iid )
{
	my $key = "$aid.$iid";
	$self->{event_subscriptions}{$key}{ $session->id } = $session;
	$session->{subscriptions}{$key} = 1;
	FuguLib::Log->default->debug( 'Registered event subscription for %s',
		$key );
}

sub _unregister_event_subscription ( $self, $session, $aid, $iid )
{
	my $key = "$aid.$iid";
	delete $self->{event_subscriptions}{$key}{ $session->id };
	delete $session->{subscriptions}{$key};
	FuguLib::Log->default->debug( 'Unregistered event subscription for %s',
		$key );
}

# $self->_purge_event_subscriptions($session):
#	Remove every subscription that a disconnecting session
#	holds. Subscriptions are per-connection (HAP-HTTP.md §14).
sub _purge_event_subscriptions ( $self, $session )
{
	my $id = $session->id;

	for my $key ( keys %{ $session->{subscriptions} } ) {
		delete $self->{event_subscriptions}{$key}{$id};
	}
	$session->{subscriptions} = {};

	return;
}

# Characteristic types exempt from coalescing (HAP-HTTP.md §14):
# ProgrammableSwitchEvent (0x73), ButtonEvent (0x126),
# MotionDetected (0x22), ContactSensorState (0x6A)
use constant IMMEDIATE_EVENT_TYPES => {
	'73'  => 1,
	'126' => 1,
	'22'  => 1,
	'6A'  => 1,
};

# Event coalescing delay in seconds (HAP-HTTP.md §14)
use constant EVENT_COALESCE_DELAY => 0.250;

# Queue an event for delivery. Coalesce all events except the
# immediate-delivery characteristic types. The optional
# $originator is the session whose request caused the change.
# That session never receives the event (HAP-HTTP.md §14).
sub queue_event ( $self, $aid, $iid, $value, $originator = undef )
{
	my $accessory = $self->{bridge}->get_accessory($aid);
	return unless $accessory;

	my $char = $accessory->get_characteristic($iid);
	return unless $char;

	# The immediate types bypass coalescing
	my $char_type =
	    OpenHAP::Characteristic::_uuid_to_short( $char->{type} // '' );
	if ( IMMEDIATE_EVENT_TYPES->{$char_type} ) {
		$self->send_event( $aid, $iid, $value, $originator );
		return;
	}

	# Queue the event for coalescing
	my $key = "$aid.$iid";
	$self->{event_queue}{$key} = {
		aid        => $aid,
		iid        => $iid,
		value      => $value,
		originator => $originator,
		timestamp  => Time::HiRes::time(),
	};

	# Schedule one flush for the whole window. A second event
	# inside the window joins the flush that the first one asked
	# for, which is what coalescing means.
	$self->{event_flush_timer} //= $self->loop->after(
		EVENT_COALESCE_DELAY,
		sub {
			$self->{event_flush_timer} = undef;
			$self->flush_events;
		} );
}

# $self->flush_events:
#	Send every queued event now. The coalesce timer calls this at
#	the end of the window. A caller that drives the server by hand,
#	such as a conformance test, calls it directly.
sub flush_events ($self)
{
	return unless %{ $self->{event_queue} };

	for my $event ( values %{ $self->{event_queue} } ) {
		$self->send_event(
			$event->{aid},   $event->{iid},
			$event->{value}, $event->{originator} );
	}

	$self->{event_queue} = {};

	# A direct call empties the queue, so the pending timer has
	# nothing left to do
	$self->loop->cancel( $self->{event_flush_timer} )
	    if $self->{event_flush_timer};
	$self->{event_flush_timer} = undef;

	return;
}

# Send an EVENT/1.0 notification to the subscribed sessions. Do
# not send it to the originating session when the caller gives
# one (HAP-HTTP.md §14).
sub send_event ( $self, $aid, $iid, $value, $originator = undef )
{
	my $key  = "$aid.$iid";
	my $subs = $self->{event_subscriptions}{$key} // {};

	my $event_body = encode_json( {
			characteristics =>
			    [ { aid => $aid, iid => $iid, value => $value } ] }
	);

	my $event_msg =
	      "EVENT/1.0 200 OK\r\n"
	    . "Content-Type: application/hap+json\r\n"
	    . "Content-Length: "
	    . length($event_body) . "\r\n" . "\r\n"
	    . $event_body;

	for my $session ( values %$subs ) {
		next unless $session && $session->is_encrypted();
		next if defined $originator && $session == $originator;

		my $encrypted = $session->encrypt($event_msg);
		my $socket    = $session->{socket};
		if ( $socket && $socket->connected ) {
			eval { $socket->syswrite($encrypted) };
			if ($@) {
				FuguLib::Log->default->warning(
					'Failed to send event to session: %s',
					$@ );
			}
		}
	}
}

sub is_paired ($self)
{
	my $pairings = $self->{storage}->load_pairings();
	return scalar( keys %$pairings ) > 0;
}

sub get_config_number ($self)
{
	return $self->{storage}->get_config_number();
}

# $self->update_config_number():
#	Increment c# when the accessory database changed since the
#	last run (HAP-mDNS.md §3.1). The server calls this after
#	device loading. It compares a digest of the accessory
#	structure against the stored one.
sub update_config_number ($self)
{
	my @parts;
	for my $accessory ( $self->{bridge}->get_all_accessories ) {
		push @parts, "a$accessory->{aid}";
		for my $service ( $accessory->get_services ) {
			push @parts,
			    "s$service->{iid}:" . $service->to_json->{type};
			for my $char ( $service->get_characteristics ) {
				push @parts,
				      "c$char->{iid}:"
				    . $char->to_json->{type} . ':'
				    . $char->{format};
			}
		}
	}
	my $digest = unpack( 'H*', sha512( join( ';', @parts ) ) );

	my $stored = $self->{storage}->get_config_digest;
	if ( !defined $stored ) {

		# On the first run, record the digest. c# stays at
		# its initial value of 1.
		$self->{storage}->save_config_digest($digest);
	}
	elsif ( $stored ne $digest ) {
		$self->{storage}->increment_config_number;
		$self->{storage}->save_config_digest($digest);
		FuguLib::Log->default->info(
			'Accessory database changed, c# is now %d',
			$self->get_config_number );
	}

	return $self->get_config_number;
}

sub get_device_id ($self)
{
	# Generate a device ID from the public key in uppercase MAC format
	my $id = uc( unpack( 'H*', substr( $self->{accessory_ltpk}, 0, 6 ) ) );
	return join( ':', $id =~ /../g );
}

sub get_mdns_txt_records ($self)
{
	# Note: pv=1, not 1.1. mdnsd uses '.' as the TXT record
	# delimiter and does not support escaping. HomeKit accepts
	# pv=1.
	my $records = {
		'c#' => $self->get_config_number(),
		'ff' => 0,
		'id' => $self->get_device_id(),
		'md' => $self->{name},
		'pv' => '1',
		's#' => 1,
		'sf' => $self->is_paired() ? 0 : 1,
		'ci' => 2,
	};

	# Add the setup hash if setup_id is set
	if ( defined $self->{setup_id} && length( $self->{setup_id} ) == 4 ) {
		$records->{sh} = $self->_get_setup_hash();
	}

	return $records;
}

# $self->get_mdns_txt_string():
#	Return the TXT records in the advertisement format. The
#	string joins key=value pairs with '.' in sorted key order.
#	The TXT delimiter of mdnsd makes the order visible on the
#	wire (MDNS-Control.md §5). Thus the function keeps the
#	order deterministic.
sub get_mdns_txt_string ($self)
{
	my $records = $self->get_mdns_txt_records;

	return join '.', map { "$_=$records->{$_}" } sort keys %$records;
}

# _get_setup_hash() - Calculate the setup hash for mDNS
# The hash is the Base64 of the first 4 bytes of
# SHA-512(setupID + deviceID.toUpperCase())
sub _get_setup_hash ($self)
{
	my $setup_id  = $self->{setup_id};
	my $device_id = $self->get_device_id();    # Already uppercase

	my $hash      = sha512( $setup_id . $device_id );
	my $truncated = substr( $hash, 0, 4 );

	# Encode the truncated hash in Base64 without newlines
	my $encoded = encode_base64( $truncated, '' );
	return $encoded;
}

# _regenerate_identity() - Generate new accessory keys after a
# factory reset. The server calls this after removal of the
# last admin pairing (HAP-Pairing.md §7.2).
sub _regenerate_identity ($self)
{
	my ( $ltsk, $ltpk ) = FuguLib::Crypto->ed25519_keypair;
	$self->{storage}->save_accessory_keys( $ltsk, $ltpk );
	$self->{accessory_ltsk} = $ltsk;
	$self->{accessory_ltpk} = $ltpk;

	# Reinitialize the pairing handler with the new keys
	$self->{pairing} = OpenHAP::Pairing->new(
		pin            => $self->{pin},
		storage        => $self->{storage},
		accessory_ltsk => $self->{accessory_ltsk},
		accessory_ltpk => $self->{accessory_ltpk},
	);

	# Reset the authentication attempt counter
	OpenHAP::Pairing->reset_auth_attempts();

	FuguLib::Log->default->info('Accessory identity regenerated');
	return;
}

1;
