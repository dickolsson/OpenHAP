# ex:ts=8 sw=4:
# $OpenBSD$
#
# Copyright (c) 2026 Dick Olsson <hi@senzilla.io>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use v5.36;

package App::FuguWeb::CLI;

use App::FuguWeb;
use App::FuguWeb::Check;
use App::FuguWeb::Config;
use App::FuguWeb::Index;
use App::FuguWeb::Page;
use App::FuguWeb::Site;
use File::Spec;
use Fugu::File;
use Fugu::CLI;
use Fugu::Log;

# App::FuguWeb::CLI - subcommand dispatch for fuguweb.
#
# Fugu::CLI parses and dispatches. This file holds the command table,
# the global options, and one method for each command. Nothing here
# repeats a Getopt::Long block.

# The generic exit codes come from Fugu::CLI. Only the codes that mean
# something to a site build are defined here.
use constant {
	EXIT_SUCCESS      => Fugu::CLI::EXIT_SUCCESS,
	EXIT_ERROR        => Fugu::CLI::EXIT_ERROR,
	EXIT_INVALID_ARGS => Fugu::CLI::EXIT_INVALID_ARGS,
	EXIT_CONFIG_ERROR => Fugu::CLI::EXIT_CONFIG_ERROR,

	# Scriptable: a caller that builds in a container can tell a
	# renderer that is not installed from a page that is malformed.
	EXIT_RENDER_FAILED => 4,
	EXIT_CHECK_FAILED  => 5,
	EXIT_TOOL_MISSING  => 6,
};

# The subcommands. Each entry names the method that runs it, its own
# options, and whether it runs without a loaded project.
my %COMMANDS = (
	page => {
		summary => 'Wrap a body fragment from standard input',
		usage   => '<title>',
		method  => 'cmd_page',
	},
	index => {
		summary => 'Write the body of the manual index',
		method  => 'cmd_index',
	},
	build => {
		summary => 'Render the whole site',
		usage   => '[--out <dir>]',
		options => { 'out=s' => 'the output directory' },
		method  => 'cmd_build',
	},
	clean => {
		summary => 'Remove the output directory',
		usage   => '[--out <dir>]',
		options => { 'out=s' => 'the output directory' },
		method  => 'cmd_clean',

		# clean is the command an operator reaches for when the
		# tree is in a bad state, so it must not be the one
		# command that needs the tree to be in a good state.
		# With --out it needs no description at all.
		offline => 1,
	},
	check => {
		summary => 'Check a built site',
		usage   => '[--out <dir>] [--verbose]',
		options => {
			'out=s'     => 'the output directory',
			'verbose|v' => 'also note every external link',
		},
		method => 'cmd_check',
	},
	init => {
		summary => 'Write a starter .fuguwebrc',
		usage   => '[dir]',
		method  => 'cmd_init',
		offline => 1,
	},
);

# The description that 'fuguweb init' writes. A new project gets a
# file that builds, not a file that it has to repair first.
my $STARTER = <<'RC';
# The website, built by fuguweb(1).

site       = Example
out_dir    = web/build
source_dir = web
entry      = index.html

nav "index.html" {
	label = Home
}

# Every page needs a way in, or 'fuguweb check' reports it as
# unreachable. A page that nothing links to says 'unlinked = yes'.
nav "manuals.html" {
	label = Manuals
}

page "index.html" {
	title = Home
	body  = index.body.html
}

page "manuals.html" {
	title = Manuals
	index = yes
}

# A manuals block globs its directory for the mdoc sources. A modules
# block finds the POD sidecars below its own. Never name a directory
# that holds more than one namespace.
#manuals "Manuals" {
#	dir    = man
#	anchor = manuals
#}
RC

sub new ( $class, %opts )
{
	my $mode =
	    $opts{quiet} ? Fugu::Log::MODE_QUIET : Fugu::Log::MODE_STDERR;

	return bless {
		project => $opts{project},
		quiet   => $opts{quiet} // 0,
		config  => undef,
		log     => Fugu::Log->new(
			mode  => $mode,
			level => 'info',
			ident => 'fuguweb',
		),
	}, $class;
}

sub run ( $class, @argv )
{
	# The object exists before the parse, because each command body
	# is a method on it. _prepare fills in what the global options
	# decided, once Fugu::CLI has read them.
	my $self = $class->new;

	my %commands;
	for my $name ( keys %COMMANDS ) {
		my $entry = $COMMANDS{$name};
		$commands{$name} = {
			summary => $entry->{summary},
			usage   => $entry->{usage},
			options => $entry->{options},
			run     => sub ( $cli, @args ) {
				my $failure = $self->_prepare( $cli, $entry );
				return $failure if defined $failure;

				my $method = $entry->{method};
				return $self->$method( $cli, @args );
			},
		};
	}

	my $cli = Fugu::CLI->new(
		name     => 'fuguweb',
		usage    => '[--project <dir>] [--quiet] <command> [options]',
		log      => $self->{log},
		commands => \%commands,
		options  => {
			'project=s' =>
			    'the project root (default: auto-discover)',
			'quiet|q' => 'suppress informational output',
		},
		epilogue => <<'EOF',
Examples:
  fuguweb init
  fuguweb build --out web/build
  fuguweb clean
EOF
	);

	return $cli->run(@argv);
}

