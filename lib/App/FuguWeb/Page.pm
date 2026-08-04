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

package App::FuguWeb::Page;

use App::FuguWeb;
use Fugu::File;

# App::FuguWeb::Page - the shared chrome around one body fragment.
#
# Every source format is reduced to one HTML body fragment, and this
# module wraps it: the head, the banner, the navigation, the fragment,
# and the footer. The layout is fixed. What a project decides is the
# site name, the language, the navigation, and the footer prose.
#
# The module builds the document with string operations and not with a
# substitution over a template. A title may therefore hold any
# character. The sed template that this replaced could not take a
# slash or an ampersand.

# The two separators that are not ASCII: an em dash between the page
# title and the site name, and a middle dot between navigation
# entries. No file in the namespace carries 'use utf8', and
# Fugu::File reads and writes bytes, so the constants are the UTF-8
# bytes themselves and reach the output unchanged.
use constant {
	EM_DASH    => "\xe2\x80\x94",
	MIDDLE_DOT => "\xc2\xb7",
};

# The base stylesheet, and the sheet that a project may add beside it.
# Both are file names in the output directory: the site is served from
# one flat directory.
use constant {
	BASE_STYLESHEET  => 'style.css',
	EXTRA_STYLESHEET => 'extra.css',
};

# The optional fragment that carries the footer prose. The text
# belongs to the project, not to the tool, so it is content in the
# source directory and not a setting.
use constant FOOTER_FRAGMENT => 'footer.body.html';

# App::FuguWeb::Page->new(%args):
#	config => $config	the site description (required)
sub new ( $class, %args )
{
	my $config = $args{config};
	die 'config parameter required'
	    unless defined $config;

	return bless { config => $config }, $class;
}

# $self->config:
#	Return the site description.
sub config ($self)
{
	return $self->{config};
}

# $self->document($title, $fragment):
#	Return the whole page as bytes. The fragment goes in
#	unchanged: it is already HTML, from a renderer or from the
#	project's own source directory.
sub document ( $self, $title, $fragment )
{
	return $self->_head($title) . ( $fragment // '' ) . $self->_foot;
}

# $self->write($path, $title, $fragment):
#	Write the page. The method returns true on success, and undef
#	with a message in the log otherwise.
sub write ( $self, $path, $title, $fragment )
{
	return Fugu::File->write( $path, $self->document( $title, $fragment ) );
}

# $self->_head($title):
#	Everything before the fragment.
sub _head ( $self, $title )
{
	my $config = $self->{config};
	my $site   = App::FuguWeb::escape_html( $config->site );

	my $html = "<!DOCTYPE html>\n";
	$html .= '<html lang="' . $config->lang . qq{">\n};
	$html .= "<head>\n";
	$html .= qq{<meta charset="utf-8">\n};
	$html .= '<meta name="viewport"'
	    . qq{ content="width=device-width, initial-scale=1">\n};
	$html .=
	      '<title>'
	    . App::FuguWeb::escape_html($title) . ' '
	    . EM_DASH
	    . " $site</title>\n";
	$html .= $self->_stylesheets;
	$html .= "</head>\n<body>\n";
	$html .=
	      '<header class="banner"><a href="'
	    . $config->entry . '">'
	    . App::FuguWeb::escape_html( $config->banner )
	    . "</a></header>\n";
	$html .= $self->_nav;
	$html .= "<hr>\n<main>\n";

	return $html;
}

# $self->_stylesheets:
#	The link elements. The base sheet ships with the tool. A
#	project sheet comes after it, so a project rule wins over the
#	rule it overrides.
sub _stylesheets ($self)
{
	my $html =
	    qq{<link rel="stylesheet" href="} . BASE_STYLESHEET . qq{">\n};

	$html .= qq{<link rel="stylesheet" href="} . EXTRA_STYLESHEET . qq{">\n}
	    if -f $self->{config}->source_path(EXTRA_STYLESHEET);

	return $html;
}

# $self->_nav:
#	The navigation. Every entry but the last carries the
#	separator, so the row does not end in a dangling dot.
sub _nav ($self)
{
	my @entries = $self->{config}->nav;
	return "" unless @entries;

	my $html = "<nav>\n";
	for my $index ( 0 .. $#entries ) {
		my $entry = $entries[$index];
		$html .=
		      '<a href="'
		    . $entry->{href} . '">'
		    . App::FuguWeb::escape_html( $entry->{label} ) . '</a>';
		$html .= ' ' . MIDDLE_DOT if $index < $#entries;
		$html .= "\n";
	}
	$html .= "</nav>\n";

	return $html;
}

# $self->_foot:
#	Everything after the fragment. A project with no footer
#	fragment gets no footer element and no rule before it: an
#	empty footer is not chrome, it is a gap.
sub _foot ($self)
{
	my $html = "</main>\n";

	my $path = $self->{config}->source_path(FOOTER_FRAGMENT);
	if ( -f $path ) {
		my $prose = Fugu::File->read($path) // '';
		$html .= "<hr>\n<footer>\n$prose</footer>\n";
	}

	$html .= "</body>\n</html>\n";

	return $html;
}

1;
