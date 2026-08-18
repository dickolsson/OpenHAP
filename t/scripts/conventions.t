#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Guards for scripts/ that no single script's own test would catch
#
# Names in scripts/ carry no extension. Thus only the shebang says
# what language a file is in. Several call sites invoke them as bare
# paths: the Makefile, vm-up, vm-provision, Image.pm. A lost exec bit
# or a broken shebang thus fails at use, not at build.

use v5.36;
use Test::More;
use FindBin qw($RealBin);

my $dir = "$RealBin/../../scripts";

# Named, not globbed: a script that disappears must fail here. The
# list must not shrink silently.
my @scripts =
    qw(deps deps-key dist ftp integration spec-coverage vm-provision vm-up);

for my $name (@scripts) {
	my $path = "$dir/$name";

	ok( -f $path, "scripts/$name exists" ) or next;
	ok( -x $path, "scripts/$name is executable" );

	open my $fh, '<', $path or do {
		fail("scripts/$name is readable");
		next;
	};
	my $shebang = <$fh>;
	close $fh;

	like( $shebang, qr{\A\#!\S*/(?:env )?(?:sh|perl)\b},
		"scripts/$name has an sh or perl shebang" );
}

# Every Perl script compiles. make lint and make tidy already read
# them, but neither runs the compiler. CI's perl -cw sweep covers only
# lib/ and bin/.
for my $name (@scripts) {
	my $path = "$dir/$name";
	next unless -f $path;

	open my $fh, '<', $path or next;
	my $shebang = <$fh>;
	close $fh;
	next unless $shebang =~ /perl/;

	my $output = `$^X -c "$path" 2>&1`;
	is( $? >> 8, 0, "scripts/$name compiles" ) or diag($output);
}

# Nothing under scripts/ regained an extension or an underscore
{
	opendir my $dh, $dir or die "opendir $dir: $!";
	my @found = sort grep { !/\A\.\.?\z/ } readdir $dh;
	closedir $dh;

	is_deeply( \@found, [ sort @scripts ],
		'scripts/ holds exactly the expected files' );

	my @odd = grep { /[_.]/ } @found;
	is_deeply( \@odd, [], 'no script name has an underscore or extension' );
}

done_testing();
