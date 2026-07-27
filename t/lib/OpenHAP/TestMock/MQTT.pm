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

# Mock MQTT client for host-side tests. Records subscriptions and
# publishes, and delivers simulated messages to matching subscription
# callbacks, including + and # wildcard patterns.

package OpenHAP::TestMock::MQTT;

sub new ($class)
{
	bless {
		subscriptions => {},
		published     => [],
		connected     => 1,
	}, $class;
}

sub is_connected ($self) { $self->{connected} }

sub subscribe ( $self, $topic, $callback )
{
	$self->{subscriptions}{$topic} = $callback;
}

sub unsubscribe ( $self, $topic )
{
	delete $self->{subscriptions}{$topic};
}

sub publish ( $self, $topic, $payload )
{
	push @{ $self->{published} }, { topic => $topic, payload => $payload };
}

sub get_subscriptions ($self) { keys %{ $self->{subscriptions} } }

sub get_published ($self) { @{ $self->{published} } }

sub clear_published ($self) { $self->{published} = [] }

sub simulate_message ( $self, $topic, $payload )
{
	for my $pattern ( keys %{ $self->{subscriptions} } ) {
		if ( _topic_matches( $pattern, $topic ) ) {
			$self->{subscriptions}{$pattern}->( $topic, $payload );
		}
	}
}

sub _topic_matches ( $pattern, $topic )
{
	return 1 if $pattern eq $topic;
	return 0 unless $pattern =~ m{[+#]};

	my @pattern_parts = split m{/}, $pattern;
	my @topic_parts   = split m{/}, $topic;

	for my $i ( 0 .. $#pattern_parts ) {
		my $p = $pattern_parts[$i];
		return 1 if $p eq '#';
		return 0 if $i > $#topic_parts;
		next     if $p eq '+';
		return 0 if $p ne $topic_parts[$i];
	}

	return @topic_parts == @pattern_parts;
}

1;
