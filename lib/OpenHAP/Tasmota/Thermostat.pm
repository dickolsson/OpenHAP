use v5.36;

package OpenHAP::Tasmota::Thermostat;

use FuguLib::Log;
require OpenHAP::Tasmota::Base;
our @ISA = qw(OpenHAP::Tasmota::Base);
use OpenHAP::Service;
use OpenHAP::Characteristic;

use JSON::XS;

# Supported sensor types for thermostat
use constant SENSOR_TYPES =>
    qw(DS18B20 DHT11 DHT22 AM2301 BME280 BMP280 SHT3X SI7021);

sub new ( $class, %args )
{

	my $self = $class->SUPER::new(
		aid          => $args{aid},
		name         => $args{name},
		model        => 'Tasmota Thermostat',
		manufacturer => 'OpenHAP',
		serial       => $args{serial} // 'TSTAT-001',
		mqtt_topic   => $args{mqtt_topic},
		mqtt_client  => $args{mqtt_client},
		relay_index  => $args{relay_index} // 0,
		fulltopic    => $args{fulltopic},               # H2
		setoption26  => $args{setoption26},             # M1
	);

	# Sensor configuration (H5)
	$self->{sensor_type}  = $args{sensor_type};     # undef = auto-detect
	$self->{sensor_index} = $args{sensor_index};    # For indexed sensors

	# Current state
	$self->{current_temp}         = 20.0;
	$self->{target_temp}          = 20.0;
	$self->{heating_state}        = 0;              # 0=Off, 1=Heat, 2=Cool
	$self->{target_heating_state} = 0;

	# Add the Thermostat service
	my $thermostat = OpenHAP::Service->new(
		type => 'Thermostat',
		iid  => 10,
	);

	$thermostat->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'CurrentHeatingCoolingState',
			iid    => 11,
			format => 'uint8',
			perms  => [ 'pr', 'ev' ],
			value  => \$self->{heating_state},
		) );

	$thermostat->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'TargetHeatingCoolingState',
			iid    => 12,
			format => 'uint8',
			perms  => [ 'pr', 'pw', 'ev' ],
			value  => \$self->{target_heating_state},
			on_set => sub { $self->_set_target_state(@_) },
		) );

	$thermostat->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'CurrentTemperature',
			iid    => 13,
			format => 'float',
			perms  => [ 'pr', 'ev' ],
			unit   => 'celsius',
			value  => \$self->{current_temp},
			min    => -40,
			max    => 100,
		) );

	$thermostat->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'TargetTemperature',
			iid    => 14,
			format => 'float',
			perms  => [ 'pr', 'pw', 'ev' ],
			unit   => 'celsius',
			value  => \$self->{target_temp},
			min    => 10,
			max    => 38,
			step   => 0.5,
			on_set => sub { $self->_set_target_temp(@_) },
		) );

	$thermostat->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'TemperatureDisplayUnits',
			iid    => 15,
			format => 'uint8',
			perms  => [ 'pr', 'pw', 'ev' ],
			value  => 0,    # 0=Celsius, 1=Fahrenheit
		) );

	$self->add_service($thermostat);

	return $self;
}

sub subscribe_mqtt ($self)
{
	# Call the base class to set up the standard subscriptions
	# (C1, C2, C3)
	$self->SUPER::subscribe_mqtt();

	return unless $self->{mqtt_client}->is_connected();

	FuguLib::Log->default->debug(
		'Thermostat %s subscribing to additional MQTT topics',
		$self->{name} );

	# M2: Subscribe to the plain-text POWER response
	# (SetOption4 support)
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'stat', $self->_get_power_key() ),
		sub ( $recv_topic, $payload ) {
			my $new_state = ( $payload eq 'ON' ) ? 1 : 0;
			if ( $self->{heating_state} != $new_state ) {
				$self->{heating_state} = $new_state;
				FuguLib::Log->default->debug(
					'Thermostat %s heating state: %s',
					$self->{name}, $payload );
				$self->notify_change(11);
			}
		} );

	# Subscribe to STATUS8 for sensor data
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'stat', 'STATUS8' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_status8($payload);
		} );

	# Subscribe to STATUS10 for sensor data. The spec recommends
	# this query.
	$self->{mqtt_client}->subscribe(
		$self->_build_topic( 'stat', 'STATUS10' ),
		sub ( $recv_topic, $payload ) {
			$self->_handle_status10($payload);
		} );

	# Query the sensor status immediately
	$self->query_status(10);
}

