# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2025 Dick Olsson <hi@senzilla.io>
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

package OpenHAP::Tasmota::Base;
require OpenHAP::Accessory;
our @ISA = qw(OpenHAP::Accessory);

use JSON::XS;

use constant {

	# Device availability states
	AVAILABILITY_UNKNOWN => 0,
	AVAILABILITY_ONLINE  => 1,
	AVAILABILITY_OFFLINE => 2,
};

sub new ( $class, %args )
{
	my $self = $class->SUPER::new(%args);

	$self->{mqtt_topic}   = $args{mqtt_topic};
	$self->{mqtt_client}  = $args{mqtt_client};
	$self->{relay_index}  = $args{relay_index} // 0;    # 0 = no index
	$self->{availability} = AVAILABILITY_UNKNOWN;
	$self->{temp_unit}    = 'C';                        # Default to Celsius
	$self->{last_state}   = {};    # Cache of last known state

	# FullTopic pattern (H2). The default is %prefix%/%topic%/
	$self->{fulltopic} = $args{fulltopic} // '%prefix%/%topic%/';

	# SetOption26: use the indexed POWER1 for single-relay devices (M1)
	$self->{setoption26} = $args{setoption26} // 0;

	return $self;
}

# $self->subscribe_mqtt():
#	Subscribe to all standard Tasmota topics.
#	Subclasses must call SUPER::subscribe_mqtt() first.
sub subscribe_mqtt ($self)
{
	my $topic = $self->{mqtt_topic};

	return unless $self->{mqtt_client}->is_connected();

	$OpenHAP::logger->debug( 'Tasmota %s subscribing to MQTT topics for %s',
		ref($self), $self->{name} );

	# C1: Subscribe to LWT for device availability
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'tele', 'LWT' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_lwt($payload);
		} );

	# C2: Subscribe to tele/STATE for periodic state updates
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'tele', 'STATE' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_state($payload);
		} );

	# C3: Subscribe to stat/RESULT for command responses
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'stat', 'RESULT' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_result($payload);
		} );

	# Subscribe to tele/SENSOR for sensor data
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'tele', 'SENSOR' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_sensor($payload);
		} );

	# C1/H1: Subscribe to STATUS11 for full state reconciliation
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'stat', 'STATUS11' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_status11($payload);
		} );
}

# $self->query_initial_state():
#	Query the device for the current state after a connect or
#	an LWT Online. The method uses Status 11 for full state
#	reconciliation (C1/H1).
sub query_initial_state ($self)
{
	return unless $self->{mqtt_client}->is_connected();

	$OpenHAP::logger->debug( 'Querying initial state for %s',
		$self->{name} );

	# Request the full status (Status 11). Spec §6.1 recommends
	# this query.
	$self->{mqtt_client}
	    ->publish( $self->_build_topic( 'cmnd', 'Status' ), '11' );
}

# $self->is_online():
#	Check if the device is online.
sub is_online ($self)
{
	return $self->{availability} == AVAILABILITY_ONLINE;
}

# $self->get_availability():
#	Get the device availability state.
sub get_availability ($self)
{
	return $self->{availability};
}

# $self->_handle_lwt($payload):
#	Process the LWT (Last Will and Testament) message (C1).
sub _handle_lwt ( $self, $payload )
{
	my $prev = $self->{availability};

	if ( $payload eq 'Online' ) {
		$self->{availability} = AVAILABILITY_ONLINE;
		$OpenHAP::logger->info( 'Device %s is online', $self->{name} );

		# Query the initial state when the device comes online (H3)
		$self->query_initial_state();
	}
	elsif ( $payload eq 'Offline' ) {
		$self->{availability} = AVAILABILITY_OFFLINE;
		$OpenHAP::logger->warning( 'Device %s is offline',
			$self->{name} );
	}
	else {
		$OpenHAP::logger->debug( 'Unknown LWT payload for %s: %s',
			$self->{name}, $payload );
	}

	# Notify the subclass if the availability changed
	if ( $prev != $self->{availability} ) {
		$self->_on_availability_changed( $prev, $self->{availability} );
	}
}

# $self->_handle_state($payload):
#	Process the periodic STATE message from the tele/ topic (C2).
sub _handle_state ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);
		$self->_process_state_data($data);
	};

	if ($@) {
		$OpenHAP::logger->error( 'Error parsing STATE for %s: %s',
			$self->{name}, $@ );
	}
}

# $self->_handle_result($payload):
#	Process the RESULT message from the stat/ topic (C3).
sub _handle_result ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);
		$self->_process_result_data($data);
	};

	if ($@) {
		$OpenHAP::logger->error( 'Error parsing RESULT for %s: %s',
			$self->{name}, $@ );
	}
}

# $self->_handle_sensor($payload):
#	Process the SENSOR message from the tele/ topic.
sub _handle_sensor ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);

		# Extract the temperature unit if it is present (H4)
		if ( exists $data->{TempUnit} ) {
			$self->{temp_unit} = $data->{TempUnit};
		}

		$self->_process_sensor_data($data);
	};

	if ($@) {
		$OpenHAP::logger->error( 'Error parsing SENSOR for %s: %s',
			$self->{name}, $@ );
	}
}

# $self->_handle_status11($payload):
#	Process the STATUS11 response for state reconciliation (C1/H1).
sub _handle_status11 ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);

		# STATUS11 wraps the data in StatusSTS. The format is
		# the same as the periodic STATE.
		if ( exists $data->{StatusSTS} ) {
			my $sts = $data->{StatusSTS};

			$OpenHAP::logger->debug( 'STATUS11 received for %s',
				$self->{name} );

			# Cache the state data
			$self->{last_state} =
			    { %{ $self->{last_state} }, %$sts };

			# Process the data as state data
			$self->_process_state_data($sts);
		}
	};

	if ($@) {
		$OpenHAP::logger->error( 'Error parsing STATUS11 for %s: %s',
			$self->{name}, $@ );
	}
}

