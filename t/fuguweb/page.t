#!/usr/bin/env perl
# ex:ts=8 sw=4:
# App::FuguWeb::Page: the chrome, the two byte separators, the
# escaping, and the two optional files.
#
# The test builds each site in a File::Temp directory. It never reads
# the repository, so a change to web/ cannot break it.

use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use_ok('App::FuguWeb::Config');
use_ok('App::FuguWeb::Page');

# site($rc, %files):
#	Build a project with the description $rc and the named files
#	in its source directory. Return the loaded configuration.
sub site ( $rc, %files )
{
	my $root = tempdir( CLEANUP => 1 );
	open my $fh, '>', "$root/.fuguwebrc"
	    or die "Cannot write the description: $!";
	print {$fh} $rc;
	close $fh;

	make_path("$root/web");
	for my $name ( sort keys %files ) {
		open my $out, '>', "$root/web/$name"
		    or die "Cannot write $name: $!";
		print {$out} $files{$name};
		close $out;
	}

	my $config =
	    App::FuguWeb::Config->load( root => $root, error => \my $reason );
	die "$reason\n" unless $config;

	return $config;
}

my $RC = <<'RC';
site = Example

nav "index.html" {
	label = Home
}

nav "manuals.html" {
	label = Manuals
}
RC

subtest 'the whole chrome, in order' => sub {
	my $page = App::FuguWeb::Page->new( config => site($RC) );
	my $html = $page->document( 'Install', "<h1>Install</h1>\n" );

	my $expected = <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install \xe2\x80\x94 Example</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<header class="banner"><a href="index.html">Example</a></header>
<nav>
<a href="index.html">Home</a> \xc2\xb7
<a href="manuals.html">Manuals</a>
</nav>
<hr>
<main>
<h1>Install</h1>
</main>
</body>
</html>
HTML

	is( $html, $expected, 'the document is byte for byte the chrome' );
};

subtest 'the two separators are the UTF-8 bytes' => sub {
	is( App::FuguWeb::Page::EM_DASH(),    "\xe2\x80\x94",
		'the em dash' );
	is( App::FuguWeb::Page::MIDDLE_DOT(), "\xc2\xb7",
		'the middle dot' );

	my $page = App::FuguWeb::Page->new( config => site($RC) );
	my $html = $page->document( 'Install', '' );

	like( $html, qr/<title>Install \xe2\x80\x94 Example<\/title>/,
		'an em dash separates the title from the site' );
	like( $html, qr/<\/a> \xc2\xb7\n/,
		'a middle dot separates two navigation entries' );
	unlike( $html, qr/<\/a> \xc2\xb7\n<\/nav>/,
		'the last entry carries no separator' );
};

subtest 'the title and the labels are escaped' => sub {
	my $config = site( <<'RC' );
site = A & B

nav "index.html" {
	label = <Home>
}
RC
	my $page = App::FuguWeb::Page->new( config => $config );
	my $html = $page->document( 'Tags < & >', '' );

	like( $html, qr/<title>Tags &lt; &amp; &gt; /,
		'the title is escaped' );
	like( $html, qr/&amp; B<\/title>/, 'the site name is escaped' );
	like( $html, qr/>&lt;Home&gt;<\/a>/, 'a navigation label is escaped' );

	# The chrome that mkpage.sh replaced substituted the title with
	# sed. A slash ended the substitution and an ampersand meant
	# "the whole match", so neither could ever reach a page.
	$html = $page->document( 'openhapd.conf(5) / 8', '' );
	like( $html, qr{<title>openhapd\.conf\(5\) / 8 },
		'a title may hold a slash' );
};

subtest 'the footer fragment is optional' => sub {
	my $page = App::FuguWeb::Page->new( config => site($RC) );
	my $html = $page->document( 'Install', '' );
	unlike( $html, qr/<footer>/, 'no fragment, no footer element' );
	like( $html, qr/<\/main>\n<\/body>/, 'and no rule before one' );

	$page = App::FuguWeb::Page->new(
		config => site( $RC, 'footer.body.html' => "<p>ISC.</p>\n" ) );
	$html = $page->document( 'Install', '' );
	like( $html, qr{</main>\n<hr>\n<footer>\n<p>ISC\.</p>\n</footer>\n},
		'the fragment becomes the footer' );
};

subtest 'a project stylesheet is optional' => sub {
	my $page = App::FuguWeb::Page->new( config => site($RC) );
	my $html = $page->document( 'Install', '' );
	unlike( $html, qr/extra\.css/, 'no file, no second link' );

	$page = App::FuguWeb::Page->new(
		config => site( $RC, 'extra.css' => "body { color: red }\n" ) );
	$html = $page->document( 'Install', '' );
	my $links = qq{<link rel="stylesheet" href="style.css">\n}
	    . qq{<link rel="stylesheet" href="extra.css">\n};
	like( $html, qr/\Q$links\E/,
		'the project sheet comes after the base sheet' );
};

subtest 'write puts the same bytes on disk' => sub {
	my $config = site($RC);
	my $page   = App::FuguWeb::Page->new( config => $config );
	my $path   = $config->root . '/out.html';

	ok( $page->write( $path, 'Install', "<p>x</p>\n" ), 'write succeeds' );

	open my $fh, '<', $path or die "Cannot read $path: $!";
	binmode $fh;
	my $written = do { local $/; <$fh> };
	close $fh;

	is( $written, $page->document( 'Install', "<p>x</p>\n" ),
		'the file holds the document' );
};

done_testing();
