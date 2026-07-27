#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Unit tests for scripts/deps against fixture manifests
#
# Everything runs under --dry-run, so no package manager is ever
# invoked; --os drives all three platform branches from one runner.

use v5.36;
use Test::More;
use Cwd         qw(getcwd);
use FindBin     qw($RealBin);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);

my $script = "$RealBin/../../scripts/deps";
my $root   = "$RealBin/../..";
ok( -x $script, 'deps script is executable' );

sub write_file ( $path, $content )
{
	open my $fh, '>', $path or die "Cannot write $path: $!";
	print $fh $content;
	close $fh;
}

# fixture($os, $manifest):
#	A directory holding deps/<os>.txt. deps reads the manifest
#	relative to the current directory, so tests chdir into this.
sub fixture ( $os, $manifest )
{
	my $dir = tempdir( CLEANUP => 1 );
	make_path("$dir/deps");
	write_file( "$dir/deps/$os.txt", $manifest );

	return $dir;
}

# run_in($dir, @args):
#	Run deps with $dir as the working directory.
sub run_in ( $dir, @args )
{
	my $cwd = getcwd();
	chdir $dir or die "chdir $dir: $!";
	my $output = `$script @args 2>&1`;
	my $exit   = $? >> 8;
	chdir $cwd or die "chdir $cwd: $!";

	return ( $exit, $output );
}

my $MANIFEST = <<'EOF';
# a comment
runtime pkg alpha
runtime cpan Foo::Bar

	# an indented comment
test pkg beta
develop pkg gamma
develop cpan Baz
EOF

# Environment filtering
{
	my $dir = fixture( 'OpenBSD', $MANIFEST );

	my ( $exit, $output ) = run_in( $dir, '--os OpenBSD --dry-run runtime' );
	is( $exit, 0, 'runtime exits 0' );
	like( $output, qr/^\+ pkg_add alpha$/m, 'runtime selects its package' );
	like( $output, qr/cpanm .*Foo::Bar/, 'runtime selects its CPAN module' );
	unlike( $output, qr/beta|gamma|Baz/,
		'other environments are not selected' );

	( $exit, $output ) = run_in( $dir, '--os OpenBSD --dry-run test' );
	is( $exit, 0, 'test exits 0' );
	like( $output, qr/^\+ pkg_add beta$/m, 'test selects only its package' );
	unlike( $output, qr/alpha|gamma/, 'and nothing else' );
	unlike( $output, qr/cpanm/, 'no cpanm run when a tier has no modules' );
}

# Comments and blank lines are skipped, including an indented comment
{
	my ( $exit, $output ) =
	    run_in( fixture( 'OpenBSD', $MANIFEST ), '--os OpenBSD --dry-run develop' );
	is( $exit, 0, 'a manifest with comments and blanks parses' );
	like( $output, qr/^\+ pkg_add gamma$/m, 'develop package selected' );
	unlike( $output, qr/comment/, 'comment text never reaches a command' );
}

# Per-OS command shapes
{
	my $manifest = "runtime pkg alpha\nruntime pkg beta\n";

	my ( undef, $openbsd ) =
	    run_in( fixture( 'OpenBSD', $manifest ), '--os OpenBSD --dry-run runtime' );
	like( $openbsd, qr/^\+ pkg_add alpha beta$/m, 'OpenBSD uses pkg_add' );

	my ( undef, $linux ) =
	    run_in( fixture( 'Linux', $manifest ), '--os Linux --dry-run runtime' );
	like( $linux, qr/^\+ sudo apt-get update$/m, 'Linux refreshes apt first' );
	like( $linux, qr/^\+ sudo apt-get install -y alpha beta$/m,
		'Linux uses apt-get install' );

	my ( undef, $darwin ) =
	    run_in( fixture( 'Darwin', $manifest ), '--os Darwin --dry-run runtime' );
	like( $darwin, qr/^\+ brew install alpha beta$/m, 'Darwin uses brew' );
}

# An OS with a manifest but no package manager branch
{
	my ( $exit, $output ) = run_in(
		fixture( 'Plan9', "runtime pkg alpha\n" ),
		'--os Plan9 --dry-run runtime'
	);
	isnt( $exit, 0, 'an unsupported OS exits non-zero' );
	like( $output, qr/Unknown OS: Plan9/, 'and says which OS' );
}

