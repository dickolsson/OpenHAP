use v5.36;

package OpenHAP::MQTT;

# MQTT client wrapper for OpenHAP
# Integrates with IO::Select for event-driven message handling

sub new ( $class, %args )
{
	my $self = bless {
		host     => $args{host} // '127.0.0.1',
		port     => $args{port} // 1883,
		username => $args{username},
		password => $args{password},

		subscriptions    => {},
		pending_messages => [],
		connected        => 0,
		last_tick        => 0,
	}, $class;

	return $self;
}

sub mqtt_connect ( $self, $timeout = 10 )
{
	$OpenHAP::logger->debug(
		'Connecting to MQTT broker at %s:%d (timeout: %ds)',
		$self->{host}, $self->{port}, $timeout );

	# Try to load Net::MQTT::Simple if available
	local $@;

	# Capture warnings from Net::MQTT::Simple
	my @warnings;
	local $SIG{__WARN__} = sub {
		push @warnings, shift;
	};

	my $success = eval {

		# Ensure site_perl is in @INC
		unshift @INC, '/usr/local/libdata/perl5/site_perl'
		    unless grep { $_ eq '/usr/local/libdata/perl5/site_perl' }
		    @INC;

		local $SIG{ALRM} = sub { die "Connection timeout\n" };
		alarm($timeout);

		require Net::MQTT::Simple;

		my $server = $self->{host};
		if ( $self->{port} != 1883 ) {
			$server .= ':' . $self->{port};
		}

		my $mqtt = Net::MQTT::Simple->new($server);

		# Set login credentials if provided
		if ( defined $self->{username} ) {
			$mqtt->login( $self->{username},
				$self->{password} // '' );
		}

		alarm(0);    # Clear alarm

		$self->{client}    = $mqtt;
		$self->{connected} = 1;
		$OpenHAP::logger->debug(
			'Successfully connected to MQTT broker');
		return 1;
	};
	alarm(0);    # Ensure alarm is cleared on error path

	# Log captured warnings through our logging system
	for my $warning (@warnings) {
		chomp $warning;

	     # Strip program name if present (e.g., "/usr/local/bin/openhapd: ")
		$warning =~ s{^(?:.*/)?[^/]+:\s+}{};
		$OpenHAP::logger->debug( 'MQTT connection warning: %s',
			$warning );
	}

	if ( $@ || !$success ) {
		my $err = $@ || 'Unknown error';
		$OpenHAP::logger->error( 'MQTT connection failed: %s', $err );
		$self->{connected} = 0;
	}

	return $self->{connected};
}

# $self->subscribe($topic, $callback):
#	subscribe to an MQTT topic with a callback for messages
#	$callback receives ($topic, $payload)
sub subscribe ( $self, $topic, $callback )
{
	$OpenHAP::logger->debug( 'Subscribing to MQTT topic: %s', $topic );
	$self->{subscriptions}{$topic} = $callback;

	return unless $self->{connected} && $self->{client};

	# Net::MQTT::Simple uses a different subscription model
	# We register topics and poll for messages in tick().
	# Since 1.33 it passes a retain flag as a third argument;
	# accept and ignore any extra arguments.
	eval {
		$self->{client}->subscribe(
			$topic,
			sub ( $topic_received, $payload, @ ) {
				push @{ $self->{pending_messages} },
				    [ $topic_received, $payload ];
			} );
	};

	if ($@) {
		$OpenHAP::logger->error( 'MQTT subscribe error for %s: %s',
			$topic, $@ );
	}
}

# $self->unsubscribe($topic):
#	unsubscribe from an MQTT topic
sub unsubscribe ( $self, $topic )
{
	delete $self->{subscriptions}{$topic};

	return unless $self->{connected} && $self->{client};

	eval { $self->{client}->unsubscribe($topic); };
}

sub publish ( $self, $topic, $payload, $retain = 0 )
{
	return unless $self->{connected} && $self->{client};

	$OpenHAP::logger->debug(
		'Publishing to MQTT topic %s: %s',
		$topic,
		length($payload) > 50
		? substr( $payload, 0, 50 ) . '...'
		: $payload
	);
	eval {
		if ($retain) {
			$self->{client}->retain( $topic, $payload );
		}
		else {
			$self->{client}->publish( $topic, $payload );
		}
	};

	if ($@) {
		$OpenHAP::logger->error( 'MQTT publish error: %s', $@ );
	}
}

# $self->tick($timeout):
#	process pending MQTT messages, call from main event loop
#	$timeout is maximum seconds to wait (default 0 = non-blocking)
#	returns number of messages processed
sub tick ( $self, $timeout = 0 )
{
	return 0 unless $self->{connected} && $self->{client};

	my $processed = 0;

	# Process any incoming messages with timeout
	# Capture warnings from Net::MQTT::Simple's connection attempts
	my @warnings;
	local $SIG{__WARN__} = sub {
		push @warnings, shift;
	};

	eval { $self->{client}->tick($timeout); };

	# Log captured warnings through our logging system
	for my $warning (@warnings) {
		chomp $warning;

	     # Strip program name if present (e.g., "/usr/local/bin/openhapd: ")
		$warning =~ s{^(?:.*/)?[^/]+:\s+}{};
		$OpenHAP::logger->debug( 'MQTT: %s', $warning );
	}

	if ($@) {

		# Connection may have been lost
		if ( $@ =~ /connection|socket|closed/i ) {
			$self->{connected} = 0;
			$OpenHAP::logger->warning( 'MQTT connection lost: %s',
				$@ );
			return 0;
		}
		$OpenHAP::logger->error( 'MQTT tick error: %s', $@ );
	}

	# Process pending messages through callbacks
	while ( @{ $self->{pending_messages} } > 0 ) {
		my $msg = shift @{ $self->{pending_messages} };
		my ( $topic_received, $payload ) = @$msg;

		$processed +=
		    $self->_dispatch_message( $topic_received, $payload );
	}

	$self->{last_tick} = time;
	return $processed;
}

# $self->_dispatch_message($topic, $payload):
#	dispatch a message to matching subscription callbacks
#	$callback receives ($topic, $payload) - topic is the actual received topic
sub _dispatch_message ( $self, $topic, $payload )
{
	my $dispatched = 0;

	for my $pattern ( keys %{ $self->{subscriptions} } ) {
		if ( $self->_topic_matches( $pattern, $topic ) ) {
			my $callback = $self->{subscriptions}{$pattern};
			eval { $callback->( $topic, $payload ); };
			if ($@) {
				$OpenHAP::logger->error(
					'MQTT callback error for %s: %s',
					$topic, $@ );
			}
			$dispatched++;
		}
	}

	return $dispatched;
}

# $self->_topic_matches($pattern, $topic):
#	check if a topic matches a subscription pattern
#	supports + (single level) and # (multi level) wildcards
sub _topic_matches ( $self, $pattern, $topic )
{
	# Exact match
	return 1 if $pattern eq $topic;

	# No wildcards, must be exact
	return 0 unless $pattern =~ m{[+#]};

	my @pattern_parts = split m{/}, $pattern;
	my @topic_parts   = split m{/}, $topic;

	for my $i ( 0 .. $#pattern_parts ) {
		my $p = $pattern_parts[$i];

		# Multi-level wildcard matches everything remaining
		return 1 if $p eq '#';

		# Topic is shorter than pattern (without #)
		return 0 if $i > $#topic_parts;

		# Single-level wildcard matches any single level
		next if $p eq '+';

		# Exact level match required
		return 0 if $p ne $topic_parts[$i];
	}

	# Pattern exhausted, topic must also be exhausted
	return @topic_parts == @pattern_parts;
}

# $self->resubscribe():
#	resubscribe to all topics after reconnection
sub resubscribe ($self)
{
	return unless $self->{connected} && $self->{client};

	for my $topic ( keys %{ $self->{subscriptions} } ) {
		my $callback = $self->{subscriptions}{$topic};
		eval {
			$self->{client}->subscribe(
				$topic,
				sub ( $topic_received, $payload, @ ) {
					push @{ $self->{pending_messages} },
					    [ $topic_received, $payload ];
				} );
		};
		if ($@) {
			$OpenHAP::logger->error(
				'MQTT resubscribe error for %s: %s',
				$topic, $@ );
		}
	}
}

# $self->reconnect():
#	attempt to reconnect to the broker
#	returns 1 on success, 0 on failure
sub reconnect ($self)
{
	$OpenHAP::logger->debug('Attempting MQTT reconnection');
	$self->disconnect();

	if ( $self->mqtt_connect() ) {
		$self->resubscribe();
		$OpenHAP::logger->debug('MQTT reconnected successfully');
		return 1;
	}

	return 0;
}

sub disconnect ($self)
{
	if ( $self->{connected} && $self->{client} ) {
		eval { $self->{client}->disconnect(); };
		$self->{client}    = undef;
		$self->{connected} = 0;
	}
	$self->{pending_messages} = [];
}

sub is_connected ($self)
{
	return $self->{connected};
}

# $self->subscriptions():
#	return list of subscribed topics
sub subscriptions ($self)
{
	return keys %{ $self->{subscriptions} };
}

1;
