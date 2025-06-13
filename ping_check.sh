#!/bin/bash






TARGET_HOST=$1
PACKET_COUNT=5

SUCCESS_THRESHOLD=2 

if [[ -z "$TARGET_HOST" ]]; then
  exit 1
fi


ping_output=$(ping -c $PACKET_COUNT -i 0.3 -W 1 -q "$TARGET_HOST" 2>&1)
ping_exit_code=$?


if [ $ping_exit_code -ne 0 ]; then
  exit 1
fi


received_packets=$(echo "$ping_output" | grep 'packets transmitted' | awk '{print $4}')


if ! [[ "$received_packets" =~ ^[0-9]+$ ]]; then

  exit 1
fi


if (( received_packets >= SUCCESS_THRESHOLD )); then

  exit 0
else

  exit 1
fi
