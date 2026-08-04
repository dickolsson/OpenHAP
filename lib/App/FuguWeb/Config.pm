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

package App::FuguWeb::Config;

use App::FuguWeb;
use Fugu::Config;

# App::FuguWeb::Config - the site description over Fugu::Config.
#
# The grammar, the quoting and the yes/no spellings come from
# Fugu::Config. This file holds what is true of a site: the settings
# and their defaults, the ordered navigation, the ordered pages, and
# the rules that a description must obey before a build reads it.
#
# The object is immutable once loaded. Two sites in one process
# therefore share nothing.

# The settings that a project may leave out, and what they mean when
# it does. 'site' has no default: a site with no name is a mistake,
# not a default.
use constant {
	DEFAULT_LANG        => 'en',
	DEFAULT_OUT_DIR     => 'web/build',
	DEFAULT_SOURCE_DIR  => 'web',
	DEFAULT_ENTRY       => 'index.html',
	DEFAULT_MODULE_ROOT => 'lib',
	DEFAULT_MANDOC_OS   => 'OpenBSD',
	DEFAULT_MAN_URL     => 'https://man.openbsd.org/',
	DEFAULT_POD_CENTER  => 'Perl Library Manual',
	DEFAULT_POD_RELEASE => 'OpenBSD',
};

# The settings that name a path inside the project. Each one is
# checked for a parent-directory step, because a build must write
# inside the project and read inside it.
my @PATH_SETTINGS = qw(out_dir source_dir module_root stylesheet);

# The three ways a page block names its content. Exactly one of them
# must appear.
my @PAGE_SOURCES = qw(body markdown index);

# App::FuguWeb::Config->load(%args):
#	root  => $dir		the project root (default: discover)
#	error => \$reason	where the failure message goes
#
#	Read and validate the description. The method returns the
#	object, or undef with the reason in $reason. Every message
#	names the file, and the block when a block is at fault.
#
#	The reason travels through a reference because the object that
#	would hold it does not exist when the load fails. The module
#	keeps no package state for it: two sites in one process must
#	not share a failure.
sub load ( $class, %args )
{
	my $reason = $args{error} // \my $ignored;

	my $root = $args{root}
	    // Fugu::Config->find_project_root(App::FuguWeb::CONFIG_FILE);
	unless ( defined $root ) {
		$$reason =
		      'Not in a FuguWeb project: no '
		    . App::FuguWeb::CONFIG_FILE
		    . ' above the working'
		    . " directory. Run 'fuguweb init' first.";
		return;
	}

	my $path = "$root/" . App::FuguWeb::CONFIG_FILE;
	unless ( -f $path ) {
		$$reason = "Cannot read $path: no such file";
		return;
	}

	my $file = Fugu::Config->new( file => $path );
	unless ( $file->load ) {
		$$reason = $file->error;
		return;
	}

	my $self = bless {
		root => $root,
		path => $path,
		file => $file,
		nav  => [],
		page => [],
	}, $class;

	$self->_apply_settings;
	$self->_read_nav($reason)    or return;
	$self->_read_pages($reason)  or return;
	$self->_check_paths($reason) or return;

	return $self;
}

# $self->root, $self->path:
#	The project root, and the description that this object read.
sub root ($self) { return $self->{root}; }
sub path ($self) { return $self->{path}; }

# The settings. Each one is a plain accessor over the merged value, so
# a caller never repeats a default.
sub site        ($self) { return $self->{site}; }
sub banner      ($self) { return $self->{banner}; }
sub lang        ($self) { return $self->{lang}; }
sub out_dir     ($self) { return $self->{out_dir}; }
sub source_dir  ($self) { return $self->{source_dir}; }
sub entry       ($self) { return $self->{entry}; }
sub module_root ($self) { return $self->{module_root}; }
sub pod_center  ($self) { return $self->{pod_center}; }
sub pod_release ($self) { return $self->{pod_release}; }
sub mandoc_os   ($self) { return $self->{mandoc_os}; }
sub man_url     ($self) { return $self->{man_url}; }
sub stylesheet  ($self) { return $self->{stylesheet}; }

# $self->source_path($name):
#	The path of a file in the source directory, or of the
#	directory itself when the caller names nothing.
sub source_path ( $self, $name = undef )
{
	my $dir = "$self->{root}/$self->{source_dir}";

	return defined $name ? "$dir/$name" : $dir;
}

# $self->nav:
#	The navigation, in file order. Each entry is a hashref with
#	href and label.
sub nav ($self)
{
	return @{ $self->{nav} };
}

