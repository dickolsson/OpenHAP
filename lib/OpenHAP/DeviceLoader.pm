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

use FuguLib::Log;

# OpenHAP::DeviceLoader - turn the device blocks of the configuration
# into accessories on the bridge.
#
# One table describes every device type. Each entry says what the type
# is called in a log line, which class builds it, and what that class
# needs beyond the fields every device has. Adding a type is one
# entry, and no second place to keep true.
#
# The class of the entry does the work of building. The loader only
# decides which one, validates the fields the configuration must
# carry, and subscribes the result to MQTT.
#
# A device class loads when the configuration asks for it, not at
# compile time. The classes drag JSON::XS and the whole accessory
# model behind them, and a tool that only reads the device blocks
# needs none of it. The daemon builds its devices before it pledges,
# thus the late load costs it nothing.
my %DEVICE = (
	'tasmota/thermostat' => {
		name  => 'thermostat',
		class => 'OpenHAP::Tasmota::Thermostat',
		args  => sub ($device) {
			return (
				sensor_type  => $device->{sensor_type},
				sensor_index => $device->{sensor_index},
			);
		},
	},
	'tasmota/heater' => {
		name  => 'switch',
		class => 'OpenHAP::Tasmota::Heater',
	},
	'tasmota/switch' => {
		name  => 'switch',
		class => 'OpenHAP::Tasmota::Heater',
	},
	'tasmota/sensor' => {
		name  => 'sensor',
		class => 'OpenHAP::Tasmota::Sensor',
		args  => sub ($device) {
			return (
				sensor_type  => $device->{sensor_type},
				sensor_index => $device->{sensor_index},
				has_humidity => $device->{has_humidity} // 0,
			);
		},
	},
	'tasmota/lightbulb' => {
		name  => 'lightbulb',
		class => 'OpenHAP::Tasmota::Lightbulb',
		args  => sub ($) {
			return ( capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER() );
		},
	},
	'tasmota/dimmer' => {
		name  => 'dimmer',
		class => 'OpenHAP::Tasmota::Lightbulb',
		args  => sub ($) {
			return ( capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER() );
		},
	},
	'tasmota/rgblight' => {
		name  => 'rgb light',
		class => 'OpenHAP::Tasmota::Lightbulb',
		args  => sub ($) {
			return ( capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER() |
				    OpenHAP::Tasmota::Lightbulb::CAP_COLOR() );
		},
	},
	'tasmota/ctlight' => {
		name  => 'ct light',
		class => 'OpenHAP::Tasmota::Lightbulb',
		args  => sub ($) {
			return ( capabilities =>
				    OpenHAP::Tasmota::Lightbulb::CAP_DIMMER() |
				    OpenHAP::Tasmota::Lightbulb::CAP_CT() );
		},
	},
);

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
	my @devices = $self->devices($config);
	FuguLib::Log->default->debug( 'Loading %d device(s) from configuration',
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

		FuguLib::Log->default->info(
			'Added %s: %s (AID=%d)',
			$self->_device_type_name($device),
			$device->{name}, $accessory->{aid} );
	}

	FuguLib::Log->default->info( 'Loaded %d device(s), %d skipped',
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

	FuguLib::Log->default->debug(
		'Processing device: type=%s, subtype=%s, name=%s',
		$dev_type, $dev_subtype, $device->{name} // '<unnamed>' );

	# Validate the device type
	unless ( $self->_is_supported_device( $dev_type, $dev_subtype ) ) {
		FuguLib::Log->default->debug(
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
		FuguLib::Log->default->error(
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
		FuguLib::Log->default->debug(
			'MQTT not connected, deferring subscription for "%s"',
			$device->{name} );
	}

	return $accessory;
}

# $self->_is_supported_device($type, $subtype):
#	Check if the loader supports the device type.
sub _is_supported_device ( $self, $type, $subtype )
{
	return exists $DEVICE{"$type/$subtype"} ? 1 : undef;
}

# $class->devices($config):
#	Return the device blocks of a FuguLib::Config as records with
#	type, subtype, id and the settings of the block.
sub devices ( $, $config )
{
	my @devices;
	for my $block ( $config->blocks('device') ) {
		my ( $type, $subtype, $id ) = @{ $block->{args} };
		push @devices,
		    {
			%{ $block->{settings} },
			type    => $type,
			subtype => $subtype,
			id      => $id,
		    };
	}

	return @devices;
}

# $self->_validate_device($device):
#	Validate the required device fields. The method returns true
#	if the device is valid.
sub _validate_device ( $self, $device )
{
	unless ( defined $device->{name} && $device->{name} ne '' ) {
		FuguLib::Log->default->error(
			'Device missing required field: name');
		return;
	}

	unless ( defined $device->{topic} && $device->{topic} ne '' ) {
		FuguLib::Log->default->error(
			'Device "%s" missing required field: topic',
			$device->{name} );
		return;
	}

	unless ( defined $device->{id} && $device->{id} ne '' ) {
		FuguLib::Log->default->warning(
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
	my $entry = $DEVICE{"$type/$subtype"}
	    or die "Unsupported device type: $type/$subtype";

	# The class loads here, not at compile time. require needs the
	# path form of the name.
	my $module = $entry->{class} =~ s{::}{/}gr;
	require "$module.pm";

	my %args = (
		aid         => $self->{next_aid}++,
		name        => $device->{name},
		mqtt_topic  => $device->{topic},
		mqtt_client => $mqtt,
		serial      => $device->{id},
		relay_index => $device->{relay_index} // 0,
	);
	%args = ( %args, $entry->{args}->($device) ) if $entry->{args};

	return $entry->{class}->new(%args);
}

# $self->_subscribe_mqtt($accessory, $device):
#	Subscribe the device to its MQTT topics.
sub _subscribe_mqtt ( $self, $accessory, $device )
{
	eval { $accessory->subscribe_mqtt(); };
	if ($@) {
		FuguLib::Log->default->error(
			'Failed to subscribe MQTT for "%s": %s',
			$device->{name}, $@ );
	}
	else {
		FuguLib::Log->default->info( 'Subscribed to MQTT topic: %s',
			$device->{topic} );
	}
}

# $self->_device_type_name($device):
#	Return the human-readable device type name.
sub _device_type_name ( $self, $device )
{
	my $type    = $device->{type}    // 'unknown';
	my $subtype = $device->{subtype} // 'unknown';

	my $entry = $DEVICE{"$type/$subtype"};

	return $entry ? $entry->{name} : "$type/$subtype";
}

1;
