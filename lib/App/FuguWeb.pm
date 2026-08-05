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

package App::FuguWeb;

# App::FuguWeb - a static documentation site for a Perl project.
#
# The tool renders mdoc(7) manuals, POD sidecars and Markdown into one
# site. A project describes its site in .fuguwebrc and needs no build
# recipe of its own.
#
# The namespace is an application, not a library. It uses Fugu:: and
# core Perl. It never uses App::OpenHAP or App::FuguVM, and neither of
# them uses it: a sibling application is not a library.
#
# This file holds what every module in the namespace needs: the name
# of the configuration file, and the escape that guards a value on its
# way into HTML.

# The configuration file, at the project root. The name and the
# discovery match .fuguvmrc.
use constant CONFIG_FILE => '.fuguwebrc';

# escape_html($text):
#	Escape the three characters that change the meaning of HTML
#	text: the ampersand first, so an escape that the function
#	itself writes is not escaped again.
#
#	The function takes bytes and returns bytes. No file in the
#	namespace carries 'use utf8', so a multi-byte character passes
#	through untouched.
sub escape_html ($text)
{
	return '' unless defined $text;

	my $escaped = $text;
	$escaped =~ s/&/&amp;/g;
	$escaped =~ s/</&lt;/g;
	$escaped =~ s/>/&gt;/g;

	return $escaped;
}

# escape_attr($text):
#	Escape a value on its way into a double-quoted attribute. The
#	quote is the character that matters here: a value that holds
#	one ends the attribute early, and everything after it becomes
#	markup. escape_html alone does not guard an attribute.
sub escape_attr ($text)
{
	my $escaped = escape_html($text);
	$escaped =~ s/"/&quot;/g;

	return $escaped;
}

1;
