#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin    qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);
use FuguLib::File;
use FuguLib::Log;

use_ok('FuguLib::Store');

# The store reports recoverable failures through the default logger.
FuguLib::Log->set_default( FuguLib::Log->new( mode => 'quiet' ) );

my $dir = tempdir( CLEANUP => 1 );
my $n   = 0;

sub next_path()
{
	return sprintf '%s/state-%d.json', $dir, ++$n;
}

subtest 'set, get and persist' => sub {
	my $path  = next_path();
	my $store = FuguLib::Store->new( path => $path )->load;

	is( $store->get('missing'), undef, 'an unset key is undef' );
	ok( !$store->exists('missing'), 'and does not exist' );

	ok( $store->set( 'count', 3 ), 'set reports success' );
	is( $store->get('count'), 3, 'get returns it' );
	ok( $store->exists('count'), 'and it exists' );

	# A second object over the same file sees the same state
	my $reader = FuguLib::Store->new( path => $path )->load;
	is( $reader->get('count'), 3, 'another reader sees it' );

	ok( $store->set( 'nested', { a => [ 1, 2 ] } ), 'a structure stores' );
	is_deeply(
		FuguLib::Store->new( path => $path )->load->get('nested'),
		{ a => [ 1, 2 ] },
		'and comes back whole'
	);

	ok( $store->delete('count'), 'delete reports success' );
	ok( !FuguLib::Store->new( path => $path )->load->exists('count'),
		'and the key is gone from the file' );
};

subtest 'a stored undef is still a stored answer' => sub {
	my $path  = next_path();
	my $store = FuguLib::Store->new( path => $path )->load;

	$store->set( 'seen', undef );
	is( $store->get('seen'), undef, 'the value is undef' );
	ok( $store->exists('seen'), 'but the key exists' );
};

subtest 'increment' => sub {
	my $store = FuguLib::Store->new( path => next_path() )->load;

	is( $store->increment('c'), 1, 'an absent counter starts at 0' );
	is( $store->increment('c'), 2, 'and counts up' );
	is( $store->increment( 'c', 5 ), 7, 'a step is possible' );
	is( $store->get('c'), 7, 'the value persists in memory' );

	is( FuguLib::Store->new( path => $store->path )->load->get('c'),
		7, 'and on disk' );
};

subtest 'load tolerates a missing and a corrupt file' => sub {
	my $missing = FuguLib::Store->new( path => "$dir/never-written.json" );
	ok( $missing->load,          'load succeeds on a missing file' );
	is( $missing->get('any'),    undef, 'and the state is empty' );
	is( $missing->error,         undef, 'with no error' );

	# A crash can leave a truncated file. The program that would
	# rewrite it must not be the one that refuses to start.
	my $path = next_path();
	FuguLib::File->write( $path, '{"count": 3' );

	my $corrupt = FuguLib::Store->new( path => $path );
	ok( $corrupt->load, 'load survives a corrupt file' );
	is( $corrupt->get('count'), undef, 'the state is empty' );
	like( $corrupt->error, qr/Cannot read state/, 'and it says so' );

	# The store recovers by writing over it
	ok( $corrupt->set( 'count', 1 ), 'a write repairs the file' );
	is( FuguLib::Store->new( path => $path )->load->get('count'),
		1, 'and the new state reads back' );

	# A file that holds JSON, but not an object, is corrupt too
	FuguLib::File->write( $path, '[1, 2, 3]' );
	my $wrong = FuguLib::Store->new( path => $path )->load;
	is( $wrong->get('count'), undef, 'a JSON array is not state' );
	ok( defined $wrong->error, 'and it says so' );
};

subtest 'save is atomic' => sub {
	my $path  = next_path();
	my $store = FuguLib::Store->new( path => $path )->load;
	$store->set( 'good', 'value' );

	# A save that cannot finish must leave the previous file whole,
	# and must leave no partial file behind. A value that no encoder
	# can represent fails inside the call.
	my $unencodable = FuguLib::Store->new( path => $path )->load;
	$unencodable->data->{code} = sub { 1 };

	is( $unencodable->save, undef, 'the save fails' );
	like( $unencodable->error, qr/Cannot write state/, 'and says so' );

	is( FuguLib::Store->new( path => $path )->load->get('good'),
		'value', 'the previous state is intact' );

	opendir my $dh, $dir or die "opendir $dir: $!";
	my @partial = grep { /^\./ && !/^\.\.?$/ } readdir $dh;
	closedir $dh;
	is_deeply( \@partial, [], 'no partial file remains' );
};

subtest 'the mode keeps the state private' => sub {
	my $path = next_path();
	FuguLib::Store->new( path => $path )->load->set( 'secret', 'value' );
	is( ( stat $path )[2] & 07777, 0600, 'the default mode is 0600' );

	my $open = next_path();
	FuguLib::Store->new( path => $open, mode => 0644 )->load
	    ->set( 'public', 'value' );
	is( ( stat $open )[2] & 07777, 0644, 'the mode is configurable' );
};

subtest 'data gives the whole state for a batch change' => sub {
	my $path  = next_path();
	my $store = FuguLib::Store->new( path => $path )->load;

	$store->data->{a} = 1;
	$store->data->{b} = 2;
	ok( $store->save, 'one save for two changes' );

	my $reader = FuguLib::Store->new( path => $path )->load;
	is( $reader->get('a'), 1, 'the first change persisted' );
	is( $reader->get('b'), 2, 'and the second' );
};

subtest 'a missing path is a programming error' => sub {
	ok( !eval { FuguLib::Store->new; 1 },              'new needs a path' );
	ok( !eval { FuguLib::Store->new( path => '' ); 1 }, 'and a real one' );
};

done_testing();
