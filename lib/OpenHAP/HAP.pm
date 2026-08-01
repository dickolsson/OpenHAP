use v5.36;

package OpenHAP::HAP;
use IO::Socket::INET;
use IO::Select;
use JSON::XS;
use MIME::Base64 qw(encode_base64);
use Digest::SHA  qw(sha512);
use Time::HiRes  qw(time);
use OpenHAP::HTTP;

use OpenHAP::Session;
use OpenHAP::Pairing;
use OpenHAP::Storage;
use OpenHAP::Crypto;
use OpenHAP::Bridge;
use OpenHAP::Characteristic;
use OpenHAP::PIN qw(normalize_pin);

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

		event_subscriptions   => {},   # Track event subscriptions
		event_queue           => {},   # Queued events for coalescing
		event_flush_scheduled =>
		    undef,    # Timestamp when flush was scheduled
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
		( $ltsk, $ltpk ) = OpenHAP::Crypto::generate_keypair_ed25519();
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
			$OpenHAP::logger->error(
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
		$OpenHAP::logger->info(
			'Pairing state changed, re-advertised mDNS TXT (sf=%d)',
			$paired ? 0 : 1
		);
	}
	else {
		$OpenHAP::logger->warning(
			'mDNS TXT update failed: %s',
			$self->{mdns}->error // 'unknown'
		);
	}

	return;
}

sub run ($self)
{
	my $server = IO::Socket::INET->new(
		LocalPort => $self->{port},
		Type      => SOCK_STREAM,
		Reuse     => 1,
		Listen    => 10,
	    )
	    or do {
		$OpenHAP::logger->error(
			'Cannot create server socket on port %d: %s',
			$self->{port}, $! );
		die "Cannot create server: $!";
	    };

	$OpenHAP::logger->info( 'OpenHAP server listening on port %d',
		$self->{port} );
	$OpenHAP::logger->debug( 'Pairing PIN: %s', $self->{pin} );

	my $select = IO::Select->new($server);

	# Use a short timeout to allow MQTT polling
	my $select_timeout          = $self->{mqtt_tick_interval};
	my $mqtt_reconnect_interval = 30;    # Reconnect attempt interval
	my $last_mqtt_reconnect     = 0;

	while (1) {
		my @ready = $select->can_read($select_timeout);

		# Process MQTT messages if the server has a client
		if ( $self->{mqtt_client} ) {
			if ( $self->{mqtt_client}->is_connected ) {
				$self->{mqtt_client}->tick(0);
			}
			else {
				# Try to reconnect at intervals when the
				# client is not connected
				my $now = time;
				if ( $now - $last_mqtt_reconnect >=
					$mqtt_reconnect_interval )
				{
					$last_mqtt_reconnect = $now;
					if ( $self->{mqtt_client}->reconnect() )
					{
						$OpenHAP::logger->info(
'Reconnected to MQTT broker'
						);

						# Resubscribe the devices
						$self
						    ->_mqtt_resubscribe_accessories
						    ();
					}
					else {
						$OpenHAP::logger->debug(
'MQTT reconnection attempt failed, will retry'
						);
					}
				}
			}
		}

		for my $sock (@ready) {
			if ( $sock == $server ) {

				# New connection
				my $client = $server->accept();
				$select->add($client);
				$self->_init_session($client);
			}
			else {

				# Process the client data
				$self->_handle_client( $sock, $select );
			}
		}

		# Flush the coalesced events after the coalesce delay
		$self->flush_events();
	}
}

sub _init_session ( $self, $socket )
{
	$OpenHAP::logger->info( 'Client connected from %s', $socket->peerhost );
	$self->{sessions}{$socket} =
	    OpenHAP::Session->new( socket => $socket, );
}