# Override the base method to process the sensor data from
# SENSOR messages
sub _process_sensor_data ( $self, $data )
{
	$self->_extract_temperature($data);
}

# Override the base method to process the power state updates
sub _on_power_update ( $self, $state )
{
	if ( $self->{heating_state} != $state ) {
		$self->{heating_state} = $state;
		FuguLib::Log->default->debug(
			'Thermostat %s heating updated: %s',
			$self->{name}, $state ? 'ON' : 'OFF' );
		$self->notify_change(11);
	}
}

# Process the STATUS8 response
sub _handle_status8 ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);

		if ( exists $data->{StatusSNS} ) {

			# Extract the temperature unit if it is
			# present (H4)
			if ( exists $data->{StatusSNS}{TempUnit} ) {
				$self->{temp_unit} =
				    $data->{StatusSNS}{TempUnit};
			}

			$self->_extract_temperature( $data->{StatusSNS} );
		}
	};

	if ($@) {
		FuguLib::Log->default->error(
			'Error parsing STATUS8 for %s: %s',
			$self->{name}, $@ );
	}
}

# Process the STATUS10 response (recommended sensor query)
sub _handle_status10 ( $self, $payload )
{
	eval {
		my $data = decode_json($payload);

		if ( exists $data->{StatusSNS} ) {
			if ( exists $data->{StatusSNS}{TempUnit} ) {
				$self->{temp_unit} =
				    $data->{StatusSNS}{TempUnit};
			}
			$self->_extract_temperature( $data->{StatusSNS} );
		}
	};

	if ($@) {
		FuguLib::Log->default->error(
			'Error parsing STATUS10 for %s: %s',
			$self->{name}, $@ );
	}
}

# $self->_extract_temperature($data):
#	Extract the temperature from the sensor data (H4, H5).
sub _extract_temperature ( $self, $data )
{
	my $temp = $self->_find_temperature($data);

	if ( defined $temp ) {

		# Convert the value to Celsius if necessary (H4)
		$temp = $self->convert_temperature($temp);

		FuguLib::Log->default->debug(
			'Thermostat %s temperature updated: %.1f°C',
			$self->{name}, $temp );
		$self->{current_temp} = $temp;
		$self->notify_change(13);
		$self->_check_thermostat_logic();
	}
}

# $self->_find_temperature($data):
#	Find the temperature value in the sensor data (H5).
sub _find_temperature ( $self, $data )
{
	# If the configuration sets a sensor type, look for that sensor
	if ( defined $self->{sensor_type} ) {
		my $key = $self->{sensor_type};

		# Add the index for indexed sensors, for example DS18B20-1
		if ( defined $self->{sensor_index} ) {
			$key .= '-' . $self->{sensor_index};
		}

		if ( exists $data->{$key} ) {
			return $data->{$key}{Temperature};
		}
	}

	# Auto-detect: try each known sensor type (H5)
	for my $type (SENSOR_TYPES) {
		if ( exists $data->{$type} ) {
			$self->{sensor_type} = $type;
			return $data->{$type}{Temperature};
		}

		# Check for indexed sensors, for example DS18B20-1
		for my $i ( 1 .. 8 ) {
			my $indexed = "$type-$i";
			if ( exists $data->{$indexed} ) {
				$self->{sensor_type}  = $type;
				$self->{sensor_index} = $i;
				return $data->{$indexed}{Temperature};
			}
		}
	}

	return;
}

sub _set_target_temp ( $self, $temp )
{
	FuguLib::Log->default->debug(
		'Thermostat %s target temperature set to %.1f°C',
		$self->{name}, $temp );
	$self->{target_temp} = $temp;
	$self->_check_thermostat_logic();
}

sub _set_target_state ( $self, $state )
{
	FuguLib::Log->default->debug(
		'Thermostat %s target heating state set to %d',
		$self->{name}, $state );
	$self->{target_heating_state} = $state;
	$self->_check_thermostat_logic();
}

sub _check_thermostat_logic ($self)
{
	# Simple bang-bang controller with 0.5°C hysteresis
	my $hysteresis = 0.5;
	my $current    = $self->{current_temp};
	my $target     = $self->{target_temp};

	if ( $self->{target_heating_state} == 0 ) {

		# The target is OFF
		$self->set_power(0) if $self->{heating_state};
	}
	elsif ( $self->{target_heating_state} == 1 ) {

		# The target is HEAT
		if ( $current < $target - $hysteresis ) {
			$self->set_power(1);
		}
		elsif ( $current > $target + $hysteresis ) {
			$self->set_power(0);
		}
	}
}

1;
