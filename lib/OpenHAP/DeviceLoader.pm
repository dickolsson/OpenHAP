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

package OpenHAP::DeviceLoader;

use OpenHAP::Tasmota::Thermostat;
use OpenHAP::Tasmota::Heater;
use OpenHAP::Tasmota::Sensor;
use OpenHAP::Tasmota::Lightbulb;

# $class->new():
#	Create a new device loader instance.
sub new ($class)
{
	bless {
		next_aid => 2,    # AID 1 is the bridge
		devices  => [],
	}, $class;
}

# $self->load_devices($config, $hap, $mqtt):
#	Load the devices from the configuration. Add them to the
#	HAP bridge. The method returns the number of loaded devices.
sub load_devices ( $self, $config, $hap, $mqtt )
{
	my @devices = $config->get_devices();
	$OpenHAP::logger->debug( 'Loading %d device(s) from configuration',
		scalar @devices );

	my $loaded_count   = 0;
	my $mqtt_connected = $mqtt->is_connected();

	for my $device (@devices) {
		my $accessory =
		    $self->_create_device( $device, $mqtt, $mqtt_connected );
		next unless defined $accessory;

		$hap->add_accessory($accessory);
		push @{ $self->{devices} }, $accessory;
		$loaded_count++;

		$OpenHAP::logger->info(
			'Added %s: %s (AID=%d)',
			$self->_device_type_name($device),
			$device->{name}, $accessory->{aid} );
	}

	$OpenHAP::logger->info( 'Loaded %d device(s), %d skipped',
		$loaded_count, scalar(@devices) - $loaded_count );

	return $loaded_count;
}

# $self->get_devices():
#	Return the list of loaded device accessory objects.
sub get_devices ($self)
{
	return @{ $self->{devices} };
}

