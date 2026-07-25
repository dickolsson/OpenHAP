#!/bin/sh
# ex:ts=8 sw=4:
# OpenHAP Integration Test Suite
#
# Usage: ./integration-test.sh [--fresh]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Find openhvf
OPENHVF="${PROJECT_ROOT}/bin/openhvf"
if [ ! -x "${OPENHVF}" ]; then
	echo "ERROR: openhvf not found" >&2
	exit 1
fi

# Parse arguments
FRESH=0
for arg in "$@"; do
	case "${arg}" in
		--fresh) FRESH=1 ;;
		--help|-h)
			echo "Usage: $0 [--fresh]"
			echo ""
			echo "Options:"
			echo "  --fresh    Destroy and recreate VM"
			exit 0
			;;
		*)
			echo "Unknown option: ${arg}" >&2
			exit 1
			;;
	esac
done

# Fresh install?
if [ ${FRESH} -eq 1 ]; then
	echo "==> Destroying existing VM..."
	"${OPENHVF}" destroy 2>/dev/null || true
fi

# Bring up VM (idempotent). Under TCG emulation (e.g. CI runners
# without hardware acceleration) boot and install take far longer than
# under HVF/KVM, so the wait timeout is overridable.
"${OPENHVF}" up
"${OPENHVF}" wait --timeout "${OPENHVF_WAIT_TIMEOUT:-120}"
