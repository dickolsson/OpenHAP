# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2024 Dick Olsson <hi@senzilla.io>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use v5.36;

package FuguVM::Proxy;

use POSIX qw(setsid);
use IO::Socket::INET;
use Socket      qw(IPPROTO_TCP TCP_NODELAY SOL_SOCKET SO_SNDBUF);
use Time::HiRes qw(usleep time);

use FuguLib::Log;
use FuguLib::Process;
use FuguVM::Proxy::Cache;
use FuguVM::Proxy::MetaCache;

# $class->run_child($port, $cache_dir):
#	The entry point for the spawned child process. The method sets
#	up the cache and runs the proxy server.
sub run_child ( $class, $port, $cache_dir )
{
	my $log       = FuguLib::Log->new( mode => 'stderr', level => 'debug' );
	my $cache     = FuguVM::Proxy::Cache->new($cache_dir);
	my $metacache = FuguVM::Proxy::MetaCache->new;
	my $self      = bless {
		cache     => $cache,
		metacache => $metacache,
		log       => $log,
	}, $class;

	$log->info( 'Proxy starting on port %d', $port );
	$log->info( 'Cache directory: %s',       $cache_dir );

	# Warm the metadata cache before the proxy serves requests
	my $start_time = time;
	$metacache->warm($cache);
	my $warm_time = time - $start_time;
	my $entries   = scalar keys %{ $metacache->{entries} };
	$log->info( 'Metadata cache warmed: %d entries in %.3f seconds',
		$entries, $warm_time );

	$self->_run_proxy($port);
}

use constant {
	PORT_RANGE_START => 8080,
	PORT_RANGE_END   => 8180,
	CONNECT_TIMEOUT  => 30,
	HOST_GATEWAY     => '10.0.2.2',    # QEMU user-mode networking gateway
};

sub new ( $class, $state, $cache_dir )
{
	my $self = bless {
		state     => $state,
		cache_dir => $cache_dir,
		cache     => FuguVM::Proxy::Cache->new($cache_dir),
		metacache => FuguVM::Proxy::MetaCache->new,
	}, $class;

	return $self;
}

# $self->start:
#	Start the proxy server. The method returns the port number on
#	success and undef on failure.
sub start ($self)
{
	# Check if the proxy already runs
	if ( $self->is_running ) {
		return $self->{state}->get_proxy_port;
	}

	my $port = $self->_find_available_port;
	if ( !defined $port ) {
		warn "No available ports in range "
		    . PORT_RANGE_START . "-"
		    . PORT_RANGE_END . "\n";
		return;
	}

	# Spawn the proxy with FuguLib::Process
	my $log       = $self->{state}->vm_state_dir . "/proxy.log";
	my $cache_dir = $self->{cache_dir};
	my $result    = FuguLib::Process->spawn_perl(
		code => 'use FuguVM::Proxy; FuguVM::Proxy->run_child(@ARGV)',
		args => [ $port, $cache_dir ],
		daemonize   => 1,
		stdout      => $log,
		stderr      => $log,
		check_alive => 1,
		on_success  => sub ($pid) {

			# Record the state in the callback
			$self->{state}->set_proxy_pid($pid);
			$self->{state}->set_proxy_port($port);
		},
		on_error => sub ($err) {
			warn "Proxy failed to start: $err\n";
		},
	);

	return unless $result->{success};

	# Wait until the proxy is ready
	if ( !$self->wait_ready(CONNECT_TIMEOUT) ) {
		warn "Proxy failed to become ready\n";
		$self->stop;
		return;
	}

	return $port;
}

# $self->stop:
#	Stop the proxy server. Send SIGTERM first, then SIGKILL if the
#	process stays.
sub stop ($self)
{
	my $pid = $self->{state}->get_proxy_pid;
	return 1 if !defined $pid;

	# Send SIGTERM
	if ( kill( 0, $pid ) ) {
		kill( 'TERM', $pid );

		# Wait until the process exits
		my $waited = 0;
		while ( $waited < 5 && kill( 0, $pid ) ) {
			sleep 1;
			$waited++;
		}

		# Send SIGKILL if the process does not exit
		if ( kill( 0, $pid ) ) {
			kill( 'KILL', $pid );
			sleep 1;
		}
	}

	$self->{state}->clear_proxy_pid;
	$self->{state}->clear_proxy_port;

	return 1;
}

