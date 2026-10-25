#!/usr/bin/env bash
# Test double for kafka-console-producer.sh.
#
# Behaviour is selected with FAKE_KAFKA_MODE:
#   success (default) -- consume the message and succeed
#   fail              -- consume the message and fail every attempt
#   flaky             -- fail until the attempt count reaches FAKE_KAFKA_SUCCEED_ON
#   hang              -- consume the message, then block until killed (tests
#                        the timeout around the real producer)
#
# FAKE_KAFKA_LOG records the command-line arguments, FAKE_KAFKA_MESSAGES
# records the payload, and FAKE_KAFKA_COUNT_FILE tracks attempts in flaky mode.
set -euo pipefail

payload=$(cat)

if [[ -n ${FAKE_KAFKA_LOG:-} ]]; then
    printf '%s\n' "$*" >>"$FAKE_KAFKA_LOG"
fi

if [[ -n ${FAKE_KAFKA_MESSAGES:-} ]]; then
    printf '%s\n' "$payload" >>"$FAKE_KAFKA_MESSAGES"
fi

case "${FAKE_KAFKA_MODE:-success}" in
    success)
        exit 0
        ;;
    fail)
        exit 1
        ;;
    flaky)
        if [[ -z ${FAKE_KAFKA_COUNT_FILE:-} ]]; then
            echo "FAKE_KAFKA_COUNT_FILE is required in flaky mode" >&2
            exit 2
        fi
        attempts=$(cat "$FAKE_KAFKA_COUNT_FILE" 2>/dev/null || printf '0')
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" >"$FAKE_KAFKA_COUNT_FILE"
        if ((attempts >= ${FAKE_KAFKA_SUCCEED_ON:-3})); then
            exit 0
        fi
        exit 1
        ;;
    hang)
        # exec so the process that timeout(1) signals is the sleeping
        # process itself, not a bash parent that would wait for its child.
        exec sleep "${FAKE_KAFKA_HANG_SECONDS:-300}"
        ;;
    *)
        echo "unknown FAKE_KAFKA_MODE: ${FAKE_KAFKA_MODE}" >&2
        exit 2
        ;;
esac
