#!/bin/bash
# Verify if the host is an AWS EC2 Instance
if [ -f /sys/class/dmi/id/product_uuid ] && [ "$(head -c 3 /sys/class/dmi/id/product_uuid)" == ec2 ]; then
    echo
else
    echo
    echo "This is not an EC2 instance, or a reverse-customized one. This package is for monitoring AWS EC2 Instances only..."
    echo
    exit
fi

# Function to retrieve instance metadata with retries
retrieve_instance_metadata() {
    local metadata_url="http://169.254.169.254/latest/meta-data/$1"
    local retry_count=0
    local metadata

    while [ $retry_count -lt 3 ]; do
        metadata=$(wget -q -O - "$metadata_url" 2>&1)
        if [ $? -eq 0 ] && [ -n "$metadata" ]; then
            echo "$metadata"
            return 0
        else
            echo "Retry $((retry_count + 1)): Failed to retrieve metadata from $metadata_url"
            retry_count=$((retry_count + 1))
            sleep 1
        fi
    done

    echo "Error: Failed to retrieve metadata after multiple retries."
    return 1
}

# Retrieve necessary metadata
EC2_INSTANCE_ID=$(retrieve_instance_metadata "instance-id") || exit 1
EC2_AVAIL_ZONE=$(retrieve_instance_metadata "placement/availability-zone") || exit 1
EC2_REGION=$(echo "$EC2_AVAIL_ZONE" | sed -e 's:\([0-9][0-9]*\)[a-z]*\$:\\1:') || exit 1

# Retrieve instance name from tags
EC2_INSTANCE_NAME=$(aws ec2 describe-tags --region "$EC2_REGION" --filters "Name=resource-id,Values=$EC2_INSTANCE_ID" "Name=key,Values=Name" --output text | cut -f5)

# Verify AWS CLI installation
if ! which aws > /dev/null; then
   echo -e "awscli not found! Please install and configure awscli with proper permissions before continuing..."
   exit 1
fi

# Check if Tomcat process is running and/or Port is open
TOMPORT=$(netstat -lnp | grep 8080 | wc -l)
TOMPROC=$(ps ax | grep -c "[j]ava.*org.apache.catalina.startup.Bootstrap")

# To check CPU, Memory, and Disk Usage
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
MEMORY_USAGE=$(free | awk '/Mem/{printf("%.2f"), $3/$2*100}')
DISK_USAGE=$(df -h | awk '$NF=="/"{printf "%s", $5}')

if (( TOMPORT >= 1 )) && (( TOMPROC >= 1 )); then
    AWS_VAL=0  # Tomcat is up
    # Log message for CloudWatch Logs
    CW_LOG_MESSAGE="Tomcat is running. Process count: $TOMPROC, Port status: open. CPU Usage: $CPU_USAGE%, Memory Usage: $MEMORY_USAGE%, Disk Usage: $DISK_USAGE"
else
    AWS_VAL=1  # Tomcat is down
    # Record the date and time when Tomcat goes down
    DOWN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    CW_LOG_MESSAGE="Tomcat is down at: $DOWN_TIME. Process count: $TOMPROC, Port status: closed. CPU Usage: $CPU_USAGE%, Memory Usage: $MEMORY_USAGE%, Disk Usage: $DISK_USAGE"
    echo "Tomcat is down at: $DOWN_TIME" >> /opt/awsTomcatMonitoring/logs/tomcat_down.log
fi

# Just for testing
echo "Tomcat Process Status: $TOMPROC"
echo "Tomcat Port Status: $TOMPORT"
echo "AWS_VAL: $AWS_VAL"
echo "EC2_INSTANCE_ID: $EC2_INSTANCE_ID"
echo "EC2_AVAIL_ZONE: $EC2_AVAIL_ZONE"
echo "CPU Usage: $CPU_USAGE%"
echo "Memory Usage: $MEMORY_USAGE%"
echo "Disk Usage: $DISK_USAGE"

# Push log message to CloudWatch Logs
aws logs create-log-stream --log-group-name "TomcatMonitor" --log-stream-name "$EC2_INSTANCE_ID" --region "$EC2_REGION" || exit 1
aws logs put-log-events --log-group-name "TomcatMonitor" --log-stream-name "$EC2_INSTANCE_ID" --region "$EC2_REGION" --log-events "[{\"timestamp\": $(date +%s)000, \"message\": \"$CW_LOG_MESSAGE\"}]" || exit 1

# Push all data to CloudWatch
aws cloudwatch put-metric-data --namespace "Monitoring" --metric-name "$AWS_METRIC_NAME" --value "$AWS_VAL" --unit Count --dimensions "InstanceID=$EC2_INSTANCE_ID,InstanceName=$EC2_INSTANCE_NAME" --region "$EC2_REGION" || exit 1
