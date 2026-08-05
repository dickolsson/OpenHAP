#!/usr/bin/env perl
# ex:ts=8 sw=4:
# The OpenHAP website that 'make web' produces.
#
# The generic half of this file moved into App::FuguWeb::Check, which
# every project that uses the tool gets. What is left is what is true
# of this site and of no other: which sources must reach a page, and
# which cross-references must resolve where.
#
# The file drives subprocesses and loads no module from lib/, as the
# tooling tier requires.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use File::Find ();
use File::Temp qw(tempdir);

my $ROOT = "$RealBin/../..";

sub have ($tool)
{
	return system("command -v $tool >/dev/null 2>&1") == 0;
}

sub slurp ($path)
{
	open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
	local $/ = undef;
	my $content = <$fh>;
	close $fh;
	return $content;
}

plan skip_all => 'make not found'    unless have('make');
plan skip_all => 'lowdown not found' unless have('lowdown');
plan skip_all => 'mandoc not found'  unless have('mandoc');

# Build the whole site into a scratch directory.  WEBOUT points outside the
# repository. Thus the build cannot quietly rely on its default location.
my $default_build = -e "$ROOT/web/build";
my $OUT           = tempdir( CLEANUP => 1 );
my $build_log     = `cd $ROOT && make web WEBOUT=$OUT 2>&1`;
is( $? >> 8, 0, 'make web exits 0' ) or diag $build_log;

# Every generic assertion is in the tool. A site that fails one of them
# fails here, with the tool's own message.
my $check_log = `cd $ROOT && bin/fuguweb check --out $OUT 2>&1`;
is( $? >> 8, 0, 'fuguweb check exits 0' ) or diag $check_log;

# The build writes nothing outside WEBOUT. The default output directory
# must not appear as a side effect of a build somewhere else.
SKIP: {
	skip 'web/build predates this test', 1 if $default_build;
	ok( !-e "$ROOT/web/build",
		'build honours WEBOUT and writes nowhere else' );
}

# The pages and assets that this site holds, written down. The tool
# derives its expectation from .fuguwebrc and web/, so a page or an
# asset that is deleted from both is invisible to it. These names are
# the second opinion: dropping web/CNAME or the 404 page has to fail
# somewhere.
my @SITE = qw(
    index.html install.html manuals.html fuguvm.html fugu.html 404.html
);
my @ASSETS = qw(style.css robots.txt CNAME);

for my $file ( @SITE, @ASSETS ) {
	ok( -s "$OUT/$file", "$file exists and is not empty" );
}

# The manual sources have two consumers: this site, and install-man.
# The site globs a directory and the Makefile keeps a list, so the two
# can drift. A manual that reaches the site and not the list is
# published but never installed, never packaged, and has no cat page.
{
	my $makefile = slurp("$ROOT/Makefile");
	# The four lists run from MAN1 to the first CATMAN line.
	my ($lists) = $makefile =~ m{^MAN1\s*=(.*?)^CATMAN1\b}ms;
	$lists //= '';

	my @listed = $lists =~ m{(man/\S+\.(?:1|3p|5|8))}g;
	my %listed = map { $_ => 1 } @listed;
	ok( scalar @listed, 'the Makefile lists manual sources' );

	my @missing;
	for my $src ( sort glob("$ROOT/man/*/*") ) {
		next unless $src =~ m{/(man/[^/]+/[^/]+\.(?:1|3p|5|8))$};
		push @missing, $1 unless $listed{$1};
	}
	is( scalar @missing, 0,
		'every manual the site publishes is in MAN1/MAN3P/MAN5/MAN8' )
	    or diag "not installed, not packaged: @missing";
}

# The namespaces that a manuals group declares, read from .fuguwebrc as
# text. Plan 008 had to edit a hard-coded rule here for one directory;
# nobody should edit it again.
my %NAMESPACE;
{
	my $rc  = slurp("$ROOT/.fuguwebrc");
	my $dir = '';
	for my $line ( split /\n/, $rc ) {
		$line =~ s/#.*//;
		$dir = '' if $line =~ /^\s*\}/;
		$dir = ''         if $line =~ /^\s*manuals\b/;
		$dir = $1         if $line =~ m{^\s*dir\s*=?\s*man/(\S+)};
		$NAMESPACE{$dir} = $1
		    if length $dir
		    && $line =~ /^\s*namespace\s*=?\s*"?([^"\s]+)"?/;
	}

	ok( $NAMESPACE{fugu}, '.fuguwebrc declares the Fugu namespace' );
}

