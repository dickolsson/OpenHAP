#!/usr/bin/env perl
# ex:ts=8 sw=4:
use v5.36;
use Test::More;

use_ok('Protocol::HAP::SetupCode');

# Test normalize_setup_code: basic operation
{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('1234-5678');
	is($pin, '12345678',
	    '[HAP-Pairing §2.2] 8-digit setup code accepted with dashes');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('12345678');
	is($pin, '12345678', 'Normalize PIN without dashes');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('1234 5678');
	is($pin, '12345678', 'Normalize PIN with space');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('12-34-56-78');
	is($pin, '12345678', 'Normalize PIN with multiple dashes');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('1 2 3 4 - 5 6 7 8');
	is($pin, '12345678', 'Normalize PIN with spaces and dashes');
}

# Test normalize_setup_code: invalid formats
{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('123-4567');
	is($pin, undef,
	    '[HAP-Pairing §2.2] reject PIN with 7 digits (setup code is 8 digits)');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('1234-56789');
	is($pin, undef, 'Reject PIN with 9 digits');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('abcd-efgh');
	is($pin, undef, 'Reject PIN with letters');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('1234-567a');
	is($pin, undef, 'Reject PIN with mixed alphanumeric');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('');
	is($pin, undef, 'Reject empty string');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code(undef);
	is($pin, undef, 'Handle undefined input');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('1234-');
	is($pin, undef, 'Reject incomplete PIN');
}

# Test validate_setup_code: valid PINs
{
	ok(Protocol::HAP::SetupCode::validate_setup_code('9876-5432'), 'Valid PIN with dash');
}

{
	ok(Protocol::HAP::SetupCode::validate_setup_code('98765432'), 'Valid PIN without dash');
}

{
	ok(Protocol::HAP::SetupCode::validate_setup_code('1111-2222'), 'Valid PIN with repeated digits');
}

{
	ok(Protocol::HAP::SetupCode::validate_setup_code('0000-0001'), 'Valid PIN starting with zeros');
}

# Test validate_setup_code: HAP disallows trivial setup codes (Apple HAP R2
# 5.3). The trivial-code blacklist is not in spec/.
{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('00000000'), 'Reject 00000000');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('11111111'), 'Reject 11111111');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('22222222'), 'Reject 22222222');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('33333333'), 'Reject 33333333');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('44444444'), 'Reject 44444444');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('55555555'), 'Reject 55555555');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('66666666'), 'Reject 66666666');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('77777777'), 'Reject 77777777');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('88888888'), 'Reject 88888888');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('99999999'), 'Reject 99999999');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('12345678'), 'Reject 12345678');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('87654321'), 'Reject 87654321');
}

# Test validate_setup_code: it must also reject invalid PINs with dashes
{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('0000-0000'), 'Reject 0000-0000');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('1111-1111'), 'Reject 1111-1111');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('1234-5678'), 'Reject 1234-5678 (sequential)');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('8765-4321'), 'Reject 8765-4321 (reverse sequential)');
}

# Test validate_setup_code: malformed input
{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('123-4567'), 'Reject malformed PIN (7 digits)');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code('abcd-efgh'), 'Reject non-numeric PIN');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code(''), 'Reject empty string');
}

{
	ok(!Protocol::HAP::SetupCode::validate_setup_code(undef), 'Reject undefined input');
}

# Test edge cases
{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('----1234----5678----');
	is($pin, '12345678', 'Handle excessive dashes');
}

{
	my $pin = Protocol::HAP::SetupCode::normalize_setup_code('   1234   5678   ');
	is($pin, '12345678', 'Handle excessive spaces');
}

# Test that normalization is idempotent
{
	my $pin1 = Protocol::HAP::SetupCode::normalize_setup_code('1234-5678');
	my $pin2 = Protocol::HAP::SetupCode::normalize_setup_code($pin1);
	is($pin1, $pin2, 'Normalization is idempotent');
}

done_testing();
