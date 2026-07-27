#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Tests for the static website produced by 'make web'

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
# repository so the build cannot quietly rely on its default location.
my $default_build = -e "$ROOT/web/build";
my $OUT           = tempdir( CLEANUP => 1 );
my $build_log     = `cd $ROOT && make web WEBOUT=$OUT 2>&1`;
is( $? >> 8, 0, 'make web exits 0' ) or diag $build_log;

# Hand-written pages
my @SITE = qw(
    index.html
    install.html
    manuals.html
    openhvf.html
    fugulib.html
    404.html
);

my @ASSETS = qw(style.css robots.txt CNAME);

# Every page carries the same navigation
my @NAV = (
	'index.html',
	'install.html',
	'manuals.html',
	'openhvf.html',
	'fugulib.html',
	'https://github.com/dickolsson/openhap',
);

# Manual sources in the tree, and the page each one must produce.  The list
# is discovered rather than written down, so a manual that is added without
# being published fails here instead of silently going missing.
my %MANUAL;
for my $src ( sort glob("$ROOT/man/*/*") ) {
	next unless $src =~ m{/man/([^/]+)/([^/]+)\.(1|3p|5|8)$};
	my ( $dir, $stem, $section ) = ( $1, $2, $3 );

	# FuguLib pages are module manuals: the source drops the namespace
	# because make cannot have a colon in a target, the page keeps it
	my $name = $dir eq 'fugulib' ? "FuguLib::$stem" : $stem;
	$MANUAL{$src} = "$name.$section.html";
}

ok( scalar keys %MANUAL, 'manual sources found in man/' );

# The POD sidecars, and the page each one must produce.  Discovered the
# same way the build discovers them, so a sidecar that is added without
# being published shows up here as a missing file.
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

ok( scalar keys %POD, 'POD sidecars found under lib/OpenHAP' );

my @PAGES = ( @SITE, sort values %MANUAL, sort values %POD );

for my $file ( @PAGES, @ASSETS ) {
	ok( -s "$OUT/$file", "$file exists and is not empty" );
}

# Nothing outside WEBOUT is written: the default output directory must not
# appear as a side effect of building somewhere else
SKIP: {
	skip 'web/build predates this test', 1 if $default_build;
	ok( !-e "$ROOT/web/build",
		'build honours WEBOUT and writes nowhere else' );
}

# The mdoc staging directory is a build detail, not content
ok( !-e "$OUT/.man", 'the .man staging directory is removed' );

for my $page (@PAGES) {
	my $html = slurp("$OUT/$page");

	unlike( $html, qr/\@TITLE\@/, "$page has no unsubstituted \@TITLE\@" );

	my ($title) = $html =~ m{<title>([^<]*)</title>};
	ok( defined $title && length $title, "$page has a title" );

	# mkpage.sh substitutes the title with sed, so a title containing a
	# slash, an ampersand or a newline would be mangled rather than
	# escaped.  Assert no title ever does.
	unlike( $title // '', qr{[/&\n]}, "$page title is sed-safe" );

	for my $link (@NAV) {
		like( $html, qr/href="\Q$link\E"/, "$page links to $link" );
	}

	# Nothing may be root-absolute: the site is served from a project
	# path, where a leading slash leaves the site entirely
	my @refs = $html =~ m{(?:href|src)="([^"]+)"}g;
	my @rooted = grep { m{^/} } @refs;
	is( scalar @rooted, 0, "$page has no root-absolute reference" )
	    or diag "offenders: @rooted";

	# Every relative reference must resolve to a file that was built,
	# and every fragment to an id that exists on the target page
	for my $ref (@refs) {
		unlike( $ref, qr{^file:}i, "$page: $ref is not a file: URL" );
		next if $ref =~ m{^[a-z]+:};    # absolute: http, https, mailto

		my ( $path, $fragment ) = split /#/, $ref, 2;
		$path = $page unless length $path;

		ok( -e "$OUT/$path", "$page: $ref resolves inside the site" )
		    or next;
		next unless defined $fragment && length $fragment;

		like( slurp("$OUT/$path"), qr/\bid="\Q$fragment\E"/,
			"$page: $ref points at an existing anchor" );
	}
}

