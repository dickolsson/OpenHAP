#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for scripts/spec-coverage against a fixture tree

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);

my $script = "$RealBin/../../scripts/spec-coverage";
ok( -x $script, 'spec-coverage script is executable' );

# Build a fixture spec/ + t/ tree
my $fixture  = tempdir( CLEANUP => 1 );
my $spec_dir = "$fixture/spec";
my $test_dir = "$fixture/t";
mkdir $spec_dir or die "mkdir $spec_dir: $!";
mkdir $test_dir or die "mkdir $test_dir: $!";

sub write_file ( $path, $content )
{
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}

write_file( "$spec_dir/HAP-Fixture8.md", <<'EOF' );
# HAP Fixture

## 1. First Section

Text.

### 1.1 Subsection

More text.

## 2. Second Section

### 2.1 Covered Table

| Row | Value |

## 3. Uncovered Section

Nothing cites this.
EOF

# Index file (stem without '-'): the tool lists it but does not count
# it
write_file( "$spec_dir/HAP.md", <<'EOF' );
# Index

## 1. Glossary
EOF

# Unnumbered file: the tool tolerates it. It has nothing to cover.
write_file( "$spec_dir/IMPLEMENTATIONS.md", <<'EOF' );
# Implementations

## Patterns

No numbered anchors here.
EOF

# A second topic family that covers the MDNS branch of the citation
# regex
write_file( "$spec_dir/MDNS-Fixture1.md", <<'EOF' );
# MDNS Fixture

## 1. Framed Section

Text.

## 2. Uncited Section

Nothing cites this.
EOF

# The test assembles the citation strings at runtime. Thus this
# file's own source never matches the citation grep when the tool runs
# on the real tree. The stem carries a digit to cover stems like
# HAP-TLV8.
my $STEM      = 'HAP-' . 'Fixture8';
my $MDNS_STEM = 'MDNS-' . 'Fixture1';

write_file( "$test_dir/fixture.t", <<EOF );
ok(1, '[$STEM §1] first section requirement');
ok(1, '[$STEM §1.1] subsection requirement');
ok(1, '[$STEM §2.1/RowName] table row citation');
ok(1, '[$MDNS_STEM §1] mdns family citation');
EOF

sub run_tool (@args)
{
	my $cmd    = join ' ', $script, '--spec-dir', $spec_dir,
	    '--test-dir', $test_dir, @args;
	my $output = `$cmd 2>&1`;
	return ( $? >> 8, $output );
}

# Basic run: the tool parses and joins the citations
{
	my ( $exit, $output ) = run_tool();
	is( $exit, 0, 'exits 0 with no stale citations' );
	like( $output, qr/HAP-Fixture8\.md\s+3\/5 sections cited/,
		'per-file coverage counts cited sections' );
	like( $output, qr/MDNS-Fixture1\.md\s+1\/2 sections cited/,
		'MDNS stem citation counted' );
	like( $output, qr/§1\s+\S*fixture\.t:1/,
		'citation resolved to file:line' );
	like( $output, qr/§2\.1\s+\S*fixture\.t:3/,
		'row-suffixed citation resolves to its section' );
	like( $output, qr/§3\s+UNCOVERED/, 'uncovered section reported' );
	like( $output, qr/§2\s+UNCOVERED/,
		'parent section not covered by child citation' );
	like( $output, qr/TOTAL: 4\/7 numbered sections cited/,
		'total line present' );
	like( $output, qr/HAP\.md\s+\(index, not counted\)/,
		'index file listed but not counted' );
	like( $output, qr/IMPLEMENTATIONS\.md\s+\(unnumbered, not counted\)/,
		'unnumbered file tolerated' );
}

# --quiet: totals only
{
	my ( $exit, $output ) = run_tool('--quiet');
	is( $exit, 0, '--quiet exits 0' );
	like( $output, qr/^TOTAL: 4\/7 numbered sections cited/m,
		'--quiet prints totals' );
	unlike( $output, qr/UNCOVERED/, '--quiet omits section detail' );
}

# --uncovered: only gaps
{
	my ( $exit, $output ) = run_tool('--uncovered');
	is( $exit, 0, '--uncovered exits 0' );
	like( $output, qr/§3\s+UNCOVERED/, '--uncovered lists gaps' );
	unlike( $output, qr/fixture\.t:1/,
		'--uncovered omits covered sections' );
}

# Stale citation: nonexistent section
{
	write_file( "$test_dir/stale.t", <<EOF );
ok(1, '[$STEM §9.9] no such section');
EOF
	my ( $exit, $output ) = run_tool('--quiet');
	is( $exit, 1, 'stale citation exits non-zero' );
	like( $output,
		qr/STALE: \S*stale\.t:1 cites HAP-Fixture8 §9\.9 \(no such section\)/,
		'stale citation names file:line and section' );
	unlink "$test_dir/stale.t";
}

# Stale citation: nonexistent spec file
{
	my $bogus = 'HAP-' . 'Bogus';
	write_file( "$test_dir/stale2.t", <<EOF );
ok(1, '[$bogus §1] no such spec file');
EOF
	my ( $exit, $output ) = run_tool('--quiet');
	is( $exit, 1, 'unknown spec stem exits non-zero' );
	like( $output, qr/STALE: \S*stale2\.t:1 cites HAP-Bogus §1 \(no such spec file\)/,
		'unknown stem reported with file:line' );
	unlink "$test_dir/stale2.t";
}

# The tool also scans a citation in a .pm helper under t/
{
	write_file( "$test_dir/Helper.pm", <<EOF );
# [$STEM §3] helper-level citation
1;
EOF
	my ( $exit, $output ) = run_tool();
	is( $exit, 0, 'helper citation accepted' );
	like( $output, qr/§3\s+\S*Helper\.pm:1/,
		'.pm files under the test dir are scanned' );
	unlink "$test_dir/Helper.pm";
}

done_testing();
