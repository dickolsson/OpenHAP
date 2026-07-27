#!/bin/sh
# ex:ts=8 sw=4:
# Print the provisioning key: a short digest over everything that
# determines the guest's installed dependencies.
#
# scripts/vm_up.sh restores the snapshot named after this key, and
# scripts/vm_provision.sh saves it, so both must derive it identically.
# Whatever this hashes must also be hashed into the CI cache key, or a
# change here would rotate the snapshot name without letting the runner
# persist the result.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The deps layer of vm_provision.sh only, not the whole file: the
# OpenHAP layer runs on every provision and never enters the snapshot,
# so editing it must not invalidate the cached dependencies.
# The markers sit inside an 'else' block, so they are indented: anchor
# on optional leading whitespace, not on '^#'. Matching '^#' extracted
# nothing at all, which silently dropped this input from the digest and
# left every edit to the layer unable to invalidate its cached snapshot.
deps_layer() {
	sed -n '/^[[:space:]]*# BEGIN deps layer$/,/^[[:space:]]*# END deps layer$/p' \
		"${PROJECT_ROOT}/scripts/vm_provision.sh"
}

# Fail closed: a digest over silently-missing inputs is worse than no
# digest, because it looks valid and caches a stale layer forever.
require_deps_layer() {
	if [ "$(deps_layer | wc -l)" -lt 2 ]; then
		echo "deps_key: cannot find the deps layer markers in" \
			"scripts/vm_provision.sh" >&2
		exit 1
	fi
}

digest() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256
	elif command -v cksum >/dev/null 2>&1; then
		cksum -a sha256
	else
		echo "No sha256 tool found" >&2
		exit 1
	fi
}

require_deps_layer

{
	# Named markers so a boundary shift between inputs cannot
	# silently produce the same digest
	echo "== deps/OpenBSD.txt"
	cat "${PROJECT_ROOT}/deps/OpenBSD.txt"
	echo "== scripts/deps.sh"
	cat "${PROJECT_ROOT}/scripts/deps.sh"
	echo "== cpanfile"
	[ -f "${PROJECT_ROOT}/cpanfile" ] && cat "${PROJECT_ROOT}/cpanfile"
	echo "== deps layer"
	deps_layer
} | digest | awk '{ print substr($1, 1, 12) }'
