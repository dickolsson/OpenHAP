use v5.36;

package Protocol::HAP::Service;

use Protocol::HAP;

# HAP Base UUID suffix for Apple-defined services
use constant HAP_BASE_UUID => '-0000-1000-8000-0026BB765291';

# HAP Service Type UUIDs
our %SERVICE_TYPES = (
	'AccessoryInformation' => '0000003E-0000-1000-8000-0026BB765291',
	'ProtocolInformation'  => '000000A2-0000-1000-8000-0026BB765291',
	'Thermostat'           => '0000004A-0000-1000-8000-0026BB765291',
	'Switch'               => '00000049-0000-1000-8000-0026BB765291',
	'TemperatureSensor'    => '0000008A-0000-1000-8000-0026BB765291',
	'HumiditySensor'       => '00000082-0000-1000-8000-0026BB765291',
	'Outlet'               => '00000047-0000-1000-8000-0026BB765291',
	'Lightbulb'            => '00000043-0000-1000-8000-0026BB765291',
);

# _uuid_to_short($uuid) - Convert the full UUID to the short form
# for JSON. The function returns a short hex string for Apple
# UUIDs. It returns the full UUID for custom UUIDs.
sub _uuid_to_short ($uuid)
{
	my $base = HAP_BASE_UUID;
	if ( $uuid =~ /^0*([0-9A-Fa-f]+)\Q$base\E$/i ) {
		return uc($1);
	}
	return $uuid;
}

sub new ( $class, %args )
{

	my $type = $args{type}           // die "Service type required";
	my $uuid = $SERVICE_TYPES{$type} // $type;

	my $self = bless {
		type            => $uuid,
		iid             => $args{iid},
		logger          => $args{logger} // Protocol::HAP->null_logger,
		characteristics => [],
		hidden          => $args{hidden}  // 0,
		primary         => $args{primary} // 0,
	}, $class;

	return $self;
}

sub add_characteristic ( $self, $characteristic )
{
	push @{ $self->{characteristics} }, $characteristic;
}

sub get_characteristic ( $self, $iid )
{

	for my $char ( @{ $self->{characteristics} } ) {
		return $char if $char->{iid} == $iid;
	}

	return;
}

sub get_characteristic_by_type ( $self, $type )
{
	require Protocol::HAP::Characteristic;
	my $target_uuid = $Protocol::HAP::Characteristic::CHAR_TYPES{$type}
	    // $type;

	for my $char ( @{ $self->{characteristics} } ) {
		return $char if $char->{type} eq $target_uuid;
	}

	return;
}

sub get_characteristics ($self)
{
	return @{ $self->{characteristics} };
}

sub to_json ($self)
{

	my @chars;
	for my $char ( @{ $self->{characteristics} } ) {
		push @chars, $char->to_json();
	}

	my $json = {
		type            => _uuid_to_short( $self->{type} ),
		iid             => $self->{iid},
		characteristics => \@chars,
	};

	$json->{hidden}  = \1 if $self->{hidden};
	$json->{primary} = \1 if $self->{primary};

	return $json;
}

1;
