#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for scripts/deps-key against fixture trees
#
# The provisioning key is consumed by scripts/vm-up (which restores the
# snapshot named after it) and scripts/vm-provision (which saves it), so
# the framing is a contract, not an implementation detail. These tests
# pin it.

use v5.36;
use Test::More;
use Digest::SHA qw(sha256_hex);
use FindBin     qw($RealBin);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);

my $script = "$RealBin/../../scripts/deps-key";
ok( -x $script, 'deps-key script is executable' );

# A deps layer whose markers are indented, as they are in the real
# scripts/vm-provision: they sit inside an 'else' block. Anchoring the
# extraction on '^#' once matched nothing at all, which silently dropped
# this input from the digest.
my $PROVISION = <<'EOF';
#!/bin/sh
echo before

if vm_run "test -f marker"; then
	echo warm
else
	# BEGIN deps layer
	vm_run <<INNER
	pkg_add -u
INNER
	# END deps layer
fi

echo after
EOF

sub write_file ( $path, $content )
{
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}

# build_fixture(%override):
#	A minimal project root. Any of the four digest inputs can be
#	overridden; passing undef for cpanfile omits the file entirely.
sub build_fixture (%override)
{
	my %file = (
		'deps/OpenBSD.txt'    => "runtime pkg mosquitto\n",
		'scripts/deps'        => "#!/bin/sh\necho deps\n",
		'scripts/vm-provision' => $PROVISION,
		'cpanfile'            => "requires 'JSON::XS';\n",
		%override,
	);

	my $root = tempdir( CLEANUP => 1 );
	make_path("$root/deps");
	make_path("$root/scripts");

	for my $name ( sort keys %file ) {
		next unless defined $file{$name};
		write_file( "$root/$name", $file{$name} );
	}

	return $root;
}

sub run_tool (@args)
{
	my $output = `$script @args 2>&1`;
	return ( $? >> 8, $output );
}

sub key_for ($root)
{
	my ( $exit, $output ) = run_tool( '--root', $root );
	is( $exit, 0, 'exits 0' ) or diag($output);
	chomp $output;
	return $output;
}

# Shape
{
	my ( $exit, $output ) = run_tool( '--root', build_fixture() );
	is( $exit, 0, 'exits 0 on a well-formed tree' );
	like( $output, qr/\A[0-9a-f]{12}\n\z/,
		'prints exactly 12 lowercase hex characters' );
}

# Golden vector: the framing contract, recomputed independently so a
# change to it fails with a readable diff rather than a mystery hex
{
	my $root = build_fixture();
	my $expected = substr sha256_hex(
		    "== deps/OpenBSD.txt\n"
		  . "runtime pkg mosquitto\n"
		  . "== scripts/deps\n"
		  . "#!/bin/sh\necho deps\n"
		  . "== cpanfile\n"
		  . "requires 'JSON::XS';\n"
		  . "== deps layer\n"
		  . "\t# BEGIN deps layer\n"
		  . "\tvm_run <<INNER\n"
		  . "\tpkg_add -u\n"
		  . "INNER\n"
		  . "\t# END deps layer\n"
	), 0, 12;

	is( key_for($root), $expected,
		'key matches an independently computed SHA-256 of the framing' );
}

# Determinism and path independence. Path independence is what lets
# vm-up and vm-provision agree wherever the checkout lives.
{
	my $root = build_fixture();
	is( key_for($root), key_for($root), 'same tree gives the same key' );

	my $elsewhere = build_fixture();
	is( key_for($root), key_for($elsewhere),
		'identical contents at a different path give the same key' );
}

