use v5.36;

package OpenHAP::Config;
use Carp qw(croak);

sub new ( $class, %args )
{
	my $self = bless {
		file   => $args{file} // '/etc/openhapd.conf',
		config => {},
	}, $class;

	return $self;
}

sub load ($self)
{
	my $file = $self->{file};
	return unless -f $file;

	$OpenHAP::logger->debug( 'Loading configuration from %s', $file )
	    if $OpenHAP::logger;
	open my $fh, '<', $file or croak "Cannot open config file $file: $!";
	my @lines = <$fh>;
	close $fh;

	my $current_device;

	for my $line (@lines) {
		chomp $line;

		# Skip comments and empty lines
		next if $line =~ m/\A \s* \# /xms || $line =~ m/\A \s* \z/xms;

		# Device block start
		if ( $line =~
m/\A \s* device \s+ (\w+) \s+ (\w+) \s+ (\w+) \s* [{] /xms
		    )
		{
			$current_device = {
				type    => $1,
				subtype => $2,
				id      => $3,
			};
		}

		# Device block end
		elsif ( $line =~ m/\A \s* [}] /xms && $current_device ) {
			$OpenHAP::logger->debug(
				'Loaded device: %s %s %s',
				$current_device->{type},
				$current_device->{subtype},
				$current_device->{id} ) if $OpenHAP::logger;
			push @{ $self->{config}{devices} }, $current_device;
			$current_device = undef;
		}

		# Device properties. This check must come BEFORE the
		# top-level config check.
		elsif (    $current_device
			&& $line =~ m/\A \s* (\w+) \s* = \s* (.+?) \s* \z/xms )
		{
			my ( $key, $value ) = ( $1, $2 );
			$value =~ s/\A "//xms;
			$value =~ s/" \z//xms;
			$current_device->{$key} = $value;
		}

		# Simple key = value (top-level config)
		elsif ( $line =~ m/\A \s* (\w+) \s* = \s* (.+?) \s* \z/xms ) {
			my ( $key, $value ) = ( $1, $2 );

			# Remove the quotes around the value if they
			# are present
			$value =~ s/\A "//xms;
			$value =~ s/" \z//xms;
			$self->{config}{$key} = $value;
		}
	}

	return $self->{config};
}

sub get ( $self, $key, $default = undef )
{
	return $self->{config}{$key} // $default;
}

sub get_devices ($self)
{
	return @{ $self->{config}{devices} // [] };
}

1;
