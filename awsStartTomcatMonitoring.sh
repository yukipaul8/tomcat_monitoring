#!/bin/bash

# Main loop to continuously execute the script
while true; do
    # Your script logic goes here

    # For example, execute your main script command
    ./awsTomcatStatus.sh

    # Optionally, add a delay before restarting the script
    sleep 60s  # Sleep for 60 seconds before restarting the script
done

