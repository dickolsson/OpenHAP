#!/usr/bin/env perl
# ex:ts=8 sw=4:
# Guards for .github/actions/setup-perl and the workflows that use it
#
# Nothing else in the tree checks CI wiring: a workflow that stops
# passing an environment, or a cache key that stops covering an input
# that decides what gets installed, both fail on a runner - the first as
# a job that installs the wrong dependency set, the second as a tree
# that is silently rebuilt and re-cached under a stale key on every run.
#
# Text, not YAML: a parser is not in base perl and the invariants here
# are all about which literal strings appear, not about structure - with
# one exception, the cache key, whose shell is extracted and run.  Reading
# it was not enough: interpolating the hashFiles expression straight after
# $prefix made the digest part of the variable NAME, which produced an
# empty key and failed every job at the restore step.

use v5.36;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($RealBin);

my $root     = "$RealBin/../..";
my $action   = "$root/.github/actions/setup-perl/action.yml";
my $workflow = "$root/.github/workflows";

# The environments deps/<OS>.txt names, and the make target each one
# selects. deps-develop and deps-test have their own targets; runtime is
# plain `make deps`.
my %TARGET = (
	runtime => 'deps',
	test    => 'deps-test',
	develop => 'deps-develop',
);

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

# _run_block($yml, $step_name):
#	The `run: |` script of the named step, dedented to column zero so
#	it can be handed to a shell. Undef when the step or its block is
#	not there.
sub _run_block ( $yml, $name )
{
	my @lines = split /\n/, $yml;
	my ( $seen, $indent, @block );

	for my $i ( 0 .. $#lines ) {
		$seen = 1 if $lines[$i] =~ /^\s+-\s+name:\s*\Q$name\E\s*$/;
		next unless $seen;

		# A later step begins, so the block is over
		last if @block && $lines[$i] =~ /^\s+-\s+name:/;

		if ( !defined $indent ) {
			next unless $lines[$i] =~ /^(\s+)run:\s*\|\s*$/;
			$indent = length($1) + 2;
			next;
		}

		last if length $lines[$i] && $lines[$i] !~ /^ {$indent}/;

		# A blank line inside the block is shorter than the indent
		# and carries nothing to dedent
		push @block,
		    length( $lines[$i] ) > $indent
		    ? substr( $lines[$i], $indent )
		    : '';
	}

	return if !@block;
	return join( "\n", @block ) . "\n";
}

my $yml = _slurp($action);
plan skip_all => 'no setup-perl action' unless defined $yml;

subtest 'the action takes one environment input' => sub {
	like( $yml, qr/^\s+dependencies:$/m,
		'declares a dependencies input' );
	like( $yml, qr/^\s+default:\s*"?test"?\s*$/m,
		'defaults to the test environment' );

	# Every environment resolves, and only through the input: a
	# workflow must not have to know the target names.
	for my $env ( sort keys %TARGET ) {
		like( $yml, qr/\b\Q$env\E\b/,
			"resolves the $env environment" );
	}
	like(
		$yml,
		qr/run:\s*make \$\{\{\s*steps\.\w+\.outputs\.target\s*\}\}/,
		'installs the resolved target, not a hardcoded one'
	);
	like( $yml, qr/exit 1/, 'rejects an unknown environment' );
};