# Manual sources in the tree, and the page each one must produce.  The test
# discovers the list rather than writes it down. Thus a manual that is
# added but not published fails here. It does not silently go missing.
my %MANUAL;
for my $src ( sort glob("$ROOT/man/*/*") ) {
	next unless $src =~ m{/man/([^/]+)/([^/]+)\.(1|3p|5|8)$};
	my ( $dir, $stem, $section ) = ( $1, $2, $3 );

	my $name = ( $NAMESPACE{$dir} // '' ) . $stem;
	$MANUAL{$src} = "$name.$section.html";
}

ok( scalar keys %MANUAL, 'manual sources found in man/' );

# The POD sidecars, and the page each one must produce.  The test
# discovers them the same way the build discovers them. Thus a sidecar
# that is added but not published shows up here as a missing file.
my %POD;
File::Find::find(
	sub {
		return unless /\.pod$/;
		my $rel = $File::Find::name;
		$rel =~ s{^\Q$ROOT\E/}{};

		my $name = $rel;
		$name =~ s{^lib/}{};
		$name =~ s{\.pod$}{};
		$name =~ s{/}{::}g;

		$POD{$rel} = "$name.3p.html";
	},
	"$ROOT/lib"
);

ok( scalar keys %POD, 'POD sidecars found under lib/' );

for my $file ( sort( values %MANUAL ), sort( values %POD ) ) {
	ok( -s "$OUT/$file", "$file exists and is not empty" );
}

# The build renders install.html from INSTALL.md, not from retyped text
{
	my $html = slurp("$OUT/install.html");
	like( $html, qr/Create the system user/,
		'install.html carries content from INSTALL.md' );
}

# manuals.html lists every manual, with the description from its source
{
	my $index = slurp("$OUT/manuals.html");

	for my $src ( sort keys %MANUAL ) {
		my $page = $MANUAL{$src};
		like( $index, qr{href="(?:\./)?\Q$page\E"},
			"manuals.html links to $page" );

		my ($nd) = slurp($src) =~ m{^\.Nd\s+(.+)$}m;
		ok( defined $nd, "$src has an .Nd description" ) or next;

		like( $index, qr/\Q$nd\E/,
			"manuals.html shows the .Nd of $src verbatim" );
	}

	for my $src ( sort keys %POD ) {
		my $page = $POD{$src};
		like( $index, qr{href="(?:\./)?\Q$page\E"},
			"manuals.html links to $page" );

		# 'Module - description' follows '=head1 NAME'
		my ($desc) = slurp("$ROOT/$src")
		    =~ m{^=head1\s+NAME\s*\n\s*\n\S+\s+-\s+(.+?)\s*$}m;
		ok( defined $desc, "$src has a NAME description" ) or next;

		like( $index, qr/\Q$desc\E/,
			"manuals.html shows the NAME line of $src verbatim" );
	}
}

# The module reference covers every sidecar and nothing else.  The
# Fugu documentation is in mdoc. Thus the test does not count Fugu
# pages here.
{
	opendir my $dh, $OUT or die "Cannot read $OUT: $!";
	my @module_pages =
	    grep { /^(?:App|Protocol)::.*\.3p\.html$/ } readdir $dh;
	closedir $dh;

	is( scalar @module_pages, scalar keys %POD,
		'one module page per .pod sidecar, and no more' );
}

# Cross-references: local pages link locally. Everything else leaves for
# man.openbsd.org.  mandoc decides this from the contents of its working
# directory. Thus this assertion shows that the staging directory does
# its job.
{
	my $hapctl = slurp("$OUT/hapctl.8.html");
	like( $hapctl, qr{<a class="Xr" href="\./openhapd\.8\.html">},
		'.Xr openhapd 8 links to the local page' );
	like( $hapctl, qr{<a class="Xr" href="https://man\.openbsd\.org/rc\.8">},
		'.Xr rc 8 leaves for man.openbsd.org' );

	# Sibling module manuals cross-link. This only works because the
	# staging directory holds them under their Fugu:: names.
	my $daemon = slurp("$OUT/Fugu::Daemon.3p.html");
	like( $daemon, qr{<a class="Xr" href="\./Fugu::Pidfile\.3p\.html">},
		'.Xr Fugu::Pidfile 3p links to the local page' );
}

# The site is a pure function of the repository
{
	my $second = tempdir( CLEANUP => 1 );
	my $log    = `cd $ROOT && make web WEBOUT=$second 2>&1`;
	is( $? >> 8, 0, 'second build exits 0' ) or diag $log;

	my $diff = `diff -r $OUT $second 2>&1`;
	is( $diff, '', 'two builds are byte-identical' );
}

done_testing();