# Every labelled input is inside the digest
{
	my $base = key_for( build_fixture() );

	isnt( $base,
		key_for( build_fixture( 'deps/OpenBSD.txt' => "runtime pkg foo\n" ) ),
		'deps/OpenBSD.txt changes the key' );
	isnt( $base,
		key_for( build_fixture( 'scripts/deps' => "#!/bin/sh\necho other\n" ) ),
		'scripts/deps changes the key' );
	isnt( $base,
		key_for( build_fixture( cpanfile => "requires 'Foo';\n" ) ),
		'cpanfile changes the key' );
	isnt( $base, key_for( build_fixture( cpanfile => undef ) ),
		'an absent cpanfile is tolerated and gives a distinct key' );
}

# Only the deps layer of vm-provision counts: the OpenHAP layer runs on
# every provision and never enters the snapshot, so editing it must not
# invalidate the cached dependencies.
{
	my $base = key_for( build_fixture() );

	my $inside = $PROVISION;
	$inside =~ s/pkg_add -u/pkg_add -u -v/;
	isnt( $base, key_for( build_fixture( 'scripts/vm-provision' => $inside ) ),
		'a change inside the deps layer markers changes the key' );

	my $outside = $PROVISION;
	$outside =~ s/echo after/echo afterwards/;
	is( $base, key_for( build_fixture( 'scripts/vm-provision' => $outside ) ),
		'a change outside the markers leaves the key alone' );
}

# The labels exist so a boundary shift between two inputs cannot
# silently produce the same digest
{
	my $shifted = key_for(
		build_fixture(
			'deps/OpenBSD.txt' => '',
			'scripts/deps' => "runtime pkg mosquitto\n#!/bin/sh\necho deps\n",
		)
	);
	isnt( key_for( build_fixture() ), $shifted,
		'moving a line across an input boundary changes the key' );
}

# Fail closed. A digest over silently-missing inputs is worse than no
# digest: it looks valid and caches a stale layer forever.
{
	my $no_begin = $PROVISION;
	$no_begin =~ s/^\t# BEGIN deps layer\n//m;
	my ( $exit, $output ) = run_tool( '--root',
		build_fixture( 'scripts/vm-provision' => $no_begin ) );
	isnt( $exit, 0, 'a missing BEGIN marker exits non-zero' );
	like( $output, qr/deps layer markers/,
		'the diagnostic names the deps layer markers' );
	like( $output, qr{scripts/vm-provision},
		'the diagnostic names the file it looked in' );
	unlike( $output, qr/\A[0-9a-f]{12}$/m,
		'no key is printed when the markers are missing' );
}

# BEGIN with no END: the case the shell version's line count let through
{
	my $no_end = $PROVISION;
	$no_end =~ s/^\t# END deps layer\n//m;
	my ( $exit, $output ) = run_tool( '--root',
		build_fixture( 'scripts/vm-provision' => $no_end ) );
	isnt( $exit, 0, 'a missing END marker exits non-zero' );
	unlike( $output, qr/\A[0-9a-f]{12}$/m,
		'no key is printed when END is missing' );
}

# Required inputs are required
{
	my ( $exit, $output ) = run_tool( '--root',
		build_fixture( 'deps/OpenBSD.txt' => undef ) );
	isnt( $exit, 0, 'a missing deps/OpenBSD.txt exits non-zero' );
	like( $output, qr{deps/OpenBSD\.txt}, 'the diagnostic names the file' );
}

{
	my ( $exit, $output ) =
	    run_tool( '--root', build_fixture( 'scripts/deps' => undef ) );
	isnt( $exit, 0, 'a missing scripts/deps exits non-zero' );
	like( $output, qr{scripts/deps}, 'the diagnostic names the file' );
}

{
	my ( $exit, $output ) = run_tool( '--root', '/nonexistent/openhap' );
	isnt( $exit, 0, 'a nonexistent root exits non-zero' );
}

# The real tree is well-formed, so a marker accidentally deleted from
# scripts/vm-provision fails here rather than at provisioning time
{
	my ( $exit, $output ) = run_tool();
	is( $exit, 0, 'the real project tree produces a key' );
	like( $output, qr/\A[0-9a-f]{12}\n\z/, 'and it is well formed' );
}

done_testing();
