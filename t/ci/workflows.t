#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Guards for the workflows of a consumer repository
#
# The canonical setup-perl action lives in FuguBSD/Fugu, and this
# repository references it across repositories. Nothing under
# .github/ runs outside a runner, so the test reads the workflows as
# text and asserts the invariants that only fail in CI: that every
# reference points at the shared action, that every value it gets is
# an environment the action accepts, and that no workflow installs
# dependencies on the side.

use v5.36;
use Test::More;
use FindBin qw($RealBin);

my $workflow = "$RealBin/../../.github/workflows";

use constant ACTION => 'FuguBSD/Fugu/.github/actions/setup-perl@main';

my %ENVIRONMENTS = map { $_ => 1 } qw(runtime test develop);

# _slurp($path):
#	Whole file as text, or undef with a failed assertion.
sub _slurp ($path)
{
	open my $fh, '<', $path or do {
		fail("$path is readable");
		return;
	};
	local $/ = undef;
	my $content = <$fh>;
	close $fh;

	return $content;
}

opendir my $dh, $workflow or plan skip_all => 'no workflows';
my @files = sort grep { /\.yml\z/ } readdir $dh;
closedir $dh;

ok( scalar @files, 'workflows found' );

my $users = 0;
for my $file (@files) {
	my $text  = _slurp("$workflow/$file") // next;
	my @lines = split /\n/, $text;

	# No workflow installs dependencies itself. The shared action
	# owns the whole install, so one step per job is the rule.
	my @own = grep { m{^\s+run:.*\bmake\s+deps\b} } @lines;
	is( scalar @own, 0, "$file runs no deps target of its own" )
	    or diag( join "\n", @own );

	for my $i ( 0 .. $#lines ) {
		next unless $lines[$i] =~ m{uses:\s*(\S*setup-perl\S*)\s*$};
		my $ref = $1;
		$users++;

		is( $ref, ACTION, "$file line @{[$i + 1]} references"
			    . ' the shared action' );

		my $env;
		for my $j ( $i + 1 .. $#lines ) {
			last if $lines[$j] =~ /^\s+-\s/;
			if ( $lines[$j] =~ /^\s+dependencies:\s*"?(\w+)"?\s*$/ )
			{
				$env = $1;
				last;
			}
		}

		# To omit it is fine. That is what the default is for.
		# But a value that is not an environment is a job that
		# installs nothing.
		ok( !defined $env || exists $ENVIRONMENTS{$env},
			"$file line @{[$i + 1]}: "
			    . ( $env // '(default)' )
			    . ' is a known environment' );
	}
}

ok( $users >= 1, 'at least one workflow uses the shared action' );

# The integration cache key. hashFiles over a path that matches
# nothing returns an empty string rather than an error. Thus a renamed
# input would quietly collapse the key, not rotate it. And the inputs
# that ship inside the installed FuguVM distribution are covered by
# the resolved release tag, so the key must reference that step.
subtest 'the integration cache key covers what decides the image' => sub {
	my $root = "$RealBin/../..";
	my $text = _slurp("$workflow/integration.yml");
	ok( defined $text, 'integration.yml is readable' ) or return;

	my ($hashed) = $text =~ /hashFiles\(([^)]*)\)/s;
	ok( defined $hashed, 'the key hashes files' ) or return;

	my @paths = $hashed =~ /'([^']+)'/g;
	ok( scalar @paths, 'at least one hashed path' );
	ok( -f "$root/$_", "hashed path $_ exists" ) for @paths;

	like(
		$text,
		qr/key:\s*
?\s*fuguvm-v\d+-.*\$\{\{\s*steps\.fuguvm\.outputs\.tag\s*\}\}/s,
		'the key names the resolved FuguVM release'
	);
	like( $text, qr{releases/latest},
		'a step resolves the latest release' );
};

done_testing();
