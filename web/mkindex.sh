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
# Emit the body of manuals.html from manual sources.  Grouping is by source
# directory, which is already how the tree is organised, so the index cannot
# drift as manuals are added.
# Usage: mkindex.sh <manpage|podfile>...

set -eu

[ $# -gt 0 ] || { echo "usage: mkindex.sh <manpage|podfile>..." >&2; exit 1; }

# describe <path>
#	One-line description: the .Nd macro of an mdoc page, or the
#	"Module - description" line of a POD =head1 NAME block.  Never
#	retyped here -- the source page is the only copy.
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
#	mdoc pages take their name from the file name, prefixed by the
#	group's module namespace if it has one.  POD sidecars take theirs
#	from the path under lib/, so lib/OpenHAP/Tasmota/Heater.pod is
#	OpenHAP::Tasmota::Heater.
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
#	The './' matters: a page is named FuguLib::Daemon.3p.html, and a
#	relative URL whose first segment holds a colon reads as a scheme.
emit_entry()
{
	name=$(manual_name "$1" "$2")
	section=$(manual_section "$1")

	printf '<dt><a href="./%s.%s.html">%s(%s)</a></dt>\n' \
	    "$name" "$section" "$name" "$section"
	printf '<dd>%s</dd>\n' "$(describe "$1")"
}

# emit_group <heading> <anchor> <path prefix> <namespace> <path>...
#	Emits nothing at all when no argument belongs to the group, so a
#	group that has no manuals yet leaves no empty heading behind.
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

<p>Rendered from the same sources <code>man</code> reads on an installed
system.  Cross-references between them are links; everything else goes to
<a href="https://man.openbsd.org/">man.openbsd.org</a>.</p>

EOF

emit_group 'OpenHAP' openhap man/openhap/ '' "$@"
emit_group 'FuguVM' fuguvm man/fuguvm/ '' "$@"
emit_group 'FuguLib' fugulib man/fugulib/ 'FuguLib::' "$@"
emit_group 'OpenHAP modules' modules lib/OpenHAP/ '' "$@"
emit_group 'FuguVM modules' vm-modules lib/FuguVM/ '' "$@"
