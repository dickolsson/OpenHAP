use v5.36;

package OpenHAP::Storage;

use Carp  qw(croak);
use Fcntl qw(:flock);
use FuguLib::File;
use FuguLib::Log;
use FuguLib::Store;

# OpenHAP::Storage - what a paired accessory keeps on disk.
#
# The counters ride on FuguLib::Store, and every file goes through
# FuguLib::File, which sets the mode at the open. This module keeps
# what is HAP: the long-term key files, the pairings format, and the
# rule that every pairing change bumps the configuration number.
#
# The on-disk layout does not change with the module underneath it. A
# paired installation keeps working:
#
#	<db_path>/accessory_ltsk	mode 0600
#	<db_path>/accessory_ltpk	mode 0644
#	<db_path>/pairings.db		mode 0600
#	<db_path>/state.json		mode 0600, the counters

sub new ( $class, %args )
{
	my $db_path = $args{db_path} // '/var/db/openhapd';

	FuguLib::File->ensure_dir( $db_path, mode => 0700 );

	my $self = bless {
		db_path             => $db_path,
		pairings_file       => "$db_path/pairings.db",
		accessory_ltsk_file => "$db_path/accessory_ltsk",
		accessory_ltpk_file => "$db_path/accessory_ltpk",
		store               => FuguLib::Store->new(
			path => "$db_path/state.json",
			mode => 0600,
		),
	}, $class;
	$self->{store}->load;
	$self->_migrate;

	return $self;
}

# $self->_migrate:
#	Read the counters that an older installation kept in one file
#	each, and fold them into the state store. A daemon that was
#	paired before this change must keep its configuration number:
#	a controller that sees c# go backwards drops the accessory.
sub _migrate ($self)
{
	my %legacy = (
		config_number => 'config_number',
		config_digest => 'config_digest',
		auth_attempts => 'auth_attempts',
	);

	my $migrated = 0;
	for my $key ( sort keys %legacy ) {
		my $path = "$self->{db_path}/$legacy{$key}";
		next unless -f $path;
		next if $self->{store}->exists($key);

		my $value = FuguLib::File->read($path);
		next unless defined $value;
		chomp $value;

		$self->{store}->data->{$key} = $value;
		$migrated++;
	}
	$self->{store}->save if $migrated;

	return $self;
}

sub load_accessory_keys ($self)
{
	if (       -f $self->{accessory_ltsk_file}
		&& -f $self->{accessory_ltpk_file} )
	{
		FuguLib::Log->default->debug(
			'Loading accessory keys from storage');
		my $ltsk = FuguLib::File->read( $self->{accessory_ltsk_file} );
		my $ltpk = FuguLib::File->read( $self->{accessory_ltpk_file} );
		return ( $ltsk, $ltpk );
	}

	FuguLib::Log->default->debug('No existing accessory keys found');
	return ();
}

sub save_accessory_keys ( $self, $ltsk, $ltpk )
{
	FuguLib::Log->default->debug(
		'Generating and saving new accessory keys');

	# The secret key gets its mode at the open, before it holds a
	# byte. A chmod after the write leaves a window in which the
	# identity of the accessory is world-readable.
	FuguLib::File->write( $self->{accessory_ltsk_file},
		$ltsk, mode => 0600 )
	    or croak 'Cannot store the accessory secret key';
	FuguLib::File->write( $self->{accessory_ltpk_file},
		$ltpk, mode => 0644 )
	    or croak 'Cannot store the accessory public key';

	return;
}

sub load_pairings ($self)
{
	return {} unless -f $self->{pairings_file};

	FuguLib::Log->default->debug('Loading pairings from storage');
	my %pairings;
	open my $fh, '<', $self->{pairings_file} or do {
		FuguLib::Log->default->error(
			'Cannot open pairings file %s: %s',
			$self->{pairings_file}, $! );
		die "Cannot open pairings file: $!";
	};
	flock( $fh, LOCK_SH ) or do {
		FuguLib::Log->default->error(
			'Cannot lock pairings file %s: %s',
			$self->{pairings_file}, $! );
		die "Cannot lock pairings file: $!";
	};

	while ( my $line = <$fh> ) {
		chomp $line;
		next if $line =~ /^#/ || $line =~ /^\s*$/;

		# Format: controller_id:ltpk_hex:permissions
		if ( $line =~ /^([^:]+):([^:]+):([01])$/ ) {
			my ( $id, $ltpk_hex, $perms ) = ( $1, $2, $3 );
			$pairings{$id} = {
				ltpk        => pack( 'H*', $ltpk_hex ),
				permissions => $perms,
			};
		}
	}

	flock( $fh, LOCK_UN );
	close $fh;

	return \%pairings;
}

sub save_pairing ( $self, $controller_id, $ltpk, $permissions = 1 )
{
	FuguLib::Log->default->debug( 'Saving pairing for controller: %s',
		$controller_id );
	my $pairings = $self->load_pairings;
	$pairings->{$controller_id} = {
		ltpk        => $ltpk,
		permissions => $permissions,
	};

	$self->_save_pairings($pairings);
	$self->increment_config_number();

	return;
}

sub remove_pairing ( $self, $controller_id )
{
	FuguLib::Log->default->debug( 'Removing pairing for controller: %s',
		$controller_id );
	my $pairings = $self->load_pairings;
	delete $pairings->{$controller_id};

	$self->_save_pairings($pairings);
	$self->increment_config_number();

	return;
}

# remove_all_pairings() - Remove all pairings. This is a factory
# reset. The daemon calls this method when it removes the last
# admin pairing (HAP-Pairing.md §7.2).
sub remove_all_pairings ($self)
{
	FuguLib::Log->default->debug('Removing all pairings');
	$self->_save_pairings( {} );
	$self->increment_config_number();

	return;
}

sub _save_pairings ( $self, $pairings )
{
	my $text =
	      "# OpenHAP Pairings Database\n"
	    . "# Format: controller_id:ltpk_hex:permissions\n"
	    . "# Permissions: 1=admin, 0=regular\n\n";

	for my $id ( sort keys %$pairings ) {
		my $ltpk_hex = unpack( 'H*', $pairings->{$id}{ltpk} );
		my $perms    = $pairings->{$id}{permissions};
		$text .= "$id:$ltpk_hex:$perms\n";
	}

	# The file is 0600 from its first byte. A pairing record names
	# every controller that may reach the accessory.
	FuguLib::File->write( $self->{pairings_file}, $text, mode => 0600 )
	    or croak 'Cannot write the pairings file';

	return;
}

# The configuration number tells a controller that the accessory
# database changed [HAP-Accessories]. It only ever goes up: a
# controller that sees it go backwards drops the accessory and pairs
# again. Thus the value starts at 1, not at 0.
sub get_config_number ($self)
{
	my $number = $self->{store}->get('config_number');
	return 1 unless defined $number && $number =~ /^\d+$/;

	return $number;
}

sub increment_config_number ($self)
{
	my $number = $self->get_config_number + 1;
	$self->{store}->set( config_number => $number );

	return $number;
}

sub get_config_digest ($self)
{
	return $self->{store}->get('config_digest');
}

sub save_config_digest ( $self, $digest )
{
	$self->{store}->set( config_digest => $digest );

	return;
}

sub get_auth_attempts ($self)
{
	my $count = $self->{store}->get('auth_attempts');
	return 0 unless defined $count && $count =~ /^\d+$/;

	return $count;
}

sub set_auth_attempts ( $self, $count )
{
	$self->{store}->set( auth_attempts => $count );

	return;
}

1;
