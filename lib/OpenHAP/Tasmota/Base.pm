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

	# FullTopic pattern (H2) - default: %prefix%/%topic%/
	$self->{fulltopic} = $args{fulltopic} // '%prefix%/%topic%/';

	# SetOption26: use indexed POWER1 for single-relay devices (M1)
	$self->{setoption26} = $args{setoption26} // 0;

	return $self;
}

# $self->subscribe_mqtt():
#	Subscribe to all standard Tasmota topics.
#	Subclasses should call SUPER::subscribe_mqtt() first.
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
#	Query device for current state after connect or LWT Online.
#	Uses Status 11 for full state reconciliation (C1/H1).
sub query_initial_state ($self)
{
	return unless $self->{mqtt_client}->is_connected();

	$OpenHAP::logger->debug( 'Querying initial state for %s',
		$self->{name} );

	# Request full status (Status 11) - recommended per spec §6.1
	$self->{mqtt_client}
	    ->publish( $self->_build_topic( 'cmnd', 'Status' ), '11' );
}

# $self->is_online():
#	Check if device is online.
sub is_online ($self)
{
	return $self->{availability} == AVAILABILITY_ONLINE;
}

# $self->get_availability():
#	Get device availability state.
sub get_availability ($self)
{
	return $self->{availability};
}

# $self->_handle_lwt($payload):
#	Handle LWT (Last Will and Testament) message (C1).
sub _handle_lwt ( $self, $payload )
{
	my $prev = $self->{availability};

	if ( $payload eq 'Online' ) {
		$self->{availability} = AVAILABILITY_ONLINE;
		$OpenHAP::logger->info( 'Device %s is online', $self->{name} );

		# Query initial state when device comes online (H3)
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

	# Notify if availability changed
	if ( $prev != $self->{availability} ) {
		$self->_on_availability_changed( $prev, $self->{availability} );
	}
}

# $self->_handle_state($payload):
#	Handle periodic STATE message from tele/ topic (C2).
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
#	Handle RESULT message from stat/ topic (C3).
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
#	Handle SENSOR message from tele/ topic.
sub _handle_sensor ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);

		# Extract temperature unit if present (H4)
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
#	Handle STATUS11 response for state reconciliation (C1/H1).
sub _handle_status11 ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);

		# STATUS11 wraps data in StatusSTS (same as periodic STATE)
		if ( exists $data->{StatusSTS} ) {
			my $sts = $data->{StatusSTS};

			$OpenHAP::logger->debug( 'STATUS11 received for %s',
				$self->{name} );

			# Cache state data
			$self->{last_state} =
			    { %{ $self->{last_state} }, %$sts };

			# Process as state data
			$self->_process_state_data($sts);
		}
	};

	if ($@) {
		$OpenHAP::logger->error( 'Error parsing STATUS11 for %s: %s',
			$self->{name}, $@ );
	}
}

# $self->_process_state_data($data):
#	Process parsed STATE data. Override in subclasses.
sub _process_state_data ( $self, $data )
{
	# Cache state data
	$self->{last_state} = { %{ $self->{last_state} }, %$data };

	# Default implementation: check for POWER state
	$self->_extract_power_state($data);
}

# $self->_process_result_data($data):
#	Process parsed RESULT data. Override in subclasses.
sub _process_result_data ( $self, $data )
{
	# Default implementation: check for POWER state
	$self->_extract_power_state($data);
}

# $self->_process_sensor_data($data):
#	Process parsed SENSOR data. Override in subclasses.
sub _process_sensor_data ( $self, $data )
{
	# Default: no-op, subclasses should override
}

# $self->_extract_power_state($data):
#	Extract power state from JSON data, handling multi-relay (H1).
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
#	Handles multi-relay (H1) and SetOption26 (M1) support.
sub _get_power_key ($self)
{
	if ( $self->{relay_index} && $self->{relay_index} > 0 ) {
		return 'POWER' . $self->{relay_index};
	}

	# M1: SetOption26 uses indexed format even for single-relay
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

	# M1: SetOption26 uses indexed format even for single-relay
	if ( $self->{setoption26} ) {
		return $self->_build_topic( 'cmnd', 'Power1' );
	}

	return $self->_build_topic( 'cmnd', 'Power' );
}

# $self->_build_topic($prefix, $command):
#	Build a topic using the FullTopic pattern (H2).
#	$prefix: 'cmnd', 'stat', or 'tele'
#	$command: The command/topic suffix
sub _build_topic ( $self, $prefix, $command )
{
	my $fulltopic = $self->{fulltopic};
	my $topic     = $self->{mqtt_topic};

	# Substitute tokens
	$fulltopic =~ s/%prefix%/$prefix/g;
	$fulltopic =~ s/%topic%/$topic/g;

	# Remove trailing slash and append command
	$fulltopic =~ s{/$}{};

	return "$fulltopic/$command";
}

# $self->_on_power_update($state):
#	Called when power state updates. Override in subclasses.
sub _on_power_update ( $self, $state )
{
	# Default: no-op
}

# $self->_on_availability_changed($old, $new):
#	Called when device availability changes. Override in subclasses.
sub _on_availability_changed ( $self, $old, $new )
{
	# Default: no-op
}

# $self->convert_temperature($temp):
#	Convert temperature to Celsius if needed (H4).
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
#	Set power state (0=OFF, 1=ON).
sub set_power ( $self, $state )
{
	my $command = $state ? 'ON' : 'OFF';
	my $topic   = $self->_get_power_topic();

	$OpenHAP::logger->debug( '%s power set to %s', $self->{name},
		$command );
	$self->{mqtt_client}->publish( $topic, $command );
}

# $self->toggle_power():
#	Toggle power state (L1).
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
#	Query device status.
#	$type: 0 = all, 8 = sensors, 11 = full state, etc.
sub query_status ( $self, $type = 11 )
{
	$self->{mqtt_client}
	    ->publish( $self->_build_topic( 'cmnd', 'Status' ), "$type" );
}

# $self->force_telemetry():
#	Force immediate telemetry update (L1).
#	Triggers STATE and SENSOR messages from the device.
sub force_telemetry ($self)
{
	$OpenHAP::logger->debug( 'Forcing telemetry for %s', $self->{name} );
	$self->{mqtt_client}
	    ->publish( $self->_build_topic( 'cmnd', 'TelePeriod' ), '' );
}

1;
