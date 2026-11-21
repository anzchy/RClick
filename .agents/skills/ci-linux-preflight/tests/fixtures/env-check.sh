#!/bin/sh
[ "${RCLICK_PREFLIGHT_FIXTURE_WARMUP:-}" != 1 ] || exit 0
if [ "${FAKE_ENV_CHECK_FAIL:-}" = 1 ]; then echo "fixture environment mismatch" >&2; exit 1; fi
exit 0
