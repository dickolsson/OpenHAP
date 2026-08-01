use v5.36;

package OpenHAP::HTTP;

# A simple HTTP/1.1 parser for the HAP protocol
# HAP uses a variant of HTTP/1.1 with some differences

sub parse ($data)
{
	my $request = {
		method  => '',
		path    => '',
		version => '',
		headers => {},
		body    => '',
	};

	# Split the headers and the body
	my ( $headers_part, $body ) = split( /\r?\n\r?\n/, $data, 2 );
	$request->{body} = $body // '';

	# Parse the request line and headers
	my @lines = split( /\r?\n/, $headers_part );

	if ( @lines > 0 ) {

		# Parse the request line (GET /path HTTP/1.1)
		my $request_line = shift @lines;
		if ( $request_line =~ m{^(\S+)\s+(\S+)\s+HTTP/(\S+)$} ) {
			$request->{method}  = $1;
			$request->{path}    = $2;
			$request->{version} = $3;
		}
	}

	# Parse the headers
	for my $line (@lines) {
		if ( $line =~ /^([^:]+):\s*(.*)$/ ) {
			my ( $name, $value ) = ( $1, $2 );
			$request->{headers}{ lc($name) } = $value;
		}
	}

	return $request;
}

sub build_response (%args)
{
	my $status      = $args{status}      // 200;
	my $status_text = $args{status_text} // _status_text($status);
	my $headers     = $args{headers}     // {};
	my $body        = $args{body}        // '';

	my $response = "HTTP/1.1 $status $status_text\r\n";

	# Add Content-Length if the headers do not include it
	unless ( exists $headers->{'Content-Length'} ) {
		$headers->{'Content-Length'} = length($body);
	}

	# Add Connection: keep-alive for HAP persistent connections
	unless ( exists $headers->{'Connection'} ) {
		$headers->{'Connection'} = 'keep-alive';
	}

	# Add the headers
	for my $name ( keys %$headers ) {
		$response .= "$name: $headers->{$name}\r\n";
	}

	$response .= "\r\n";
	$response .= $body;

	return $response;
}

sub _status_text ($code)
{
	my %codes = (
		200 => 'OK',
		204 => 'No Content',
		207 => 'Multi-Status',
		400 => 'Bad Request',
		401 => 'Unauthorized',
		404 => 'Not Found',
		470 => 'Connection Authorization Required',
		500 => 'Internal Server Error',
	);

	return $codes{$code} // 'Unknown';
}

1;