sub _handle_client ( $self, $sock, $select )
{
	my $session = $self->{sessions}{$sock};
	my $data    = '';
	my $bytes   = $sock->sysread( $data, 65535 );

	if ( !$bytes ) {

		# The connection is closed. Release the pairing lock
		# if this session holds it. Thus an aborted pair-setup
		# cannot block pairing until a restart.
		OpenHAP::Pairing->clear_pairing_state($session);
		$self->_purge_event_subscriptions($session);
		$OpenHAP::logger->info( 'Client disconnected from %s',
			$sock->peerhost );
		$select->remove($sock);
		delete $self->{sessions}{$sock};
		$sock->close();
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
			$OpenHAP::logger->warning(
				'Decryption failed for client session');
			OpenHAP::Pairing->clear_pairing_state($session);
			$self->_purge_event_subscriptions($session);
			$select->remove($sock);
			delete $self->{sessions}{$sock};
			$sock->close();
			return;
		}
	}

	# Parse the HTTP request
	my $request = OpenHAP::HTTP::parse($data);

	# Log the HTTP request with the client information
	$OpenHAP::logger->info(
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
		return OpenHAP::HTTP::build_response(
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
	return OpenHAP::HTTP::build_response(
		status  => 404,
		headers => { 'Content-Type' => 'text/plain' },
		body    => 'Not Found',
	);
}

sub _handle_pair_setup ( $self, $request, $session )
{
	$OpenHAP::logger->debug('Handling pair-setup request');
	my $response_body =
	    $self->{pairing}->handle_pair_setup( $request->{body}, $session );

	return OpenHAP::HTTP::build_response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response_body,
	);
}

sub _handle_pair_verify ( $self, $request, $session )
{
	$OpenHAP::logger->debug('Handling pair-verify request');
	my $response_body =
	    $self->{pairing}->handle_pair_verify( $request->{body}, $session );

	return OpenHAP::HTTP::build_response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response_body,
	);
}

