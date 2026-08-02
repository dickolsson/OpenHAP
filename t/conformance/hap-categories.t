#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Conformance tests for spec/HAP-Categories.md

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use FuguLib::TestLog;
use File::Temp qw(tempdir);

BEGIN {
	eval { require Crypt::Ed25519; require JSON::XS; };
	if ($@) {
		plan skip_all => 'Required modules not available';
	}
}

use_ok('OpenHAP::HAP');

subtest '[HAP-Categories §1] bridge category identifier is 2' => sub {
	my $hap = OpenHAP::HAP->new(
		port         => 51827,
		pin          => '123-45-678',
		name         => 'Category Bridge',
		storage_path => tempdir( CLEANUP => 1 ),
	);

	my $txt = $hap->get_mdns_txt_records;
	is( $txt->{ci}, 2,
		'[HAP-Categories §1/Bridge] OpenHAP advertises '
		    . 'CATEGORY_BRIDGE (2)' );
};

subtest '[HAP-Categories §3] category advertised in mDNS ci field' => sub {
	my $hap = OpenHAP::HAP->new(
		port         => 51828,
		pin          => '123-45-678',
		name         => 'Category Bridge',
		storage_path => tempdir( CLEANUP => 1 ),
	);

	my $txt = $hap->get_mdns_txt_records;
	ok( exists $txt->{ci}, 'ci field present in TXT records' );
	like( $txt->{ci}, qr/^\d+$/, 'ci is a numeric identifier' );

	# The category is a UI hint only. Bridged accessories of any
	# service type stay behind ci=2.
	is( $txt->{ci}, 2, 'bridge category regardless of bridged devices' );
};

done_testing();
