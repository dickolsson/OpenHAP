use v5.36;

package OpenHAP::Storage;
use Carp qw(croak);

use File::Path qw(make_path);
use Fcntl      qw(:flock);

sub new ( $class, %args )
{
	my $db_path = $args{db_path} // '/var/db/openhapd';

	# Create the directory if it does not exist
	make_path($db_path) unless -d $db_path;

	my $self = bless {
		db_path             => $db_path,
		pairings_file       => "$db_path/pairings.db",
		accessory_ltsk_file => "$db_path/accessory_ltsk",
		accessory_ltpk_file => "$db_path/accessory_ltpk",
		config_number       => 1,
	}, $class;

	return $self;
}

sub load_accessory_keys ($self)
{
	if (       -f $self->{accessory_ltsk_file}
		&& -f $self->{accessory_ltpk_file} )
	{
		$OpenHAP::logger->debug('Loading accessory keys from storage');
		my $ltsk = $self->_read_file( $self->{accessory_ltsk_file} );
		my $ltpk = $self->_read_file( $self->{accessory_ltpk_file} );
		return ( $ltsk, $ltpk );
	}

	$OpenHAP::logger->debug('No existing accessory keys found');
	return ();
}

sub save_accessory_keys ( $self, $ltsk, $ltpk )
{
	$OpenHAP::logger->debug('Generating and saving new accessory keys');
	$self->_write_file( $self->{accessory_ltsk_file}, $ltsk, 0600 );
	$self->_write_file( $self->{accessory_ltpk_file}, $ltpk, 0644 );

	return;
}

sub load_pairings ($self)
{
	return {} unless -f $self->{pairings_file};

	$OpenHAP::logger->debug('Loading pairings from storage');
	my %pairings;
	open my $fh, '<', $self->{pairings_file} or do {
		$OpenHAP::logger->error( 'Cannot open pairings file %s: %s',
			$self->{pairings_file}, $! );
		die "Cannot open pairings file: $!";
	};
	flock( $fh, LOCK_SH ) or do {
		$OpenHAP::logger->error( 'Cannot lock pairings file %s: %s',
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
	$OpenHAP::logger->debug( 'Saving pairing for controller: %s',
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
	$OpenHAP::logger->debug( 'Removing pairing for controller: %s',
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
	$OpenHAP::logger->debug('Removing all pairings');
	$self->_save_pairings( {} );
	$self->increment_config_number();

	return;
}

sub _save_pairings ( $self, $pairings )
{
	my $old_umask = umask(0077);
	open my $fh, '>', $self->{pairings_file} or do {
		umask($old_umask);
		$OpenHAP::logger->error(
			'Cannot open pairings file %s for writing: %s',
			$self->{pairings_file}, $! );
		croak "Cannot open pairings file: $!";
	};
	umask($old_umask);
	flock( $fh, LOCK_EX ) or do {
		$OpenHAP::logger->error( 'Cannot lock pairings file %s: %s',
			$self->{pairings_file}, $! );
		croak "Cannot lock pairings file: $!";
	};

	print $fh "# OpenHAP Pairings Database\n";
	print $fh "# Format: controller_id:ltpk_hex:permissions\n";
	print $fh "# Permissions: 1=admin, 0=regular\n\n";

	for my $id ( sort keys %$pairings ) {
		my $ltpk_hex = unpack( 'H*', $pairings->{$id}{ltpk} );
		my $perms    = $pairings->{$id}{permissions};
		print $fh "$id:$ltpk_hex:$perms\n";
	}

	flock( $fh, LOCK_UN );
	close $fh;

	chmod 0600, $self->{pairings_file};

	return;
}

sub get_config_number ($self)
{
	my $config_file = "$self->{db_path}/config_number";
	if ( -f $config_file ) {
		my $num = $self->_read_file($config_file);
		chomp $num;
		return $num if $num =~ /^\d+$/;
	}

	return 1;
}

sub increment_config_number ($self)
{
	my $num         = $self->get_config_number + 1;
	my $config_file = "$self->{db_path}/config_number";
	$self->_write_file( $config_file, "$num\n", 0644 );

	return $num;
}

sub get_config_digest ($self)
{
	my $digest_file = "$self->{db_path}/config_digest";
	if ( -f $digest_file ) {
		my $digest = $self->_read_file($digest_file);
		chomp $digest;
		return $digest;
	}

	return;
}

sub save_config_digest ( $self, $digest )
{
	my $digest_file = "$self->{db_path}/config_digest";
	$self->_write_file( $digest_file, "$digest\n", 0600 );

	return;
}

sub get_auth_attempts ($self)
{
	my $attempts_file = "$self->{db_path}/auth_attempts";
	if ( -f $attempts_file ) {
		my $num = $self->_read_file($attempts_file);
		chomp $num;
		return $num if $num =~ /^\d+$/;
	}

	return 0;
}

sub set_auth_attempts ( $self, $count )
{
	my $attempts_file = "$self->{db_path}/auth_attempts";
	$self->_write_file( $attempts_file, "$count\n", 0600 );

	return;
}

sub _read_file ( $self, $path )
{
	open my $fh, '<', $path or croak "Cannot open $path: $!";
	local $/ = undef;
	my $content = <$fh>;
	close $fh;

	return $content;
}

sub _write_file ( $self, $path, $content, $mode = undef )
{
	open my $fh, '>', $path or croak "Cannot open $path: $!";
	print $fh $content;
	close $fh;

	chmod $mode, $path if defined $mode;

	return;
}

1;