# List-form exec: a name containing a space stays one argument. The
# shell version built a string and let word splitting have it, so this
# installed two wrong packages.
{
	my ( $exit, $output ) = run_in(
		fixture( 'OpenBSD', "runtime pkg foo bar\n" ),
		'--os OpenBSD --dry-run runtime'
	);
	is( $exit, 0, 'a package name with a space parses' );
	like( $output, qr/^\+ pkg_add 'foo bar'$/m,
		'and is passed as a single argument' );
}

# CPAN options. Both cases pin PERL_LOCAL_LIB_ROOT rather than inherit
# it: CI sets it (.github/actions/setup-perl exports it for local::lib)
# and a developer shell usually does not, so an inherited value makes
# the same test assert opposite things in the two places.
{
	my $dir = fixture( 'OpenBSD', "runtime cpan Foo::Bar\n" );

	{
		delete local $ENV{PERL_LOCAL_LIB_ROOT};
		my ( undef, $output ) =
		    run_in( $dir, '--os OpenBSD --dry-run runtime' );
		like( $output, qr/^\+ cpanm --notest Foo::Bar$/m,
			'cpanm runs --notest' );
		unlike( $output, qr/--local-lib/,
			'no --local-lib without PERL_LOCAL_LIB_ROOT' );
	}

	local $ENV{PERL_LOCAL_LIB_ROOT} = '/tmp/openhap-locallib';
	my ( undef, $output ) = run_in( $dir, '--os OpenBSD --dry-run runtime' );
	like( $output, qr/^\+ cpanm --notest --local-lib=\S+ Foo::Bar$/m,
		'PERL_LOCAL_LIB_ROOT becomes --local-lib' );
	like( $output, qr{--local-lib=/tmp/openhap-locallib},
		'and carries its value' );
}

# Usage and manifest errors
{
	my ( $exit, $output ) = run_in( fixture( 'OpenBSD', '' ), '' );
	isnt( $exit, 0, 'no environment argument exits non-zero' );
	like( $output, qr/usage: deps/, 'and prints usage' );
}

# An environment that is not one of the three selects nothing, which the
# shell version reported as a successful install.
{
	my ( $exit, $output ) =
	    run_in( fixture( 'OpenBSD', $MANIFEST ), '--os OpenBSD --dry-run bogus' );
	isnt( $exit, 0, 'an unknown environment exits non-zero' );
	like( $output, qr/unknown environment 'bogus'/, 'and names it' );
	unlike( $output, qr/installed successfully/,
		'and does not claim success' );
}

{
	my ( $exit, $output ) = run_in(
		fixture( 'OpenBSD', "runtime pkg\n" ),
		'--os OpenBSD --dry-run runtime'
	);
	isnt( $exit, 0, 'a line missing its name exits non-zero' );
	like( $output, qr/Invalid format/,        'and reports the bad line' );
	like( $output, qr/<environment> <pkg\|cpan>/, 'and the expected shape' );
}

{
	my ( $exit, $output ) = run_in(
		fixture( 'OpenBSD', "runtime deb alpha\n" ),
		'--os OpenBSD --dry-run runtime'
	);
	isnt( $exit, 0, 'an unknown type exits non-zero' );
	like( $output, qr/Unknown type 'deb'/, 'and names the type' );
}

# A malformed line in another environment still fails: the shell version
# filtered before validating, so this stayed hidden until someone ran
# that tier.
{
	my ( $exit, $output ) = run_in(
		fixture( 'OpenBSD', "runtime pkg alpha\ndevelop deb gamma\n" ),
		'--os OpenBSD --dry-run runtime'
	);
	isnt( $exit, 0, 'a bad line in an unselected environment still fails' );
}

# A missing manifest is not an error - most platforms have none
{
	my ( $exit, $output ) =
	    run_in( tempdir( CLEANUP => 1 ), '--os Nosuchos --dry-run runtime' );
	is( $exit, 0, 'a missing manifest exits 0' );
	like( $output, qr/No dependencies for Nosuchos/, 'and says so' );
}

# The real manifests parse, so a typo in one fails here rather than on
# somebody's laptop halfway through an install
for my $os (qw(OpenBSD Linux Darwin)) {
	for my $env (qw(runtime test develop)) {
		my ( $exit, $output ) =
		    run_in( $root, "--os $os --dry-run $env" );
		is( $exit, 0, "deps/$os.txt parses for $env" )
		    or diag($output);
	}
}

done_testing();