# $self->_create_device($device, $mqtt, $mqtt_connected):
#	Create an accessory from the device configuration.
#	The method returns the accessory object, or undef on error.
sub _create_device ( $self, $device, $mqtt, $mqtt_connected )
{
	my $dev_type    = $device->{type}    // 'unknown';
	my $dev_subtype = $device->{subtype} // 'unknown';

	$OpenHAP::logger->debug(
		'Processing device: type=%s, subtype=%s, name=%s',
		$dev_type, $dev_subtype, $device->{name} // '<unnamed>' );

	# Validate the device type
	unless ( $self->_is_supported_device( $dev_type, $dev_subtype ) ) {
		$OpenHAP::logger->debug(
			'Skipping unsupported device type: %s/%s',
			$dev_type, $dev_subtype );
		return;
	}

	# Validate the required fields
	return unless $self->_validate_device($device);

	# Create the device and catch errors
	my $accessory;
	eval {
		$accessory =
		    $self->_instantiate_device( $device, $mqtt, $dev_type,
			$dev_subtype );
	};
	if ($@) {
		$OpenHAP::logger->error(
			'Failed to create %s "%s": %s',
			$self->_device_type_name($device),
			$device->{name}, $@
		);
		return;
	}

	# Subscribe to MQTT if the client is connected
	if ($mqtt_connected) {
		$self->_subscribe_mqtt( $accessory, $device );
	}
	else {
		$OpenHAP::logger->debug(
			'MQTT not connected, deferring subscription for "%s"',
			$device->{name} );
	}

	return $accessory;
}

# $self->_is_supported_device($type, $subtype):
#	Check if the loader supports the device type.
sub _is_supported_device ( $self, $type, $subtype )
{
	return 1 if $type eq 'tasmota' && $subtype eq 'thermostat';
	return 1 if $type eq 'tasmota' && $subtype eq 'heater';
	return 1 if $type eq 'tasmota' && $subtype eq 'switch';
	return 1 if $type eq 'tasmota' && $subtype eq 'sensor';
	return 1 if $type eq 'tasmota' && $subtype eq 'lightbulb';
	return 1 if $type eq 'tasmota' && $subtype eq 'dimmer';
	return 1 if $type eq 'tasmota' && $subtype eq 'rgblight';
	return 1 if $type eq 'tasmota' && $subtype eq 'ctlight';
	return;
}

# $self->_validate_device($device):
#	Validate the required device fields. The method returns true
#	if the device is valid.
sub _validate_device ( $self, $device )
{
	unless ( defined $device->{name} && $device->{name} ne '' ) {
		$OpenHAP::logger->error('Device missing required field: name');
		return;
	}

	unless ( defined $device->{topic} && $device->{topic} ne '' ) {
		$OpenHAP::logger->error(
			'Device "%s" missing required field: topic',
			$device->{name} );
		return;
	}

	unless ( defined $device->{id} && $device->{id} ne '' ) {
		$OpenHAP::logger->warning(
			'Device "%s" missing id field, using topic as serial',
			$device->{name} );
		$device->{id} = $device->{topic};
	}

	return 1;
}

# $self->_instantiate_device($device, $mqtt, $type, $subtype):
#	Create the device object for the given type.
sub _instantiate_device ( $self, $device, $mqtt, $type, $subtype )
{
	my %common_args = (
		aid         => $self->{next_aid}++,
		name        => $device->{name},
		mqtt_topic  => $device->{topic},
		mqtt_client => $mqtt,
		serial      => $device->{id},
		relay_index => $device->{relay_index} // 0,
	);

	if ( $type eq 'tasmota' ) {
		if ( $subtype eq 'thermostat' ) {
			return OpenHAP::Tasmota::Thermostat->new(
				%common_args,
				sensor_type  => $device->{sensor_type},
				sensor_index => $device->{sensor_index},
			);
		}

		if ( $subtype eq 'heater' || $subtype eq 'switch' ) {
			return OpenHAP::Tasmota::Heater->new(%common_args);
		}

		if ( $subtype eq 'sensor' ) {
			return OpenHAP::Tasmota::Sensor->new(
				%common_args,
				sensor_type  => $device->{sensor_type},
				sensor_index => $device->{sensor_index},
				has_humidity => $device->{has_humidity} // 0,
			);
		}

		if ( $subtype eq 'lightbulb' || $subtype eq 'dimmer' ) {
			return OpenHAP::Tasmota::Lightbulb->new( %common_args,
				capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER, );
		}

		if ( $subtype eq 'rgblight' ) {
			return OpenHAP::Tasmota::Lightbulb->new( %common_args,
				capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER |
				    OpenHAP::Tasmota::Lightbulb::CAP_COLOR, );
		}

		if ( $subtype eq 'ctlight' ) {
			return OpenHAP::Tasmota::Lightbulb->new( %common_args,
				capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER |
				    OpenHAP::Tasmota::Lightbulb::CAP_CT, );
		}
	}

	die "Unsupported device type: $type/$subtype";
}

# $self->_subscribe_mqtt($accessory, $device):
#	Subscribe the device to its MQTT topics.
sub _subscribe_mqtt ( $self, $accessory, $device )
{
	eval { $accessory->subscribe_mqtt(); };
	if ($@) {
		$OpenHAP::logger->error(
			'Failed to subscribe MQTT for "%s": %s',
			$device->{name}, $@ );
	}
	else {
		$OpenHAP::logger->info( 'Subscribed to MQTT topic: %s',
			$device->{topic} );
	}
}

# $self->_device_type_name($device):
#	Return the human-readable device type name.
sub _device_type_name ( $self, $device )
{
	my $type    = $device->{type}    // 'unknown';
	my $subtype = $device->{subtype} // 'unknown';

	return 'thermostat' if $type eq 'tasmota' && $subtype eq 'thermostat';
	return 'switch'     if $type eq 'tasmota' && $subtype eq 'heater';
	return 'switch'     if $type eq 'tasmota' && $subtype eq 'switch';
	return 'sensor'     if $type eq 'tasmota' && $subtype eq 'sensor';
	return 'lightbulb'  if $type eq 'tasmota' && $subtype eq 'lightbulb';
	return 'dimmer'     if $type eq 'tasmota' && $subtype eq 'dimmer';
	return 'rgb light'  if $type eq 'tasmota' && $subtype eq 'rgblight';
	return 'ct light'   if $type eq 'tasmota' && $subtype eq 'ctlight';
	return "$type/$subtype";
}

1;
