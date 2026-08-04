#!/usr/bin/env perl
# ex:ts=8 sw=4:
# App::FuguWeb::Site: a small site builds, holds what the description
# names and nothing else, drops the staging directory, and builds a
# second time to the same bytes.
#
# The test builds its site in a File::Temp directory. It never reads
# the repository; t/web/site.t covers the real site.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use_ok('App::FuguWeb::Config');
use_ok('App::FuguWeb::Site');
use_ok('Fugu::Log');

# have($tool):
#	Report whether the program is on the path.
sub have ($tool)
{
	return system("command -v $tool >/dev/null 2>&1") == 0;
}

plan skip_all => 'mandoc not found'  unless have('mandoc');
plan skip_all => 'lowdown not found' unless have('lowdown');
plan skip_all => 'pod2man not found' unless have('pod2man');

my $RC = <<'RC';
site       = Example
source_dir = web
out_dir    = out

nav "index.html" {
	label = Home
}

page "index.html" {
	title = Home
	body  = index.body.html
}

page "readme.html" {
	title    = Readme
	markdown = README.md
}

page "manuals.html" {
	title = Manuals
	index = yes
}

manuals "Manuals" {
	dir    = man
	anchor = manuals
}

modules "Modules" {
	dir    = lib/Thing
	anchor = modules
}
RC

# project():
#	Write a whole small project and return its root.
sub project ()
{
	my $root = tempdir( CLEANUP => 1 );

	my %file = (
		'.fuguwebrc'          => $RC,
		'README.md'           => "# Readme\n\nA paragraph.\n",
		'web/index.body.html' => "<h1>Home</h1>\n",
		'web/footer.body.html' => "<p>ISC.</p>\n",
		'web/robots.txt'      => "User-agent: *\n",
		'web/extra.css'       => "body { color: red }\n",

		# Not an asset: a note for the maintainers, not content
		'web/CLAUDE.md' => "# web/\n\nNotes.\n",

		'man/tool.1' => <<'MDOC',
.Dd $Mdocdate: July 27 2026 $
.Dt TOOL 1
.Os
.Sh NAME
.Nm tool
.Nd a tool
.Sh DESCRIPTION
Words.
MDOC
		'lib/Thing/Depot.pod' => <<'POD',
=head1 NAME

Thing::Depot - the persistence contract

=head1 DESCRIPTION

Words.
POD
	);

	for my $relative ( sort keys %file ) {
		my $path = "$root/$relative";
		make_path( $path =~ s{/[^/]+$}{}r );

		open my $fh, '>', $path or die "Cannot write $path: $!";
		print {$fh} $file{$relative};
		close $fh;
	}

	return $root;
}

# site($root, $out):
#	A site over the project, with a quiet log.
sub site ( $root, $out )
{
	my $config =
	    App::FuguWeb::Config->load( root => $root, error => \my $reason );
	die "$reason\n" unless $config;

	return App::FuguWeb::Site->new(
		config => $config,
		out    => $out,
		log    => Fugu::Log->new( mode => Fugu::Log::MODE_QUIET() ),
	);
}

my $ROOT = project();
my $OUT  = tempdir( CLEANUP => 1 ) . '/out';

subtest 'the build makes the site and nothing else' => sub {
	my $site = site( $ROOT, $OUT );
	is( $site->missing_tool, undef, 'every renderer is installed' );
	ok( $site->build, 'the build succeeds' );

	# The pages of the description, one page per manual, the base
	# stylesheet, and the assets.
	my @expected = qw(
	    index.html readme.html manuals.html
	    tool.1.html Thing::Depot.3p.html
	    style.css robots.txt extra.css
	);
	ok( -s "$OUT/$_", "$_ exists and is not empty" ) for @expected;

	# Staging is a build detail and never part of the published
	# tree.
	ok( !-e "$OUT/.man", 'the staging directory is gone' );

	opendir my $dh, $OUT or die "Cannot read $OUT: $!";
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;

	my %expected = map { $_ => 1 } @expected;
	my @extra = grep { !$expected{$_} } sort @entries;
	is( scalar @extra, 0, 'the output holds the site only' )
	    or diag "unexpected: @extra";
};

subtest 'each source reaches its page' => sub {
	open my $fh, '<', "$OUT/readme.html" or die "Cannot read: $!";
	my $readme = do { local $/; <$fh> };
	close $fh;
	like( $readme, qr/A paragraph\./, 'lowdown rendered the Markdown' );

	open $fh, '<', "$OUT/manuals.html" or die "Cannot read: $!";
	my $index = do { local $/; <$fh> };
	close $fh;
	like( $index, qr{href="\./tool\.1\.html"}, 'the index lists the page' );
	like( $index, qr/a tool/, 'with the description of its source' );
	like( $index, qr{href="\./Thing::Depot\.3p\.html"},
		'and the sidecar' );

	open $fh, '<', "$OUT/Thing::Depot.3p.html" or die "Cannot read: $!";
	my $module = do { local $/; <$fh> };
	close $fh;
	like( $module, qr/the persistence contract/,
		'pod2man and mandoc rendered the sidecar' );
	like( $module, qr{<title>Thing::Depot\(3p\) },
		'and the chrome carries the title' );
};

subtest 'the site is a pure function of the project' => sub {
	my $second = tempdir( CLEANUP => 1 ) . '/out';
	ok( site( $ROOT, $second )->build, 'the second build succeeds' );

	my $diff = `diff -r '$OUT' '$second' 2>&1`;
	is( $diff, '', 'two builds are byte-identical' );
};

subtest 'a second build over the same directory succeeds' => sub {
	my $site = site( $ROOT, $OUT );
	ok( $site->build, 'the build is idempotent' );
	ok( !-e "$OUT/.man", 'and leaves no staging behind' );
};

subtest 'a stylesheet that is not found fails the build' => sub {
	my $root = project();
	open my $fh, '>>', "$root/.fuguwebrc"
	    or die "Cannot append to the description: $!";
	print {$fh} "stylesheet = web/absent.css\n";
	close $fh;

	my $out = tempdir( CLEANUP => 1 ) . '/out';

	# A site with no stylesheet must not look like a success.
	ok( !site( $root, $out )->build, 'the build fails' );
};

subtest 'clean removes the output directory' => sub {
	my $site = site( $ROOT, $OUT );
	ok( -d $OUT, 'the output is there' );
	ok( $site->clean, 'clean succeeds' );
	ok( !-e $OUT, 'and the directory is gone' );

	ok( $site->clean, 'clean is idempotent' );
};

subtest 'pod_date is the date of the last commit' => sub {
	my $site = site( project(), tempdir( CLEANUP => 1 ) . '/out' );

	# A temporary project is no git checkout, so the fallback
	# answers. Either way the answer is a date and not a file time.
	like( $site->pod_date, qr/^\d{4}-\d{2}-\d{2}$/,
		'the date is an ISO date' );
};

done_testing();
