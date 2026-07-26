use v5.36;

package OpenHAP::Bridge;

require OpenHAP::Accessory;
our @ISA = qw(OpenHAP::Accessory);

sub new ( $class, %args )
{
	my $self = $class->SUPER::new(
		aid               => 1,    # Bridge is always accessory 1
		name              => $args{name}         // 'OpenHAP Bridge',
		manufacturer      => $args{manufacturer} // 'OpenBSD',
		model             => $args{model}        // 'OpenHAP',
		serial            => $args{serial}       // 'BRIDGE-001',
		firmware_revision => $args{firmware_revision} // '1.0.0',
	);

	$self->{bridged_accessories} = [];

	# ProtocolInformation is required on the bridge accessory object
	# itself; bridged accessories do not carry it (HAP-Services.md §3)
	$self->_add_protocol_info_service;

	return $self;
}

sub _add_protocol_info_service ($self)
{
	require OpenHAP::Service;
	require OpenHAP::Characteristic;

	my $protocol = OpenHAP::Service->new(
		type => 'ProtocolInformation',
		iid  => 8,
	);

	$protocol->add_characteristic(
		OpenHAP::Characteristic->new(
			type   => 'Version',
			iid    => 9,
			format => 'string',
			perms  => ['pr'],
			value  => '1.1.0',
		) );

	$self->add_service($protocol);
}

sub add_bridged_accessory ( $self, $accessory )
{
	$OpenHAP::logger->debug( 'Adding bridged accessory: AID=%d, name=%s',
		$accessory->{aid}, $accessory->{name} );
	push @{ $self->{bridged_accessories} }, $accessory;

	# Forward event callbacks, preserving the device aid
	$accessory->add_event_callback(
		sub ( $aid, $iid ) {
			for my $callback ( @{ $self->{event_callbacks} } ) {
				$callback->( $aid, $iid );
			}
		} );
}

sub get_bridged_accessories ($self)
{
	return @{ $self->{bridged_accessories} };
}

sub get_all_accessories ($self)
{
	return ( $self, @{ $self->{bridged_accessories} } );
}

sub get_accessory ( $self, $aid )
{
	return $self if $self->{aid} == $aid;

	for my $acc ( @{ $self->{bridged_accessories} } ) {
		return $acc if $acc->{aid} == $aid;
	}

	return;
}

sub to_json ($self)
{
	my @accessories;

	# Add bridge itself
	push @accessories, $self->SUPER::to_json();

	# Add bridged accessories
	for my $acc ( @{ $self->{bridged_accessories} } ) {
		push @accessories, $acc->to_json;
	}

	return { accessories => \@accessories };
}

1;
