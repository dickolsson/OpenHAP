use v5.36;

package OpenHAP::Characteristic;

use JSON::XS;

# HAP Base UUID suffix for Apple-defined characteristics
use constant HAP_BASE_UUID => '-0000-1000-8000-0026BB765291';

# HAP Characteristic Type UUIDs
our %CHAR_TYPES = (

	# Accessory Information
	'Identify'         => '00000014-0000-1000-8000-0026BB765291',
	'Manufacturer'     => '00000020-0000-1000-8000-0026BB765291',
	'Model'            => '00000021-0000-1000-8000-0026BB765291',
	'Name'             => '00000023-0000-1000-8000-0026BB765291',
	'SerialNumber'     => '00000030-0000-1000-8000-0026BB765291',
	'FirmwareRevision' => '00000052-0000-1000-8000-0026BB765291',

	# Thermostat
	'CurrentHeatingCoolingState' => '0000000F-0000-1000-8000-0026BB765291',
	'TargetHeatingCoolingState'  => '00000033-0000-1000-8000-0026BB765291',
	'CurrentTemperature'         => '00000011-0000-1000-8000-0026BB765291',
	'TargetTemperature'          => '00000035-0000-1000-8000-0026BB765291',
	'TemperatureDisplayUnits'    => '00000036-0000-1000-8000-0026BB765291',

	# Switch/Outlet
	'On'          => '00000025-0000-1000-8000-0026BB765291',
	'OutletInUse' => '00000026-0000-1000-8000-0026BB765291',

	# Lightbulb
	'Brightness'       => '00000008-0000-1000-8000-0026BB765291',
	'Hue'              => '00000013-0000-1000-8000-0026BB765291',
	'Saturation'       => '0000002F-0000-1000-8000-0026BB765291',
	'ColorTemperature' => '000000CE-0000-1000-8000-0026BB765291',

	# Sensors
	'CurrentRelativeHumidity' => '00000010-0000-1000-8000-0026BB765291',

	# Protocol information
	'Version' => '00000037-0000-1000-8000-0026BB765291',
);

# _uuid_to_short($uuid) - Convert full UUID to short form for JSON
# Returns short hex string for Apple UUIDs, full UUID for custom ones
sub _uuid_to_short ($uuid)
{
	my $base = HAP_BASE_UUID;
	if ( $uuid =~ /^0*([0-9A-Fa-f]+)\Q$base\E$/i ) {
		return uc($1);
	}
	return $uuid;
}

# HAP Characteristic Formats
our %FORMATS = (
	'bool'   => 1,
	'uint8'  => 1,
	'uint16' => 1,
	'uint32' => 1,
	'uint64' => 1,
	'int'    => 1,
	'float'  => 1,
	'string' => 1,
	'tlv8'   => 1,
	'data'   => 1,
);

# HAP Permissions
our %PERMISSIONS = (
	'pr' => 1,    # Paired Read
	'pw' => 1,    # Paired Write
	'ev' => 1,    # Events (notifications)
	'aa' => 1,    # Additional Authorization
	'tw' => 1,    # Timed Write
	'hd' => 1,    # Hidden
	'wr' => 1,    # Write Response
);

sub new ( $class, %args )
{

	my $type = $args{type}        // die "Characteristic type required";
	my $uuid = $CHAR_TYPES{$type} // $type;

	my $self = bless {
		type   => $uuid,
		iid    => $args{iid}    // die('Instance ID required'),
		format => $args{format} // 'string',
		perms  => $args{perms}  // ['pr'],

		# Value (can be scalar ref for mutable values)
		value => $args{value},

		# Optional metadata
		unit   => $args{unit},
		min    => $args{min},
		max    => $args{max},
		step   => $args{step},
		maxLen => $args{maxLen},

		# Callbacks
		on_get => $args{on_get},
		on_set => $args{on_set},

		# Event notifications
		event_enabled => 0,
	}, $class;

	return $self;
}

sub get_value ($self)
{

	# If there's a custom getter, use it
	if ( $self->{on_get} ) {
		return $self->{on_get}->();
	}

	# If value is a reference, dereference it
	if ( ref $self->{value} eq 'SCALAR' ) {
		return ${ $self->{value} };
	}

	return $self->{value};
}

sub set_value ( $self, $value )
{
	$OpenHAP::logger->debug( 'Setting characteristic IID=%d to value: %s',
		$self->{iid}, defined $value ? $value : 'undef' );

	# If there's a custom setter, use it
	if ( $self->{on_set} ) {
		$self->{on_set}->($value);
	}

	# Update value
	if ( ref $self->{value} eq 'SCALAR' ) {
		${ $self->{value} } = $value;
	}
	else {
		$self->{value} = $value;
	}
}

sub enable_events ( $self, $enabled )
{
	$OpenHAP::logger->debug(
		'Events %s for characteristic IID=%d',
		$enabled ? 'enabled' : 'disabled',
		$self->{iid} );
	$self->{event_enabled} = $enabled;
}

sub events_enabled ($self)
{
	return $self->{event_enabled};
}

sub to_json ( $self, $include_value = 1 )
{

	my $json = {
		type   => _uuid_to_short( $self->{type} ),
		iid    => $self->{iid},
		format => $self->{format},
		perms  => $self->{perms},
	};

	# Add optional metadata
	$json->{unit}     = $self->{unit}   if defined $self->{unit};
	$json->{minValue} = $self->{min}    if defined $self->{min};
	$json->{maxValue} = $self->{max}    if defined $self->{max};
	$json->{minStep}  = $self->{step}   if defined $self->{step};
	$json->{maxLen}   = $self->{maxLen} if defined $self->{maxLen};

	# Add value if requested and readable
	if ( $include_value && grep { $_ eq 'pr' } @{ $self->{perms} } ) {
		$json->{value} = $self->json_value;
	}

	return $json;
}

# json_value() - Current value converted to its JSON type per the
# characteristic format (HAP-HTTP.md §15.1)
sub json_value ($self)
{
	my $value = $self->get_value();

	if ( $self->{format} eq 'bool' ) {
		return $value ? \1 : \0;
	}
	if ( $self->{format} =~ /^(uint|int)/ ) {
		return $value + 0;
	}
	if ( $self->{format} eq 'float' ) {
		return $value + 0.0;
	}
	return $value;
}

1;
