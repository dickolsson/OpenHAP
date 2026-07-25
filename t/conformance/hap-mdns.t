#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Conformance tests for spec/HAP-mDNS.md

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use FuguLib::Log;
$OpenHAP::logger = FuguLib::Log->new( mode => 'quiet', ident => 'test' );
use File::Temp qw(tempdir);
use Digest::SHA qw(sha512);
use MIME::Base64 qw(encode_base64);

BEGIN {
	eval { require Crypt::Ed25519; require JSON::XS; };
	if ($@) {
		plan skip_all => 'Required modules not available';
	}
}

use_ok('OpenHAP::HAP');
use_ok('OpenHAP::MDNS');

sub make_hap (%extra)
{
	return OpenHAP::HAP->new(
		port         => 51827,
		pin          => '123-45-678',
		name         => 'mDNS Bridge',
		storage_path => tempdir( CLEANUP => 1 ),
		%extra,
	);
}

subtest '[HAP-mDNS §1] service type is hap over tcp' => sub {
	my $mdns = OpenHAP::MDNS->new(
		service_name => 'mDNS Bridge',
		port         => 51827,
	);
	ok( defined $mdns, 'MDNS registration wrapper created' );
	is( $mdns->{service_name}, 'mDNS Bridge', 'service name stored' );

	# The mdnsctl invocation registers the hap/tcp service type;
	# browsing _hap._tcp is asserted by the mdns integration test
	is( $mdns->{port}, 51827, 'port carried to registration' );
};