# $self->_process_state_data($data):
#	Process the parsed STATE data. Subclasses can override
#	this method.
sub _process_state_data ( $self, $data )
{
	# Cache the state data
	$self->{last_state} = { %{ $self->{last_state} }, %$data };

	# The default implementation checks for the POWER state
	$self->_extract_power_state($data);
}

# $self->_process_result_data($data):
#	Process the parsed RESULT data. Subclasses can override
#	this method.
sub _process_result_data ( $self, $data )
{
	# The default implementation checks for the POWER state
	$self->_extract_power_state($data);
}

# $self->_process_sensor_data($data):
#	Process the parsed SENSOR data. Subclasses can override
#	this method.
sub _process_sensor_data ( $self, $data )
{
	# The default does nothing. Subclasses can override this
	# method.
}

# $self->_extract_power_state($data):
#	Extract the power state from the JSON data. The method
#	supports multi-relay devices (H1).
sub _extract_power_state ( $self, $data )
{
	my $power_key = $self->_get_power_key();

	if ( exists $data->{$power_key} ) {
		my $power = $data->{$power_key};
		$self->_on_power_update( $power eq 'ON' ? 1 : 0 );
	}
}

# $self->_get_power_key():
#	Get the power key name for this device.
#	The method supports multi-relay (H1) and SetOption26 (M1).
sub _get_power_key ($self)
{
	if ( $self->{relay_index} && $self->{relay_index} > 0 ) {
		return 'POWER' . $self->{relay_index};
	}

	# M1: SetOption26 uses the indexed format even for
	# single-relay devices
	if ( $self->{setoption26} ) {
		return 'POWER1';
	}

	return 'POWER';
}

# $self->_get_power_topic():
#	Get the power topic for commands (H1 multi-relay support).
sub _get_power_topic ($self)
{
	if ( $self->{relay_index} && $self->{relay_index} > 0 ) {
		return $self->_build_topic( 'cmnd',
			'Power' . $self->{relay_index} );
	}

	# M1: SetOption26 uses the indexed format even for
	# single-relay devices
	if ( $self->{setoption26} ) {
		return $self->_build_topic( 'cmnd', 'Power1' );
	}

	return $self->_build_topic( 'cmnd', 'Power' );
}

# $self->_build_topic($prefix, $command):
#	Build a topic with the FullTopic pattern (H2).
#	$prefix: 'cmnd', 'stat', or 'tele'
#	$command: The command/topic suffix
sub _build_topic ( $self, $prefix, $command )
{
	my $fulltopic = $self->{fulltopic};
	my $topic     = $self->{mqtt_topic};

	# Replace the tokens
	$fulltopic =~ s/%prefix%/$prefix/g;
	$fulltopic =~ s/%topic%/$topic/g;

	# Remove the trailing slash. Then append the command.
	$fulltopic =~ s{/$}{};

	return "$fulltopic/$command";
}

# $self->_on_power_update($state):
#	The base class calls this method when the power state
#	updates. Subclasses can override it.
sub _on_power_update ( $self, $state )
{
	# Default: no-op
}

# $self->_on_availability_changed($old, $new):
#	The base class calls this method when the device
#	availability changes. Subclasses can override it.
sub _on_availability_changed ( $self, $old, $new )
{
	# Default: no-op
}

# $self->convert_temperature($temp):
#	Convert the temperature to Celsius if necessary (H4).
sub convert_temperature ( $self, $temp )
{
	return $temp unless defined $temp;

	if ( $self->{temp_unit} eq 'F' ) {

		# Convert Fahrenheit to Celsius
		return ( $temp - 32 ) * 5 / 9;
	}

	return $temp;
}

# $self->set_power($state):
#	Set the power state (0=OFF, 1=ON).
sub set_power ( $self, $state )
{
	my $command = $state ? 'ON' : 'OFF';
	my $topic   = $self->_get_power_topic();

	$OpenHAP::logger->debug( '%s power set to %s', $self->{name},
		$command );
	$self->{mqtt_client}->publish( $topic, $command );
}

# $self->toggle_power():
#	Toggle the power state (L1).
sub toggle_power ($self)
{
	my $topic = $self->_get_power_topic();

	$OpenHAP::logger->debug( '%s power toggled', $self->{name} );
	$self->{mqtt_client}->publish( $topic, 'TOGGLE' );
}

# $self->blink($on):
#	Start or stop blinking (L2).
sub blink ( $self, $on = 1 )
{
	my $topic   = $self->_get_power_topic();
	my $command = $on ? 'BLINK' : 'BLINKOFF';

	$OpenHAP::logger->debug( '%s blink %s', $self->{name}, $command );
	$self->{mqtt_client}->publish( $topic, $command );
}

# $self->query_status($type):
#	Query the device status.
#	$type: 0 = all, 8 = sensors, 11 = full state, and other STATUS codes
sub query_status ( $self, $type = 11 )
{
	$self->{mqtt_client}
	    ->publish( $self->_build_topic( 'cmnd', 'Status' ), "$type" );
}

# $self->force_telemetry():
#	Force an immediate telemetry update (L1).
#	The device then sends STATE and SENSOR messages.
sub force_telemetry ($self)
{
	$OpenHAP::logger->debug( 'Forcing telemetry for %s', $self->{name} );
	$self->{mqtt_client}
	    ->publish( $self->_build_topic( 'cmnd', 'TelePeriod' ), '' );
}

1;
