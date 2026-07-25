#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use_ok('FuguLib::Log');

# Test 1: Create logger in stderr mode
{
	my $log = FuguLib::Log->new( mode => 'stderr', level => 'debug' );
	ok( defined $log, 'Created stderr logger' );
	isa_ok( $log, 'FuguLib::Log' );
}

# Test 2: Create logger in quiet mode
{
	my $log = FuguLib::Log->new( mode => 'quiet' );
	ok( defined $log, 'Created quiet logger' );

	# Capture STDERR to prove quiet mode produces no output
	my $stderr = '';
	{
		local *STDERR;
		open STDERR, '>', \$stderr or die "Cannot capture STDERR: $!";
		$log->debug('test');
		$log->info('test');
	}
	is( $stderr, '', 'Quiet logger produces no output' );
}

# Test 3: Level filtering
{
	my $log = FuguLib::Log->new( mode => 'quiet', level => 'warning' );

	# Can't easily test output, but can verify methods exist
	eval {
		$log->debug('debug message');
		$log->info('info message');
		$log->warning('warning message');
		$log->error('error message');
	};
	ok( !$@, 'All log levels work' );
}

# Test 4: Printf-style formatting
{
	my $log = FuguLib::Log->new( mode => 'quiet' );

	eval { $log->info( 'Test %s %d', 'string', 42 ); };
	ok( !$@, 'Printf-style formatting works' );
}

# Test 5: Change log level
{
	my $log = FuguLib::Log->new( mode => 'stderr', level => 'error' );

	my $stderr = '';
	{
		local *STDERR;
		open STDERR, '>', \$stderr or die "Cannot capture STDERR: $!";
		$log->debug('suppressed at error level');
	}
	is( $stderr, '', 'debug suppressed before set_level' );

	$log->set_level('debug');
	$stderr = '';
	{
		local *STDERR;
		open STDERR, '>', \$stderr or die "Cannot capture STDERR: $!";
		$log->debug('now visible');
	}
	like( $stderr, qr/now visible/, 'set_level enables debug output' );
}

# Test 6: Default values
{
	my $log = FuguLib::Log->new();
	ok( defined $log, 'Created logger with defaults' );
}

# Test 7: Invalid mode
{
	eval { my $log = FuguLib::Log->new( mode => 'invalid' ); };
	like( $@, qr/Invalid log mode/, 'Rejects invalid mode' );
}

# Test 8: Alias methods
{
	my $log = FuguLib::Log->new( mode => 'quiet' );

	eval {
		$log->warn('warning');    # Alias for warning
		$log->err('error');       # Alias for error
	};
	ok( !$@, 'Alias methods work' );
}

done_testing();
