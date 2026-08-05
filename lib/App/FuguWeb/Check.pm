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

package App::FuguWeb::Check;

use App::FuguWeb;
use Fugu::File;

# App::FuguWeb::Check - what a built site must be true of.
#
# The checks are generic, so every project that uses the tool gets
# them. A project keeps only the assertions that are about its own
# content.
#
# The class never fetches a link. It collects the external ones and
# reports them, because the build and its checks touch no network.

# The placeholder that a template-driven chrome substitutes. A page
# that still carries it was never substituted.
use constant TITLE_PLACEHOLDER => '@TITLE@';

# The elements that mark text as literal code. A page that documents
# the placeholder shows it inside one of them, and that page is not a
# broken page. lowdown writes <code>; mandoc writes the second form
# for a .Ql or a POD C<>.
my @LITERAL =
    ( qr{<code\b[^>]*>.*?</code>}s, qr{<span class="Li">.*?</span>}s );

# App::FuguWeb::Check->new(%args):
#	config => $config	the site description (required)
#	out    => $dir		the built site (default: out_dir)
sub new ( $class, %args )
{
	my $config = $args{config};
	die 'config parameter required'
	    unless defined $config;

	return bless {
		config => $config,
		out => $args{out} // ( $config->root . '/' . $config->out_dir ),
		external => {},
	}, $class;
}

# $self->config, $self->out:
#	The site description and the directory that holds the site.
sub config ($self) { return $self->{config}; }
sub out    ($self) { return $self->{out}; }

# $self->pages:
#	Every page that the site must hold, in a stable order: the
#	pages of the description, then one page for each manual.
sub pages ($self)
{
	return ( map { $_->{file} } $self->{config}->pages ),
	    ( map { $_->page } map { $_->manuals } $self->{config}->groups );
}

# $self->assets:
#	Every file that the site must hold beside its pages.
sub assets ($self)
{
	return 'style.css', $self->{config}->assets;
}

# $self->external:
#	The external links that the last run collected, sorted. The
#	class never fetches one.
sub external ($self)
{
	return sort keys %{ $self->{external} };
}

# $self->run:
#	Check the site and return the problems, each one a sentence
#	that names the page. An empty list means the site is good.
sub run ($self)
{
	$self->{external} = {};

	my @problems = $self->_check_inventory;

	for my $page ( $self->pages ) {
		next unless -f $self->{out} . "/$page";
		push @problems, $self->_check_page($page);
	}
	push @problems, $self->_check_reachable;

	return @problems;
}

# $self->_check_inventory:
#	Every page and asset exists and is not empty, and the output
#	holds nothing else: no staging directory, no editor backup, no
#	stray source.
sub _check_inventory ($self)
{
	my @problems;

	unless ( -d $self->{out} ) {
		return "$self->{out}: the site is not built";
	}

	my @expected = ( $self->pages, $self->assets );
	for my $name (@expected) {
		my $path = $self->{out} . "/$name";
		push @problems, "$name: missing from the output"
		    unless -e $path;
		push @problems, "$name: empty" if -e $path && !-s $path;
	}

	opendir my $dh, $self->{out} or do {
		return "$self->{out}: cannot read the output directory: $!";
	};
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;

	my %expected = map { $_ => 1 } @expected;
	push @problems, "$_: in the output but not in the site"
	    for grep { !$expected{$_} } sort @entries;

	return @problems;
}

# $self->_check_page($page):
#	Everything that one page must be true of.
sub _check_page ( $self, $page )
{
	my $html = Fugu::File->read( $self->{out} . "/$page" ) // '';
	my @problems;

	my ($title) = $html =~ m{<title>([^<]*)</title>};
	push @problems, "$page: has no title"
	    unless defined $title && length $title;

	# The whole page, not the title alone: a project writes its own
	# body fragments, and a placeholder that reached one is as
	# unsubstituted as one in the chrome.
	push @problems, "$page: holds an unsubstituted " . TITLE_PLACEHOLDER
	    if index( _without_literals($html), TITLE_PLACEHOLDER ) >= 0;

	for my $entry ( $self->{config}->nav ) {
		my $href = $entry->{href};

		# The chrome escapes an attribute on its way out, so the
		# search has to escape it the same way.
		my $written = App::FuguWeb::escape_attr($href);
		push @problems,
		    "$page: does not carry the navigation" . " entry $href"
		    unless index( $html, qq{href="$written"} ) >= 0;
	}

	push @problems, $self->_check_references( $page, $html );
	push @problems, $self->_check_xrefs( $page, $html );

	return @problems;
}

