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
use App::FuguWeb::Config;
use App::FuguWeb::Page;
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
);

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
  fuguweb page 'Install' < install.html
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

1;