# install.html is rendered from INSTALL.md, not retyped
{
	my $html = slurp("$OUT/install.html");
	like( $html, qr/Create system user/,
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

		# '=head1 NAME' is followed by 'Module - description'
		my ($desc) = slurp("$ROOT/$src")
		    =~ m{^=head1\s+NAME\s*\n\s*\n\S+\s+-\s+(.+?)\s*$}m;
		ok( defined $desc, "$src has a NAME description" ) or next;

		like( $index, qr/\Q$desc\E/,
			"manuals.html shows the NAME line of $src verbatim" );
	}
}

# The module reference covers every sidecar and nothing else.  FuguLib is
# documented in mdoc, so its pages are not counted here.
{
	opendir my $dh, $OUT or die "Cannot read $OUT: $!";
	my @module_pages =
	    grep { /^(?:OpenHAP|OpenHVF)::.*\.3p\.html$/ } readdir $dh;
	closedir $dh;

	is( scalar @module_pages, scalar keys %POD,
		'one module page per .pod sidecar, and no more' );
}

# Cross-references: local pages link locally, everything else leaves for
# man.openbsd.org.  mandoc decides this by looking in its working directory,
# so this is the assertion that the staging directory is doing its job.
{
	my $hapctl = slurp("$OUT/hapctl.8.html");
	like( $hapctl, qr{<a class="Xr" href="\./openhapd\.8\.html">},
		'.Xr openhapd 8 links to the local page' );
	like( $hapctl, qr{<a class="Xr" href="https://man\.openbsd\.org/rc\.8">},
		'.Xr rc 8 leaves for man.openbsd.org' );

	# Sibling module manuals cross-link, which only works because the
	# staging directory holds them under their FuguLib:: names
	my $daemon = slurp("$OUT/FuguLib::Daemon.3p.html");
	like( $daemon, qr{<a class="Xr" href="\./FuguLib::State\.3p\.html">},
		'.Xr FuguLib::State 3p links to the local page' );

	# A relative URL whose first segment holds a colon is read as a
	# scheme, so links to module manuals must keep their './'
	for my $page (@PAGES) {
		my @hrefs = slurp("$OUT/$page") =~ m{href="([^"]+)"}g;
		my @bad   = grep {
			/^[A-Za-z][A-Za-z0-9.+-]*:/
			    && !m{^(?:https?|mailto):}
		} @hrefs;
		is( scalar @bad, 0, "$page: no link reads as a URL scheme" )
		    or diag "offenders: @bad";
	}

	# No cross-reference may dangle either way
	for my $page ( sort values %MANUAL ) {
		my @xrefs = slurp("$OUT/$page")
		    =~ m{<a class="Xr" href="([^"]+)"}g;
		for my $xref (@xrefs) {
			next if $xref =~ m{^https://man\.openbsd\.org/};
			ok( -e "$OUT/$xref",
				"$page: local .Xr $xref resolves" );
		}
	}
}

# Every page must be reachable by following links from the front page.
# 404.html is the exception: the host serves it for unknown paths.
{
	my %seen  = ( 'index.html' => 1 );
	my @queue = ('index.html');

	while ( my $page = shift @queue ) {
		next unless $page =~ /\.html$/;

		my $html = slurp("$OUT/$page");
		for my $ref ( $html =~ m{(?:href|src)="([^"]+)"}g ) {
			next if $ref =~ m{^[a-z]+:};

			my ($path) = split /#/, $ref, 2;
			next unless length $path;
			$path =~ s{^\./}{};

			next if $seen{$path}++;
			push @queue, $path;
		}
	}

	for my $page ( grep { $_ ne '404.html' } @PAGES ) {
		ok( $seen{$page}, "$page is reachable from index.html" );
	}
}

# The output directory holds the site and nothing else: no staging
# directory, no editor backups, no stray sources
{
	opendir my $dh, $OUT or die "Cannot read $OUT: $!";
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;

	my %expected   = map  { $_ => 1 } @PAGES, @ASSETS;
	my @unexpected = grep { !$expected{$_} } sort @entries;

	is( scalar @unexpected, 0, 'output holds only the site' )
	    or diag "unexpected: @unexpected";
}

# External links are collected and reported, never fetched: the build and
# its tests touch no network
{
	my %external;
	for my $page (@PAGES) {
		for my $ref ( slurp("$OUT/$page") =~ m{href="([^"]+)"}g ) {
			$external{$ref} = 1 if $ref =~ m{^https?://};
		}
	}
	note("external link: $_") for sort keys %external;
	ok( scalar keys %external, 'the site links outward at all' );
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
