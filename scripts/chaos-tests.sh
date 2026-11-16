#!/usr/bin/env bash
# Resilience tests. Run each one and watch the result in the console or with curl.
# Usage: ./scripts/chaos-tests.sh <test> [stack-name] [region]
#   tests: terminate-instance | reboot-db-failover | break-alb
set -euo pipefail
TEST="${1:?tests: terminate-instance | reboot-db-failover | break-alb}"
STACK="${2:-medicarehub}"
REGION="${3:-$(aws configure get region)}"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

case "$TEST" in
  terminate-instance)
    # Self-healing: the ASG notices the missing capacity and launches a replacement.
    ASG=$(out AutoScalingGroupName)
    ID=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG" \
          --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text)
    echo "Terminating $ID. Watch: the app stays up on the other AZ, a replacement joins in ~3 min,"
    echo "and a new line appears in $(out SharedLogUrl)"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$ID" >/dev/null
    ;;
  reboot-db-failover)
    # Multi-AZ: force a failover to the standby (takes 1-2 minutes, the endpoint stays the same).
    aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$STACK-db" --force-failover >/dev/null
    echo "Failover started. Check RDS > Events to see the switch to the standby AZ."
    ;;
  break-alb)
    # DNS failover: make the app unhealthy everywhere so Route 53 sends users to the S3 page.
    # Scale to 0 to simulate the whole stack failing; restore with the command printed below.
    ASG=$(out AutoScalingGroupName)
    aws autoscaling update-auto-scaling-group --region "$REGION" --auto-scaling-group-name "$ASG" \
      --min-size 0 --desired-capacity 0
    echo "Instances draining. In ~2-3 minutes the domain serves the maintenance page."
    echo "Restore: aws autoscaling update-auto-scaling-group --region $REGION --auto-scaling-group-name $ASG --min-size 2 --desired-capacity 2"
    ;;
  *) echo "Unknown test: $TEST"; exit 1 ;;
esac