# $self->_prepare($cli, $entry):
#	Apply the global options and load the site description. The
#	method returns undef when the command may run, and an exit code
#	when it may not.
sub _prepare ( $self, $cli, $entry )
{
	$self->{project} = $cli->option('project');

	if ( $cli->option('quiet') ) {
		$self->{quiet} = 1;
		$self->{log}   = Fugu::Log->new(
			mode  => Fugu::Log::MODE_QUIET,
			ident => 'fuguweb',
		);
	}

	return if $entry->{offline};

	return $self->_load_config;
}

# $self->_load_config:
#	Load the site description. The method returns undef when the
#	command may run, and an exit code when it may not.
sub _load_config ($self)
{
	my $config = App::FuguWeb::Config->load(
		root  => $self->{project},
		error => \my $reason,
	);
	unless ($config) {
		$self->{log}->error( '%s', $reason );
		return EXIT_CONFIG_ERROR;
	}
	$self->{config} = $config;

	return;
}

# Wrap a body fragment from standard input in the shared chrome
sub cmd_page ( $self, $cli, @args )
{
	my $title = shift @args;
	unless ( defined $title && length $title ) {
		return $cli->command_usage_error('page');
	}

	binmode STDIN;
	binmode STDOUT;
	my $fragment = do { local $/; <STDIN> };

	my $page = App::FuguWeb::Page->new( config => $self->{config} );
	print $page->document( $title, $fragment );

	return EXIT_SUCCESS;
}

# Write the body fragment of the manual index
sub cmd_index ( $self, $cli, @args )
{
	binmode STDOUT;
	my $index = App::FuguWeb::Index->new( config => $self->{config} );
	print $index->body;

	return EXIT_SUCCESS;
}

# Render the whole site
sub cmd_build ( $self, $cli, @args )
{
	my $site = $self->_site($cli);

	my $missing = $site->missing_tool;
	if ( defined $missing ) {
		$self->{log}->error(
			"%s not found; the build needs it. Run"
			    . " 'make deps-develop'",
			$missing
		);
		return EXIT_TOOL_MISSING;
	}

	return $site->build ? EXIT_SUCCESS : EXIT_RENDER_FAILED;
}

# Remove the output directory
sub cmd_clean ( $self, $cli, @args )
{
	# Without --out only the description knows where the site is,
	# so that is the one case where clean has to load it.
	unless ( defined $cli->option('out') ) {
		my $failure = $self->_load_config;
		return $failure if defined $failure;
	}

	$self->{config} //= App::FuguWeb::Config->anonymous( $self->{project}
		    // File::Spec->curdir );

	return $self->_site($cli)->clean ? EXIT_SUCCESS : EXIT_ERROR;
}

# Check a built site
sub cmd_check ( $self, $cli, @args )
{
	my $check = App::FuguWeb::Check->new(
		config => $self->{config},
		out    => $self->_out($cli),
	);

	my @problems = $check->run;

	# The checks touch no network, so an external link is a note
	# and never a problem.
	if ( $cli->option('verbose') ) {
		$self->{log}->info( 'external link: %s', $_ )
		    for $check->external;
	}

	return EXIT_SUCCESS unless @problems;

	$self->{log}->error( '%s', $_ ) for @problems;

	return EXIT_CHECK_FAILED;
}

# Write a starter description into a directory that holds none
sub cmd_init ( $self, $cli, @args )
{
	my $dir  = shift(@args) // '.';
	my $path = "$dir/" . App::FuguWeb::CONFIG_FILE;

	unless ( -d $dir ) {
		$self->{log}->error( 'Not a directory: %s', $dir );
		return EXIT_ERROR;
	}
	if ( -e $path ) {
		$self->{log}->error( 'Already exists: %s', $path );
		return EXIT_ERROR;
	}

	Fugu::File->write( $path, $STARTER ) or return EXIT_ERROR;
	$self->{log}->info( 'Wrote %s', $path );

	return EXIT_SUCCESS;
}

# $self->_site($cli):
#	The site over the loaded description, with --out applied.
sub _site ( $self, $cli )
{
	return App::FuguWeb::Site->new(
		config => $self->{config},
		log    => $self->{log},
		out    => $self->_out($cli),
	);
}

# $self->_out($cli):
#	The output directory. A relative --out is resolved against the
#	project root, exactly as the out_dir setting it overrides is,
#	so the same value means the same directory from any working
#	directory.
sub _out ( $self, $cli )
{
	my $out  = $cli->option('out') // $self->{config}->out_dir;
	my $root = $self->{config}->root;

	return $out =~ m{^/} ? $out : "$root/$out";
}

1;