# $self->is_running:
#	Check if the proxy runs
sub is_running ($self)
{
	return $self->{state}->is_proxy_running;
}

# $self->port:
#	Get the current proxy port
sub port ($self)
{
	return $self->{state}->get_proxy_port;
}

# $self->guest_url:
#	Get the proxy URL for use from the VM guest. The URL goes
#	through the QEMU gateway.
sub guest_url ($self)
{
	my $port = $self->port;
	return if !defined $port;

	return "http://" . HOST_GATEWAY . ":$port";
}

# $self->host_url:
#	Get the proxy URL for use from the host. The URL points to
#	localhost.
sub host_url ($self)
{
	my $port = $self->port;
	return if !defined $port;

	return "http://127.0.0.1:$port";
}

# $self->wait_ready($timeout):
#	Wait until the proxy accepts connections
sub wait_ready ( $self, $timeout = CONNECT_TIMEOUT )
{
	my $port = $self->{state}->get_proxy_port;
	return 0 if !defined $port;

	my $start = time;
	while ( time - $start < $timeout ) {
		my $sock = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => 1,
		);
		if ($sock) {
			close $sock;
			return 1;
		}
		usleep(500_000);    # 0.5 seconds
	}

	return 0;
}

# $self->cache:
#	Get the cache object
sub cache ($self)
{
	return $self->{cache};
}

sub _find_available_port ($self)
{
	for my $port ( PORT_RANGE_START .. PORT_RANGE_END ) {
		my $sock = IO::Socket::INET->new(
			LocalPort => $port,
			Proto     => 'tcp',
			ReuseAddr => 1,
			Listen    => 1,
		);
		if ($sock) {
			close $sock;
			return $port;
		}
	}

	return;
}

# $self->_run_proxy($port):
#	Run the proxy server. The child process calls this method.
sub _run_proxy ( $self, $port )
{
	require HTTP::Daemon;
	require LWP::UserAgent;
	require HTTP::Response;
	require IO::Select;

	# Ignore SIGPIPE. Clients can disconnect during a transfer.
	local $SIG{PIPE} = 'IGNORE';

	my $daemon = HTTP::Daemon->new(
		LocalAddr => '0.0.0.0',
		LocalPort => $port,
		ReuseAddr => 1,
		Listen    => 20,
	) or die "Cannot create daemon: $!";

	$self->{log}->info( 'Proxy listening on 0.0.0.0:%d', $port );

	# Use the self-pipe trick for reliable signal handling
	pipe( my $sig_read, my $sig_write ) or die "pipe: $!";
	$sig_read->blocking(0);
	$sig_write->blocking(0);

	# Use IO::Select to wait on the daemon and the signal pipe
	my $select = IO::Select->new( $daemon, $sig_read );

	# On SIGTERM, write to the self-pipe. This stops the loop safely.
	my $running = 1;
	local $SIG{TERM} = sub {
		$self->{log}->info('Received SIGTERM, shutting down');
		$running = 0;
		syswrite $sig_write, "x", 1;
	};

	while ($running) {

		# Wait for a client connection or a signal
		my @ready = $select->can_read;
		last if !$running;

		for my $fh (@ready) {

			# Drain the signal pipe after a signal
			if ( $fh == $sig_read ) {
				my $buf;
				sysread $sig_read, $buf, 100;
				next;
			}

			my $client = $daemon->accept;
			next if !$client;

			$self->_handle_client($client);
			$client->close;
		}
	}

	close $sig_read;
	close $sig_write;
	$daemon->close;
}