subtest 'the cache key covers what decides the tree' => sub {
	# One computed key, read twice. actions/cache/save rejects a write
	# to an existing key, so a restore and a save that disagreed would
	# miss on every run and then fail to store the result - which is
	# why neither step may spell the key out for itself.
	my @refs = $yml =~ /^\s+key:\s*(.*)$/mg;
	is( scalar @refs, 2, 'a restore key and a save key' );
	is_deeply(
		[ map { s/\s+//gr } @refs ],
		[ ('${{steps.cache.outputs.key}}') x 2 ],
		'both read the same computed key'
	);
	like( $yml, qr/^\s+restore-keys:\s*\$\{\{\s*steps\.cache\.outputs\./m,
		'the fallback prefix is computed with it' );

	like( $yml, qr/prefix=\S*\$\{\{\s*inputs\.dependencies\s*\}\}/,
		'the key names the environment' );

	# The tree holds compiled XS, so it is only valid for the perl that
	# built it.
	like( $yml, qr/\$Config\{version\}/,  'the key names perl version' );
	like( $yml, qr/\$Config\{archname\}/, 'the key names the archname' );

	# Fail closed: hashFiles over a path that matches nothing returns
	# an empty string rather than an error, so a renamed input would
	# quietly collapse the key instead of rotating it.
	my ($hashed) = $yml =~ /hashFiles\(([^)]*)\)/;
	ok( defined $hashed, 'the key hashes files' ) or return;

	my @paths = $hashed =~ /'([^']+)'/g;
	ok( scalar @paths, 'at least one hashed path' );
	ok( -f "$root/$_", "hashed path $_ exists" ) for @paths;

	# The two inputs that decide which modules end up installed.
	# Anything else - the Makefile above all - changes for unrelated
	# reasons and would rebuild the tree from source each time.
	for my $want ( 'deps/Linux.txt', 'scripts/deps' ) {
		ok( scalar( grep { $_ eq $want } @paths ),
			"the key hashes $want" );
	}

	like(
		$yml,
		qr/if:\s*steps\.restore\.outputs\.cache-hit\s*!=\s*'true'/,
		'the tree is saved only on a cache miss'
	);
};

subtest 'the cache key shell actually composes a key' => sub {
	# The step is legal YAML and legal shell either way, so nothing
	# above can tell a working key from an empty one. Run it: the
	# runner interpolates the expressions before bash sees them, so do
	# the same with stand-in values and read the outputs back.
	my $shell = _run_block( $yml, 'Compute the cache key' );
	ok( defined $shell, 'the key-computing step has a shell block' )
	    or return;

	my $digest = 'd' x 64;    # what hashFiles() returns
	$shell =~ s/\$\{\{\s*inputs\.dependencies\s*\}\}/develop/g;
	$shell =~ s/\$\{\{\s*hashFiles\([^)]*\)\s*\}\}/$digest/g;
	unlike( $shell, qr/\$\{\{/, 'every expression had a stand-in' );

	my $dir = tempdir( CLEANUP => 1 );
	my $out = "$dir/output";
	open my $fh, '>', "$dir/step.sh" or die "open: $!";
	print $fh $shell;
	close $fh;
	open my $touch, '>', $out or die "open: $!";
	close $touch;

	my $log = `GITHUB_OUTPUT='$out' sh '$dir/step.sh' 2>&1`;
	is( $? >> 8, 0, 'it runs clean' ) or diag($log);

	my %got = map { /\A([^=]+)=(.*)\z/ ? ( $1 => $2 ) : () }
	    split /\n/, ( _slurp($out) // '' );

	ok( length( $got{prefix} // '' ), 'it emits a non-empty prefix' );
	ok( length( $got{key}    // '' ), 'it emits a non-empty key' );

	# The bug: $prefix followed by the digest read as one variable
	# name, so key= was empty and restore-keys= was fine - which is
	# why only the composition catches it.
	is( $got{key}, ( $got{prefix} // '' ) . $digest,
		'and the key is exactly the prefix plus the digest' );
	like( $got{prefix}, qr/-develop-/, 'the environment is in the key' );
	like( $got{prefix}, qr/\Q$]\E|perl5\./, 'so is this perl' );
};

subtest 'workflows delegate installing to the action' => sub {
	opendir my $dh, $workflow or do {
		fail('.github/workflows is readable');
		return;
	};
	my @files = sort grep { /\.yml\z/ } readdir $dh;
	closedir $dh;

	ok( scalar @files, 'workflows found' );

	my $users = 0;
	for my $file (@files) {
		my $text = _slurp("$workflow/$file") // next;
		my @lines = split /\n/, $text;

		# No workflow installs dependencies itself. That is the
		# whole point of the input: one step per job, not two,
		# and no job that forgets the second one.
		my @own = grep { m{^\s+run:.*\bmake\s+deps\b} } @lines;
		is( scalar @own, 0, "$file runs no deps target of its own" )
		    or diag( join "\n", @own );

		# Whatever a workflow does pass has to be an environment
		# the action accepts.
		for my $i ( 0 .. $#lines ) {
			next
			    unless $lines[$i] =~
			    m{uses:\s*\./\.github/actions/setup-perl\s*$};
			$users++;

			my $env;
			for my $j ( $i + 1 .. $#lines ) {
				last if $lines[$j] =~ /^\s+-\s/;
				if ( $lines[$j] =~
					/^\s+dependencies:\s*"?(\w+)"?\s*$/ )
				{
					$env = $1;
					last;
				}
			}

			# Omitting it is fine - that is what the default
			# is for - but a value that is not an environment
			# is a job that installs nothing.
			ok( !defined $env || exists $TARGET{$env},
				"$file line @{[$i + 1]}: "
				    . ( $env // '(default)' )
				    . ' is a known environment' );
		}
	}

	ok( $users >= 1, 'at least one workflow uses the action' );
};

done_testing();