sub _handle_accessories ( $self, $request, $session )
{
	my $json = encode_json( $self->{bridge}->to_json() );

	return OpenHAP::HTTP::build_response(
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
	$OpenHAP::logger->debug( 'Reading characteristics: %s', $query );

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

	return OpenHAP::HTTP::build_response(
		status  => $has_errors ? 207 : 200,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => $json,
	);
}

sub _handle_characteristics_put ( $self, $request, $session )
{
	$OpenHAP::logger->debug('Writing characteristics');
	my $data = eval { decode_json( $request->{body} ) };
	return OpenHAP::HTTP::build_response( status => 400 ) unless $data;

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
	return OpenHAP::HTTP::build_response( status => 204 )
	    unless $has_errors;

	# Return 207 Multi-Status with details if some writes fail
	my $json = encode_json( { characteristics => \@results } );
	return OpenHAP::HTTP::build_response(
		status  => 207,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => $json,
	);
}

sub _handle_identify ( $self, $request, $session )
{
	# Identify is only for unpaired accessories
	if ( $self->is_paired() ) {
		return OpenHAP::HTTP::build_response(
			status  => 400,
			headers => { 'Content-Type' => 'application/hap+json' },
			body    => encode_json( { status => -70401 } ),
		);
	}

	$OpenHAP::logger->info('Identify request received (unpaired)');

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

	return OpenHAP::HTTP::build_response( status => 204 );
}

sub _handle_pairings ( $self, $request, $session )
{
	my %tlv = OpenHAP::TLV::decode( $request->{body} );

	my $method_raw = $tlv{ OpenHAP::Pairing::kTLVType_Method() };
	my $method     = defined $method_raw ? unpack( 'C', $method_raw ) : -1;

	$OpenHAP::logger->debug( 'Pairings request method=%d', $method );

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
	return OpenHAP::HTTP::build_response(
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

	$OpenHAP::logger->debug( 'Add pairing request for: %s',
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
		return OpenHAP::HTTP::build_response(
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
		return OpenHAP::HTTP::build_response(
			status  => 200,
			headers =>
			    { 'Content-Type' => 'application/pairing+tlv8' },
			body => $error,
		);
	}

	# Save the pairing
	$self->{storage}->save_pairing( $identifier, $ltpk, $perms );
	$OpenHAP::logger->info( 'Added pairing for controller: %s',
		$identifier );

	my $response = OpenHAP::TLV::encode(
		OpenHAP::Pairing::kTLVType_State(),
		pack( 'C', 2 ),
	);
	return OpenHAP::HTTP::build_response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response,
	);
}

sub _handle_remove_pairing ( $self, $tlv, $session )
{
	my $identifier = $tlv->{ OpenHAP::Pairing::kTLVType_Identifier() };

	$OpenHAP::logger->debug( 'Remove pairing request for: %s',
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
		return OpenHAP::HTTP::build_response(
			status  => 200,
			headers =>
			    { 'Content-Type' => 'application/pairing+tlv8' },
			body => $error,
		);
	}

	# Remove the pairing
	$self->{storage}->remove_pairing($identifier);
	$OpenHAP::logger->info( 'Removed pairing for controller: %s',
		$identifier );

	# Check if any admins remain (HAP-Pairing.md §7.2). If no
	# admin remains, remove all pairings and regenerate the
	# identity.
	my $remaining = $self->{storage}->load_pairings();
	my $has_admin = grep { $_->{permissions} } values %$remaining;
	unless ( $has_admin || keys %$remaining == 0 ) {
		$OpenHAP::logger->info(
'Last admin removed - clearing all pairings and regenerating identity'
		);
		$self->{storage}->remove_all_pairings();
		$self->_regenerate_identity();
	}

	my $response = OpenHAP::TLV::encode(
		OpenHAP::Pairing::kTLVType_State(),
		pack( 'C', 2 ),
	);
	return OpenHAP::HTTP::build_response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response,
	);
}

sub _handle_list_pairings ( $self, $tlv, $session )
{
	$OpenHAP::logger->debug('List pairings request');

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
		return OpenHAP::HTTP::build_response(
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
	return OpenHAP::HTTP::build_response(
		status  => 200,
		headers => { 'Content-Type' => 'application/pairing+tlv8' },
		body    => $response,
	);
}

sub _handle_prepare ( $self, $request, $session )
{
	$OpenHAP::logger->debug('Timed write prepare request');
	my $data = eval { decode_json( $request->{body} ) };
	return OpenHAP::HTTP::build_response( status => 400 ) unless $data;

	my $ttl = $data->{ttl};    # Time to live in ms
	my $pid = $data->{pid};    # Process ID
	my $aid = $data->{aid};
	my $iid = $data->{iid};

	# Validate the request
	unless ( defined $ttl && defined $pid ) {
		return OpenHAP::HTTP::build_response(
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

	return OpenHAP::HTTP::build_response(
		status  => 200,
		headers => { 'Content-Type' => 'application/hap+json' },
		body    => encode_json( { status => 0 } ),
	);
}

# Event subscription tracking
sub _register_event_subscription ( $self, $session, $aid, $iid )
{
	my $key = "$aid.$iid";
	$self->{event_subscriptions}{$key}{$session} = $session;
	$OpenHAP::logger->debug( 'Registered event subscription for %s', $key );
}

sub _unregister_event_subscription ( $self, $session, $aid, $iid )
{
	my $key = "$aid.$iid";
	delete $self->{event_subscriptions}{$key}{$session};
	$OpenHAP::logger->debug( 'Unregistered event subscription for %s',
		$key );
}

# $self->_purge_event_subscriptions($session):
#	Remove every subscription that a disconnecting session
#	holds. Subscriptions are per-connection (HAP-HTTP.md §14).
sub _purge_event_subscriptions ( $self, $session )
{
	for my $subs ( values %{ $self->{event_subscriptions} } ) {
		delete $subs->{$session};
	}

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

	# Schedule a flush if no flush is pending
	$self->{event_flush_scheduled} //= Time::HiRes::time();
}

# Flush the queued events. The event loop calls this function.
sub flush_events ($self)
{
	return unless $self->{event_flush_scheduled};

	my $now    = Time::HiRes::time();
	my $oldest = $self->{event_flush_scheduled};

	# Wait until the end of the coalesce delay
	return if ( $now - $oldest ) < EVENT_COALESCE_DELAY;

	# Send all the queued events
	for my $event ( values %{ $self->{event_queue} } ) {
		$self->send_event(
			$event->{aid},   $event->{iid},
			$event->{value}, $event->{originator} );
	}

	# Clear the queue
	$self->{event_queue}           = {};
	$self->{event_flush_scheduled} = undef;
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
				$OpenHAP::logger->warning(
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
		$OpenHAP::logger->info(
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
	my ( $ltsk, $ltpk ) = OpenHAP::Crypto::generate_keypair_ed25519();
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

	$OpenHAP::logger->info('Accessory identity regenerated');
	return;
}

1;