# $self->_check_references($page, $html):
#	Every href and src of one page.
sub _check_references ( $self, $page, $html )
{
	my @problems;

	for my $ref ( map { _unescape($_) }
		$html =~ m{(?:href|src)="([^"]+)"}g )
	{

		# The host may serve the site from a path below the
		# root, where a leading slash leaves the site entirely.
		if ( $ref =~ m{^/} ) {
			push @problems, "$page: $ref is root-absolute";
			next;
		}
		if ( $ref =~ m{^file:}i ) {
			push @problems, "$page: $ref is a file: URL";
			next;
		}
		if ( $ref =~ m{^https?://} ) {
			$self->{external}{$ref} = 1;
			next;
		}
		next if $ref =~ m{^(?:mailto|news|ftp):}i;

		# A browser reads a relative URL whose first segment
		# holds a colon as a scheme, so a page named
		# Fugu::Daemon.3p.html needs its './'.
		if ( $ref =~ /^[A-Za-z][A-Za-z0-9.+-]*:/ ) {
			push @problems, "$page: $ref reads as a URL scheme;"
			    . ' a local link needs its ./';
			next;
		}

		my ( $path, $fragment ) = split /#/, $ref, 2;
		$path = $page unless defined $path && length $path;
		$path =~ s{^\./}{};

		unless ( -e $self->{out} . "/$path" ) {
			push @problems, "$page: $ref leads nowhere";
			next;
		}
		next unless defined $fragment && length $fragment;

		my $target = Fugu::File->read( $self->{out} . "/$path" ) // '';
		push @problems, "$page: $ref has no such anchor"
		    unless $target =~ /\bid="\Q$fragment\E"/;
	}

	return @problems;
}

# _without_literals($html):
#	The page with every literal-code element removed. A page that
#	documents a placeholder is not a page that failed to
#	substitute one.
sub _without_literals ($html)
{
	my $text = $html;
	$text =~ s/$_//g for @LITERAL;

	return $text;
}

# _unescape($text):
#	Turn the four attribute entities back into their characters. A
#	reference is compared against a file name, and the file holds
#	the character and not the entity.
sub _unescape ($text)
{
	my $plain = $text;
	$plain =~ s/&lt;/</g;
	$plain =~ s/&gt;/>/g;
	$plain =~ s/&quot;/"/g;
	$plain =~ s/&amp;/&/g;

	return $plain;
}

# $self->_check_xrefs($page, $html):
#	A manual cross-reference that mandoc made local must resolve.
#	One that left for the manual host is not this tool's business.
sub _check_xrefs ( $self, $page, $html )
{
	my @problems;

	for my $xref ( map { _unescape($_) }
		$html =~ m{<a class="Xr" href="([^"]+)"}g )
	{
		next if $xref =~ m{^[a-z]+://};

		my $path = $xref =~ s{^\./}{}r;
		push @problems, "$page: the cross-reference $xref dangles"
		    unless -e $self->{out} . "/$path";
	}

	return @problems;
}

# $self->_check_reachable:
#	Every page is reachable from the entry page. A page that no
#	other page links to declares itself unlinked, as a 404 page
#	does: the host serves that one for an unknown path.
sub _check_reachable ($self)
{
	my $entry = $self->{config}->entry;
	return "$entry: the entry page is missing"
	    unless -f $self->{out} . "/$entry";

	my %seen  = ( $entry => 1 );
	my @queue = ($entry);

	while ( my $page = shift @queue ) {
		next unless $page =~ /\.html$/;

		my $html = Fugu::File->read( $self->{out} . "/$page" ) // '';
		for my $ref ( map { _unescape($_) }
			$html =~ m{(?:href|src)="([^"]+)"}g )
		{
			next if $ref =~ m{^[A-Za-z][A-Za-z0-9.+-]*:};

			my ($path) = split /#/, $ref, 2;
			next unless defined $path && length $path;
			$path =~ s{^\./}{};

			next if $seen{$path}++;
			push @queue, $path;
		}
	}

	my %unlinked = map { $_->{file} => 1 }
	    grep { $_->{unlinked} } $self->{config}->pages;

	return map { "$_: no page links to it" }
	    grep { !$seen{$_} && !$unlinked{$_} } $self->pages;
}

1;