sub _handle_client ( $self, $client )
{
	while ( my $request = $client->get_request ) {

		# Check if the proxy can stream directly from the cache
		my $method      = $request->method;
		my $url         = $request->uri->as_string;
		my $client_addr = $client->peerhost;

		$self->{log}
		    ->debug( '%s %s from %s', $method, $url, $client_addr );

		if ( ( $method eq 'GET' || $method eq 'HEAD' )
			&& defined( my $meta =
				    $self->{metacache}->lookup($url) ) )
		{
			$self->{log}
			    ->info( 'CACHE HIT (metacache): %s [%d bytes]',
				$url, $meta->{size} );
			my $start = time;
			$self->_serve_cached_streaming( $client, $meta,
				$request );
			my $elapsed = time - $start;
			my $rate =
			    $meta->{size} / $elapsed / 1024 / 1024;    # MB/s
			$self->{log}->info(
				'Streamed %d bytes in %.3f seconds (%.2f MB/s)',
				$meta->{size}, $elapsed, $rate );
		}
		else {
			my $start    = time;
			my $response = $self->_process_request($request);
			my $elapsed  = time - $start;
			$client->send_response($response);
			my $size = length( $response->content // '' );
			my $rate =
			    $size > 0 ? $size / $elapsed / 1024 / 1024 : 0;
			$self->{log}->info(
				'Served %d bytes in %.3f seconds (%.2f MB/s)',
				$size, $elapsed, $rate );
		}
	}
}

sub _process_request ( $self, $request )
{
	require HTTP::Response;
	require LWP::UserAgent;

	my $method = $request->method;
	my $url    = $request->uri->as_string;

	# Cache only GET and HEAD requests
	if ( $method ne 'GET' && $method ne 'HEAD' ) {
		return $self->_forward_request($request);
	}

	# Check the cache first
	my $cached = $self->{cache}->lookup($url);
	if ( defined $cached ) {
		$self->{log}->info( 'CACHE HIT (disk): %s', $url );
		return $self->_serve_cached( $cached, $request );
	}

	# Fetch the response from the upstream server
	$self->{log}->info( 'CACHE MISS: Fetching from upstream: %s', $url );
	my $fetch_start   = time;
	my $response      = $self->_forward_request($request);
	my $fetch_elapsed = time - $fetch_start;
	my $content_size  = length( $response->content // '' );
	my $fetch_rate =
	      $content_size > 0
	    ? $content_size / $fetch_elapsed / 1024 / 1024
	    : 0;
	$self->{log}
	    ->info( 'Fetched %d bytes in %.3f seconds (%.2f MB/s) - Status: %d',
		$content_size, $fetch_elapsed, $fetch_rate, $response->code );

	# Cache the response if it is cacheable
	if (       $response->is_success
		&& $self->{cache}->is_cacheable( $url, $response->code ) )
	{
		$self->{log}->debug( 'Caching response: %s', $url );
		my $path = $self->{cache}->store( $url, $response->content );
		if ( defined $path ) {
			$self->{metacache}->store( $url, $path );
			$self->{log}->info( 'Cached to: %s', $path );
		}
		else {
			$self->{log}->warn( 'Failed to cache: %s', $url );
		}
	}
	elsif ( !$response->is_success ) {
		$self->{log}
		    ->warn( 'Not caching failed response: %s (status %d)',
			$url, $response->code );
	}
	elsif ( !$self->{cache}->is_cacheable( $url, $response->code ) ) {
		$self->{log}->debug( 'URL not cacheable: %s', $url );
	}

	return $response;
}

sub _forward_request ( $self, $request )
{
	require LWP::UserAgent;

	my $ua = LWP::UserAgent->new(
		timeout => 300,
		agent   => 'FuguVM-Proxy/1.0',
	);

	# Clone the request to forward it
	my $url = $request->uri->as_string;
	my $forwarded =
	    HTTP::Request->new( $request->method, $url,
		$request->headers->clone,
	    );

	if ( $request->content ) {
		$forwarded->content( $request->content );
	}

	my $response = $ua->request($forwarded);
	return $response;
}

# Old _serve_cached for non-streaming fallback
sub _serve_cached ( $self, $path, $request )
{
	require HTTP::Response;

	open my $fh, '<', $path or do {
		return HTTP::Response->new( 500, 'Cache read error' );
	};
	binmode $fh;
	local $/;
	my $content = <$fh>;
	close $fh;

	my $response = HTTP::Response->new( 200, 'OK' );
	$response->header( 'Content-Length' => length($content) );
	$response->header( 'X-Cache'        => 'HIT' );

	# Guess the content type from the URL
	my $url = $request->uri->as_string;
	if ( $url =~ /\.tgz$/ ) {
		$response->header( 'Content-Type' => 'application/x-gzip' );
	}
	elsif ( $url =~ /\.img$/ ) {
		$response->header(
			'Content-Type' => 'application/octet-stream' );
	}
	else {
		$response->header(
			'Content-Type' => 'application/octet-stream' );
	}

	# Include the content only for GET requests
	if ( $request->method eq 'GET' ) {
		$response->content($content);
	}

	return $response;
}

# New optimized streaming implementation
sub _serve_cached_streaming ( $self, $socket, $meta, $request )
{
	# Set the socket options for large transfers. Disable Nagle's
	# algorithm to send data immediately.
	setsockopt( $socket, IPPROTO_TCP, TCP_NODELAY, 1 );

	# Increase the send buffer to 1MB to reduce the syscall overhead
	setsockopt( $socket, SOL_SOCKET, SO_SNDBUF, pack( 'I', 1048576 ) );

	$self->{log}->debug('Applied TCP_NODELAY and 1MB send buffer');

	my $method = $request->method;
	my $path   = $meta->{path};
	my $size   = $meta->{size};
	my $etag   = $meta->{etag};

	# Send a 304 response when If-None-Match matches the ETag
	my $if_none_match = $request->header('If-None-Match');
	if ( defined $if_none_match && $if_none_match eq $etag ) {
		$self->{log}->info('Sending 304 Not Modified (ETag match)');
		$self->_send_response_headers( $socket, 304, 'Not Modified',
			{ 'ETag' => $etag, } );
		return;
	}

	# Send the headers
	my $headers = {
		'Content-Type'   => $meta->{content_type},
		'Content-Length' => $size,
		'X-Cache'        => 'HIT',
		'ETag'           => $etag,
	};
	$self->{log}->debug(
		'Sending headers: %d %s, Content-Length: %d, Content-Type: %s',
		200, 'OK', $size, $meta->{content_type} );
	$self->_send_response_headers( $socket, 200, 'OK', $headers );

	# Stream the file body for GET requests
	if ( $method eq 'GET' ) {
		$self->{log}
		    ->debug( 'Starting stream: %s (%d bytes)', $path, $size );
		my $stream_start = time;
		my $bytes_sent =
		    $self->_stream_file_to_socket( $socket, $path, $size );
		my $stream_elapsed = time - $stream_start;
		if ( defined $bytes_sent ) {
			my $rate =
			      $bytes_sent > 0
			    ? $bytes_sent / $stream_elapsed / 1024 / 1024
			    : 0;
			$self->{log}->debug(
'Stream completed: %d bytes in %.3f seconds (%.2f MB/s)',
				$bytes_sent, $stream_elapsed, $rate );
		}
		else {
			$self->{log}->error( 'Stream failed for: %s', $path );
		}
	}
	else {
		$self->{log}->debug('HEAD request, no body sent');
	}
}

# Send the HTTP response headers to the socket
sub _send_response_headers ( $self, $socket, $code, $message, $headers )
{
	my $response = "HTTP/1.1 $code $message\r\n";
	for my $name ( keys %$headers ) {
		$response .= "$name: $headers->{$name}\r\n";
	}
	$response .= "\r\n";

	# Use syswrite in a loop to make sure that all bytes go out
	my $len    = length $response;
	my $offset = 0;
	while ( $offset < $len ) {
		my $written =
		    syswrite( $socket, $response, $len - $offset, $offset );
		return unless defined $written;
		$offset += $written;
	}
}

# Stream the file to the socket with large 256KB buffers
sub _stream_file_to_socket ( $self, $socket, $path, $size )
{
	open my $fh, '<', $path or do {
		$self->{log}->error( 'Cannot open file for streaming: %s: %s',
			$path, $! );
		return;
	};
	binmode $fh;

	# Use 256KB chunks to get the best throughput
	use constant CHUNK_SIZE => 262144;    # 256KB

	my $bytes_sent = 0;
	my $remaining  = $size;
	my $chunks     = 0;
	while ( $remaining > 0 ) {
		my $to_read = $remaining < CHUNK_SIZE ? $remaining : CHUNK_SIZE;
		my $n       = sysread( $fh, my $buffer, $to_read );
		if ( !$n ) {
			$self->{log}->error( 'Read error after %d bytes: %s',
				$bytes_sent, $! )
			    if $remaining > 0;
			last;
		}

		# Write the remaining bytes after a partial write
		my $offset = 0;
		while ( $offset < $n ) {
			my $written =
			    syswrite( $socket, $buffer, $n - $offset, $offset );
			if ( !defined $written ) {
				$self->{log}
				    ->error( 'Write error after %d bytes: %s',
					$bytes_sent, $! );
				close $fh;
				return;
			}
			$offset += $written;
		}

		$bytes_sent += $n;
		$remaining  -= $n;
		$chunks++;
	}

	close $fh;
	$self->{log}->debug( 'Streamed %d chunks (%d bytes total)',
		$chunks, $bytes_sent );
	return $bytes_sent;
}

1;