subtest '[HAP-mDNS §2] required TXT record fields' => sub {
	my $hap = make_hap();
	my $txt = $hap->get_mdns_txt_records;

	for my $key (qw(c# ff id md pv s# sf ci)) {
		ok( exists $txt->{$key},
			"[HAP-mDNS §2/$key] required field $key present" );
	}
	ok( !exists $txt->{sh},
		'[HAP-mDNS §2/sh] optional sh absent without setup_id' );
};

subtest '[HAP-mDNS §3] field values' => sub {
	my $hap = make_hap();
	my $txt = $hap->get_mdns_txt_records;

	is( $txt->{ff}, 0, '[HAP-mDNS §3.2] feature flags are 0' );
	is( $txt->{md}, 'mDNS Bridge',
		'[HAP-mDNS §3.4] model name matches display name' );
	like( $txt->{'s#'}, qr/^\d+$/, '[HAP-mDNS §3.6] s# is numeric' );
	cmp_ok( $txt->{'s#'}, '>=', 1,
		'[HAP-mDNS §3.6] state number starts at 1' );
};

subtest '[HAP-mDNS §9] complete TXT record' => sub {
	my $hap = make_hap( setup_id => 'XYZQ' );
	my $txt = $hap->get_mdns_txt_records;

	# All fields of the complete example are present with sane values
	like( $txt->{'c#'}, qr/^\d+$/,   'c# numeric' );
	is( $txt->{ff}, 0, 'ff zero' );
	like( $txt->{id}, qr/^[0-9A-F:]+$/, 'id MAC-like' );
	ok( length( $txt->{md} ),  'md present' );
	ok( length( $txt->{pv} ),  'pv present' );
	like( $txt->{'s#'}, qr/^\d+$/, 's# numeric' );
	like( $txt->{sf}, qr/^[01]$/, 'sf is 0 or 1' );
	like( $txt->{ci}, qr/^\d+$/,  'ci numeric' );
	ok( length( $txt->{sh} ), 'sh present with setup_id' );
};

subtest '[HAP-mDNS §10] bridge advertises a single service' => sub {

	# One mDNS service covers the bridge and all bridged accessories;
	# individual bridged accessories are not advertised separately
	my $hap  = make_hap();
	my $mdns = OpenHAP::MDNS->new(
		service_name => $hap->{name},
		port         => 51827,
		txt_records  => $hap->get_mdns_txt_records,
	);
	ok( defined $mdns, 'single registration for the bridge' );
	is( $mdns->{txt_records}{ci}, 2,
		'advertised category is Bridge for all bridged accessories'
	);
};

subtest '[HAP-mDNS §3.1] configuration number' => sub {
	my $hap = make_hap();
	my $txt = $hap->get_mdns_txt_records;

	like( $txt->{'c#'}, qr/^\d+$/, 'c# is numeric' );
	cmp_ok( $txt->{'c#'}, '>=', 1, 'c# starts at 1' );

	# c# increments when the accessory database changes
	$hap->{storage}->increment_config_number;
	my $txt2 = $hap->get_mdns_txt_records;
	is( $txt2->{'c#'}, $txt->{'c#'} + 1,
		'c# increments on configuration change ([HAP-mDNS §8])' );
};

subtest '[HAP-mDNS §3.3] device ID format' => sub {
	my $hap = make_hap();
	my $id  = $hap->get_device_id;

	like( $id, qr/^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/,
		'device ID is uppercase MAC-like format' );
	is( $hap->get_mdns_txt_records->{id},
		$id, 'TXT id field carries the device ID' );
};

subtest '[HAP-mDNS §3.5] protocol version' => sub {
	my $hap = make_hap();

	# pv=1 rather than 1.1: mdnsd uses '.' as the TXT record
	# delimiter and cannot escape it; HomeKit accepts pv=1
	is( $hap->get_mdns_txt_records->{pv},
		'1', 'pv advertised (1, see mdnsd delimiter note)' );
};

subtest '[HAP-mDNS §3.7] status flags follow pairing state' => sub {
	my $hap = make_hap();

	is( $hap->get_mdns_txt_records->{sf},
		1, 'sf=1 (bit 0 set) when not paired' );

	$hap->{storage}->save_pairing( 'controller', 'X' x 32, 1 );
	is( $hap->get_mdns_txt_records->{sf},
		0, 'sf=0 once paired ([HAP-mDNS §8] pairing added)' );

	$hap->{storage}->remove_all_pairings;
	is( $hap->get_mdns_txt_records->{sf},
		1, 'sf returns to 1 when pairing removed' );
};

subtest '[HAP-mDNS §3.8] category identifier' => sub {
	my $hap = make_hap();
	is( $hap->get_mdns_txt_records->{ci}, 2, 'ci=2 for a bridge' );
};

subtest '[HAP-mDNS §3.9] setup hash with fixed vector' => sub {
	my $hap = make_hap( setup_id => 'XYZQ' );

	# Pin the device ID by fixing the LTPK-derived identity
	$hap->{accessory_ltpk} = pack( 'H*', '00ffaabbccdd' . 'ee' x 26 );
	is( $hap->get_device_id, '00:FF:AA:BB:CC:DD',
		'fixed LTPK yields fixed device ID' );

	# setupHash = Base64(SHA512(SetupID + DeviceID.uppercase())[0:4])
	my $expected = encode_base64(
		substr( sha512( 'XYZQ' . '00:FF:AA:BB:CC:DD' ), 0, 4 ), '' );
	my $txt = $hap->get_mdns_txt_records;
	is( $txt->{sh}, $expected,
		'sh is Base64 of first 4 SHA-512 bytes over '
		    . 'SetupID + DeviceID' );
	is( length($txt->{sh}), 8, '4 hash bytes encode to 8 base64 chars' );
};

subtest '[HAP-mDNS §4] service instance name' => sub {
	my $hap = make_hap();
	is( $hap->get_mdns_txt_records->{md},
		'mDNS Bridge', 'model name matches the display name' );

	my $mdns = OpenHAP::MDNS->new(
		service_name => $hap->{name},
		port         => 51827,
	);
	is( $mdns->{service_name}, 'mDNS Bridge',
		'service advertised under the display name' );
};

subtest '[HAP-mDNS §6] port' => sub {
	my $mdns = OpenHAP::MDNS->new( service_name => 'x' );
	is( $mdns->{port}, 51827, 'default HAP port is 51827' );

	my $custom = OpenHAP::MDNS->new( service_name => 'x', port => 8080 );
	is( $custom->{port}, 8080, 'any available port can be advertised' );
};

done_testing();