# $self->pages:
#	The pages, in file order. Each entry is a hashref with file,
#	title, source, value and unlinked. The source is one of body,
#	markdown or index, and the value is what that source names.
sub pages ($self)
{
	return @{ $self->{page} };
}

# $self->_apply_settings:
#	Copy each setting out of the parse, with its default.
sub _apply_settings ($self)
{
	my $file = $self->{file};

	$self->{site}        = $file->get('site');
	$self->{banner}      = $file->get( 'banner',      $self->{site} );
	$self->{lang}        = $file->get( 'lang',        DEFAULT_LANG );
	$self->{out_dir}     = $file->get( 'out_dir',     DEFAULT_OUT_DIR );
	$self->{source_dir}  = $file->get( 'source_dir',  DEFAULT_SOURCE_DIR );
	$self->{entry}       = $file->get( 'entry',       DEFAULT_ENTRY );
	$self->{module_root} = $file->get( 'module_root', DEFAULT_MODULE_ROOT );
	$self->{pod_center}  = $file->get( 'pod_center',  DEFAULT_POD_CENTER );
	$self->{pod_release} = $file->get( 'pod_release', DEFAULT_POD_RELEASE );
	$self->{mandoc_os}   = $file->get( 'mandoc_os',   DEFAULT_MANDOC_OS );
	$self->{man_url}     = $file->get( 'man_url',     DEFAULT_MAN_URL );
	$self->{stylesheet}  = $file->get('stylesheet');

	return $self;
}

# $self->_read_nav($reason):
#	Collect the nav blocks in file order.
sub _read_nav ( $self, $reason )
{
	for my $block ( $self->{file}->blocks('nav') ) {
		my $href  = $block->{name};
		my $label = $block->{settings}{label};
		unless ( defined $label && length $label ) {
			return $self->_fail( $reason,
				"nav \"$href\" has no label" );
		}

		push @{ $self->{nav} }, { href => $href, label => $label };
	}

	return $self;
}

# $self->_read_pages($reason):
#	Collect the page blocks in file order. A block names exactly
#	one source, and no two blocks name the same output file.
sub _read_pages ( $self, $reason )
{
	my %seen;

	for my $block ( $self->{file}->blocks('page') ) {
		my $name     = $block->{name};
		my $settings = $block->{settings};

		my @named = grep { defined $settings->{$_} } @PAGE_SOURCES;
		unless ( @named == 1 ) {
			my $what =
			    @named
			    ? 'names ' . join ' and ', @named
			    : 'names no source (body, markdown or index)';
			return $self->_fail( $reason, "page \"$name\" $what" );
		}
		if ( $seen{$name}++ ) {
			return $self->_fail( $reason,
				"page \"$name\" is declared twice" );
		}

		my $source = $named[0];
		my $value  = $settings->{$source};
		if ( $source eq 'index' ) {
			unless ( $self->{file}->parse_bool( $value, 0 ) ) {
				return $self->_fail( $reason,
					      "page \"$name\" sets index to"
					    . " $value; the index source"
					    . ' needs yes' );
			}
			$value = undef;
		}
		elsif ( _has_parent_step($value) ) {
			return $self->_fail( $reason,
				      "page \"$name\" $source names $value,"
				    . ' which leaves the project' );
		}

		push @{ $self->{page} },
		    {
			file     => $name,
			title    => $settings->{title} // $name,
			source   => $source,
			value    => $value,
			unlinked => $self->{file}
			    ->parse_bool( $settings->{unlinked}, 0 ),
		    };
	}

	return $self;
}

# $self->_check_paths($reason):
#	Refuse a path setting that steps out of the project. A build
#	writes inside the output directory and reads inside the
#	checkout; a '..' in a setting breaks both promises at once.
sub _check_paths ( $self, $reason )
{
	unless ( defined $self->{site} && length $self->{site} ) {
		return $self->_fail( $reason, 'no site setting' );
	}

	for my $key (@PATH_SETTINGS) {
		next unless _has_parent_step( $self->{$key} );
		return $self->_fail( $reason,
			"$key is $self->{$key}, which leaves the project" );
	}

	return $self;
}

# _has_parent_step($path):
#	Report whether a path holds a '..' component. A name that only
#	starts with two dots, such as '..config', is not a step out.
sub _has_parent_step ($path)
{
	return 0 unless defined $path;

	return scalar grep { $_ eq '..' } split m{/}, $path;
}

# $self->_fail($reason, $message):
#	Record the reason, with the file that is at fault, and return
#	undef.
sub _fail ( $self, $reason, $message )
{
	$$reason = "$self->{path}: $message";

	return;
}

1;
