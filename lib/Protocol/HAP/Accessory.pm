use v5.36;

package Protocol::HAP::Accessory;

use Protocol::HAP;

sub new ( $class, %args )
{
	my $self = bless {
		aid               => $args{aid},
		name              => $args{name}         // 'Accessory',
		manufacturer      => $args{manufacturer} // 'OpenHAP',
		model             => $args{model}        // 'HAP Accessory',
		serial            => $args{serial}       // 'ACC-001',
		firmware_revision => $args{firmware_revision} // '1.0.0',
		logger          => $args{logger} // Protocol::HAP->null_logger,
		services        => [],
		event_callbacks => [],
	}, $class;

	# Add the required Accessory Information service
	$self->_add_accessory_info_service();

	return $self;
}

sub _add_accessory_info_service ($self)
{

	require Protocol::HAP::Service;
	require Protocol::HAP::Characteristic;

	my $info = Protocol::HAP::Service->new(
		type   => 'AccessoryInformation',
		iid    => 1,
		logger => $self->{logger},
	);

	$info->add_characteristic(
		Protocol::HAP::Characteristic->new(
			type   => 'Identify',
			iid    => 2,
			format => 'bool',
			perms  => ['pw'],
			logger => $self->{logger},
			on_set => sub { $self->identify() },
		) );

	$info->add_characteristic(
		Protocol::HAP::Characteristic->new(
			type   => 'Manufacturer',
			iid    => 3,
			format => 'string',
			perms  => ['pr'],
			logger => $self->{logger},
			value  => $self->{manufacturer},
		) );

	$info->add_characteristic(
		Protocol::HAP::Characteristic->new(
			type   => 'Model',
			iid    => 4,
			format => 'string',
			perms  => ['pr'],
			logger => $self->{logger},
			value  => $self->{model},
		) );

	$info->add_characteristic(
		Protocol::HAP::Characteristic->new(
			type   => 'Name',
			iid    => 5,
			format => 'string',
			perms  => ['pr'],
			logger => $self->{logger},
			value  => $self->{name},
		) );

	$info->add_characteristic(
		Protocol::HAP::Characteristic->new(
			type   => 'SerialNumber',
			iid    => 6,
			format => 'string',
			perms  => ['pr'],
			logger => $self->{logger},
			value  => $self->{serial},
		) );

	$info->add_characteristic(
		Protocol::HAP::Characteristic->new(
			type   => 'FirmwareRevision',
			iid    => 7,
			format => 'string',
			perms  => ['pr'],
			logger => $self->{logger},
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
	require Protocol::HAP::Service;
	my $target_uuid = $Protocol::HAP::Service::SERVICE_TYPES{$type}
	    // $type;

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
