#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use FuguLib::TestLog;

use_ok('OpenHAP::PIN');

# Test normalize_pin: basic operation
{
	my $pin = OpenHAP::PIN::normalize_pin('1234-5678');
	is($pin, '12345678',
	    '[HAP-Pairing §2.2] 8-digit setup code accepted with dashes');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('12345678');
	is($pin, '12345678', 'Normalize PIN without dashes');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('1234 5678');
	is($pin, '12345678', 'Normalize PIN with space');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('12-34-56-78');
	is($pin, '12345678', 'Normalize PIN with multiple dashes');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('1 2 3 4 - 5 6 7 8');
	is($pin, '12345678', 'Normalize PIN with spaces and dashes');
}

# Test normalize_pin: invalid formats
{
	my $pin = OpenHAP::PIN::normalize_pin('123-4567');
	is($pin, undef,
	    '[HAP-Pairing §2.2] reject PIN with 7 digits (setup code is 8 digits)');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('1234-56789');
	is($pin, undef, 'Reject PIN with 9 digits');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('abcd-efgh');
	is($pin, undef, 'Reject PIN with letters');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('1234-567a');
	is($pin, undef, 'Reject PIN with mixed alphanumeric');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('');
	is($pin, undef, 'Reject empty string');
}

{
	my $pin = OpenHAP::PIN::normalize_pin(undef);
	is($pin, undef, 'Handle undefined input');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('1234-');
	is($pin, undef, 'Reject incomplete PIN');
}

# Test validate_pin: valid PINs
{
	ok(OpenHAP::PIN::validate_pin('9876-5432'), 'Valid PIN with dash');
}

{
	ok(OpenHAP::PIN::validate_pin('98765432'), 'Valid PIN without dash');
}

{
	ok(OpenHAP::PIN::validate_pin('1111-2222'), 'Valid PIN with repeated digits');
}

{
	ok(OpenHAP::PIN::validate_pin('0000-0001'), 'Valid PIN starting with zeros');
}

# Test validate_pin: HAP disallows trivial setup codes (Apple HAP R2
# 5.3). The trivial-code blacklist is not in spec/.
{
	ok(!OpenHAP::PIN::validate_pin('00000000'), 'Reject 00000000');
}

{
	ok(!OpenHAP::PIN::validate_pin('11111111'), 'Reject 11111111');
}

{
	ok(!OpenHAP::PIN::validate_pin('22222222'), 'Reject 22222222');
}

{
	ok(!OpenHAP::PIN::validate_pin('33333333'), 'Reject 33333333');
}

{
	ok(!OpenHAP::PIN::validate_pin('44444444'), 'Reject 44444444');
}

{
	ok(!OpenHAP::PIN::validate_pin('55555555'), 'Reject 55555555');
}

{
	ok(!OpenHAP::PIN::validate_pin('66666666'), 'Reject 66666666');
}

{
	ok(!OpenHAP::PIN::validate_pin('77777777'), 'Reject 77777777');
}

{
	ok(!OpenHAP::PIN::validate_pin('88888888'), 'Reject 88888888');
}

{
	ok(!OpenHAP::PIN::validate_pin('99999999'), 'Reject 99999999');
}

{
	ok(!OpenHAP::PIN::validate_pin('12345678'), 'Reject 12345678');
}

{
	ok(!OpenHAP::PIN::validate_pin('87654321'), 'Reject 87654321');
}

# Test validate_pin: it must also reject invalid PINs with dashes
{
	ok(!OpenHAP::PIN::validate_pin('0000-0000'), 'Reject 0000-0000');
}

{
	ok(!OpenHAP::PIN::validate_pin('1111-1111'), 'Reject 1111-1111');
}

{
	ok(!OpenHAP::PIN::validate_pin('1234-5678'), 'Reject 1234-5678 (sequential)');
}

{
	ok(!OpenHAP::PIN::validate_pin('8765-4321'), 'Reject 8765-4321 (reverse sequential)');
}

# Test validate_pin: malformed input
{
	ok(!OpenHAP::PIN::validate_pin('123-4567'), 'Reject malformed PIN (7 digits)');
}

{
	ok(!OpenHAP::PIN::validate_pin('abcd-efgh'), 'Reject non-numeric PIN');
}

{
	ok(!OpenHAP::PIN::validate_pin(''), 'Reject empty string');
}

{
	ok(!OpenHAP::PIN::validate_pin(undef), 'Reject undefined input');
}

# Test edge cases
{
	my $pin = OpenHAP::PIN::normalize_pin('----1234----5678----');
	is($pin, '12345678', 'Handle excessive dashes');
}

{
	my $pin = OpenHAP::PIN::normalize_pin('   1234   5678   ');
	is($pin, '12345678', 'Handle excessive spaces');
}

# Test that normalization is idempotent
{
	my $pin1 = OpenHAP::PIN::normalize_pin('1234-5678');
	my $pin2 = OpenHAP::PIN::normalize_pin($pin1);
	is($pin1, $pin2, 'Normalization is idempotent');
}

done_testing();
