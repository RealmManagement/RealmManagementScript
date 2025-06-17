#!/bin/bash

















TARGET_HOST=$1

TARGET_PORT=$2

ATTEMPT_COUNT=5

SUCCESS_THRESHOLD=2

TIMEOUT_PER_ATTEMPT=1


if [[ -z "$TARGET_HOST" || -z "$TARGET_PORT" ]]; then

  exit 1
fi


success_count=0


for (( i=0; i<ATTEMPT_COUNT; i++ )); do


    (timeout $TIMEOUT_PER_ATTEMPT bash -c "true &>/dev/null </dev/tcp/$TARGET_HOST/$TARGET_PORT") &>/dev/null
    

    if [[ $? -eq 0 ]]; then

        ((success_count++))
    fi
    

    sleep 0.5
done


if (( success_count >= SUCCESS_THRESHOLD )); then

  exit 0
else

  exit 1
fi
