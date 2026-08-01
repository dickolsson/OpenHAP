use v5.36;

package OpenHAP::Accessory;

sub new ( $class, %args )
{
	my $self = bless {
		aid               => $args{aid},
		name              => $args{name}         // 'Accessory',
		manufacturer      => $args{manufacturer} // 'OpenHAP',
		model             => $args{model}        // 'HAP Accessory',
		serial            => $args{serial}       // 'ACC-001',
		firmware_revision => $args{firmware_revision} // '1.0.0',
		services          => [],
		event_callbacks   => [],
	}, $class;

	# Add the required Accessory Information service
	$self->_add_accessory_info_service();

	return $self;
}

sub _add_accessory_info_service ($self)
{

	require OpenHAP::Service;
	require OpenHAP::Characteristic;

	my $info = OpenHAP::Service->new(
		type => 'AccessoryInformation',
		iid  => 1,
	);

	$info->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'Identify',
			iid    => 2,
			format => 'bool',
			perms  => ['pw'],
			on_set => sub { $self->identify() },
		) );

	$info->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'Manufacturer',
			iid    => 3,
			format => 'string',
			perms  => ['pr'],
			value  => $self->{manufacturer},
		) );

	$info->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'Model',
			iid    => 4,
			format => 'string',
			perms  => ['pr'],
			value  => $self->{model},
		) );

	$info->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'Name',
			iid    => 5,
			format => 'string',
			perms  => ['pr'],
			value  => $self->{name},
		) );

	$info->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'SerialNumber',
			iid    => 6,
			format => 'string',
			perms  => ['pr'],
			value  => $self->{serial},
		) );

	$info->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'FirmwareRevision',
			iid    => 7,
			format => 'string',
			perms  => ['pr'],
			value  => $self->{firmware_revision},
		) );

	push @{ $self->{services} }, $info;
}

sub add_service ( $self, $service )
{
	push @{ $self->{services} }, $service;
}

sub get_services ($self)
{
	return @{ $self->{services} };
}

sub get_service ( $self, $type )
{
	# Look up the full UUID when the caller gives a short name
	require OpenHAP::Service;
	my $target_uuid = $OpenHAP::Service::SERVICE_TYPES{$type} // $type;

	for my $service ( @{ $self->{services} } ) {
		return $service if $service->{type} eq $target_uuid;
	}

	return;
}

sub get_characteristic ( $self, $iid )
{
	for my $service ( @{ $self->{services} } ) {
		my $char = $service->get_characteristic($iid);
		return $char if $char;
	}

	return;
}

sub to_json ($self)
{
	my @services;
	for my $service ( @{ $self->{services} } ) {
		push @services, $service->to_json();
	}

	return {
		aid      => $self->{aid},
		services => \@services,
	};
}

sub identify ($self)
{
	# Subclasses override this method to add the identify function.
	# For example, blink an LED or sound a beep.
}

sub add_event_callback ( $self, $callback )
{
	push @{ $self->{event_callbacks} }, $callback;
}

sub notify_change ( $self, $iid )
{
	# Tell all registered callbacks about the characteristic change
	for my $callback ( @{ $self->{event_callbacks} } ) {
		$callback->( $self->{aid}, $iid );
	}
}

1;
