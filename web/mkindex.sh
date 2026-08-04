#!/bin/sh
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
#
# Emit the body of manuals.html from manual sources.  The groups follow
# the source directories, which is already how the tree is organized.
# Thus the index cannot drift when you add manuals.
# Usage: mkindex.sh <manpage|podfile>...

set -eu

[ $# -gt 0 ] || { echo "usage: mkindex.sh <manpage|podfile>..." >&2; exit 1; }

# describe <path>
#	Print the one-line description: the .Nd macro of an mdoc page,
#	or the "Module - description" line of a POD =head1 NAME block.
#	This script never retypes the text.  The source page is the
#	only copy.
describe()
{
	case $1 in
	*.pod)
		awk '/^=head1 NAME/ { in_name = 1; next }
		     in_name && NF {
			sub(/^[^ ]+[ ]+-[ ]+/, "")
			gsub(/&/, "\\&amp;")
			gsub(/</, "\\&lt;")
			print
			exit
		     }' "$1"
		;;
	*)
		awk '/^\.Nd / {
			sub(/^\.Nd[ ]+/, "")
			gsub(/&/, "\\&amp;")
			gsub(/</, "\\&lt;")
			print
			exit
		     }' "$1"
		;;
	esac
}

# manual_name <path> <namespace>
#	An mdoc page takes its name from the file name, with the
#	group's module namespace as a prefix if the group has one.  A
#	POD sidecar takes its name from the path under lib/, so
#	lib/App/OpenHAP/Tasmota/Heater.pod is App::OpenHAP::Tasmota::Heater.
manual_name()
{
	case $1 in
	*.pod)
		rel=${1#lib/}
		printf '%s' "${rel%.pod}" | sed 's|/|::|g'
		;;
	*)
		base=${1##*/}
		printf '%s%s' "$2" "${base%.*}"
		;;
	esac
}

# manual_section <path>
manual_section()
{
	case $1 in
	*.pod)
		printf '3p'
		;;
	*)
		base=${1##*/}
		printf '%s' "${base##*.}"
		;;
	esac
}

# emit_entry <path> <namespace>
#	The './' matters.  A page has a name such as
#	Fugu::Daemon.3p.html, and a relative URL whose first segment
#	holds a colon reads as a scheme.
emit_entry()
{
	name=$(manual_name "$1" "$2")
	section=$(manual_section "$1")

	printf '<dt><a href="./%s.%s.html">%s(%s)</a></dt>\n' \
	    "$name" "$section" "$name" "$section"
	printf '<dd>%s</dd>\n' "$(describe "$1")"
}

# emit_group <heading> <anchor> <path prefix> <namespace> <path>...
#	The function emits nothing at all when no argument belongs to
#	the group.  Thus a group that has no manuals yet leaves no
#	empty heading behind.
emit_group()
{
	heading=$1
	anchor=$2
	prefix=$3
	namespace=$4
	shift 4

	open=0
	for path
	do
		case $path in
		"$prefix"*)	;;
		*)		continue ;;
		esac

		if [ $open -eq 0 ]; then
			printf '<h2 id="%s">%s</h2>\n<dl>\n' \
			    "$anchor" "$heading"
			open=1
		fi
		emit_entry "$path" "$namespace"
	done

	if [ $open -eq 1 ]; then
		printf '</dl>\n\n'
	fi
}

cat <<'EOF'
<h1>Manuals</h1>

<p>These pages come from the same sources that <code>man</code> reads on an
installed system.  Cross-references between these pages are links; all
other cross-references go to
<a href="https://man.openbsd.org/">man.openbsd.org</a>.</p>

EOF

emit_group 'OpenHAP' openhap man/openhap/ '' "$@"
emit_group 'FuguVM' fuguvm man/fuguvm/ '' "$@"
emit_group 'Fugu' fugu man/fugu/ 'Fugu::' "$@"
emit_group 'OpenHAP modules' modules lib/App/OpenHAP/ '' "$@"
emit_group 'Protocol modules' protocol-modules lib/Protocol/ '' "$@"
emit_group 'FuguVM modules' vm-modules lib/App/FuguVM/ '' "$@"
