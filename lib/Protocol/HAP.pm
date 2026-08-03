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

package Protocol::HAP;

# Protocol::HAP - the HomeKit Accessory Protocol as a library.
#
# The namespace holds the complete protocol: the TLV8 and HTTP codecs,
# the crypto primitives, SRP-6a, the pairing and session state
# machines, the accessory data model, the sans-IO accessory-server
# engine, and a controller. It is self-contained: core Perl plus the
# declared Crypt::* modules, and nothing else. The host owns sockets,
# timers, logging, and persistence, injected through narrow contracts.
#
# This module is the umbrella. It holds the null logger, the default
# for every class that takes a logger argument. See Protocol/HAP.pod
# for the host contracts.

# $class->null_logger:
#	Return the shared null logger instance. Every message
#	disappears. A class that takes no logger argument uses it.
sub null_logger ($)
{
	state $null = bless {}, 'Protocol::HAP::Log::Null';
	return $null;
}

package Protocol::HAP::Log::Null;

# The null logger. It answers the four methods of the logger contract
# and drops every message. The host injects a real logger to see them.

sub debug   ( $, @ ) { return }
sub info    ( $, @ ) { return }
sub warning ( $, @ ) { return }
sub error   ( $, @ ) { return }

1;
