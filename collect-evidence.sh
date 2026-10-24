#!/bin/bash
# Usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>
# Writes evidence.txt. A failing command is noted and the script carries on.
set -o pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>"
  exit 1
fi

BUCKET="$1"
EC2_ADDR="$2"
LAMBDA_ADDR="$3"
OUT="evidence.txt"
export AWS_PAGER=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"

case "$EC2_ADDR" in http://*|https://*) ;; *) EC2_ADDR="http://$EC2_ADDR" ;; esac
case "$LAMBDA_ADDR" in http://*|https://*) ;; *) LAMBDA_ADDR="https://$LAMBDA_ADDR" ;; esac
EC2_ADDR="${EC2_ADDR%/}"
LAMBDA_ADDR="${LAMBDA_ADDR%/}"

try() { "$@" || echo "COMMAND FAILED: $*"; }
have() { [ -n "$1" ] && [ "$1" != "None" ]; }

# Look up the resource names (they all start with a fixed prefix)
EC2_ROLE=$(aws iam list-roles --query "Roles[?starts_with(RoleName, 'cv-ec2-role-')].RoleName | [0]" --output text 2>/dev/null)
LAMBDA_ROLE=$(aws iam list-roles --query "Roles[?starts_with(RoleName, 'cv-lambda-role-')].RoleName | [0]" --output text 2>/dev/null)
FUNC=$(aws lambda list-functions --query "Functions[?starts_with(FunctionName, 'cv-func-')].FunctionName | [0]" --output text 2>/dev/null)
INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cv-ec2-*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId | [0]" --output text 2>/dev/null)

s_caller() {
  try aws sts get-caller-identity
}

s_public_access() {
  try aws s3api get-public-access-block --bucket "$BUCKET"
}

s_versioning() {
  try aws s3api get-bucket-versioning --bucket "$BUCKET"
}

s_objects() {
  try aws s3 ls "s3://$BUCKET/site/" --recursive
}

s_ec2_policy() {
  if have "$EC2_ROLE"; then
    echo "role: $EC2_ROLE"
    try aws iam get-role-policy --role-name "$EC2_ROLE" --policy-name cv-ec2-s3-read
    echo "attached managed policies:"
    try aws iam list-attached-role-policies --role-name "$EC2_ROLE"
  else
    echo "COMMAND FAILED: EC2 role not found"
  fi
}

s_lambda_policy() {
  if have "$LAMBDA_ROLE"; then
    echo "role: $LAMBDA_ROLE"
    echo "attached managed policies:"
    try aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE"
    echo "inline policies:"
    for p in $(aws iam list-role-policies --role-name "$LAMBDA_ROLE" --query PolicyNames --output text 2>/dev/null); do
      try aws iam get-role-policy --role-name "$LAMBDA_ROLE" --policy-name "$p"
    done
  else
    echo "COMMAND FAILED: Lambda role not found"
  fi
}

s_security_group() {
  if have "$INSTANCE"; then
    SG=$(aws ec2 describe-instances --instance-ids "$INSTANCE" \
      --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text 2>/dev/null)
    echo "security group: $SG"
    try aws ec2 describe-security-groups --group-ids "$SG" \
      --query "SecurityGroups[0].IpPermissions[].{Protocol:IpProtocol,From:FromPort,To:ToPort,Sources:IpRanges[].CidrIp}" \
      --output json
  else
    echo "COMMAND FAILED: running instance not found"
  fi
}

s_instance() {
  if have "$INSTANCE"; then
    try aws ec2 describe-instances --instance-ids "$INSTANCE" \
      --query "Reservations[0].Instances[0].{Id:InstanceId,Type:InstanceType,HttpTokens:MetadataOptions.HttpTokens,InstanceProfile:IamInstanceProfile.Arn,PublicIp:PublicIpAddress}" \
      --output json
  else
    echo "COMMAND FAILED: running instance not found"
  fi
}

probe() {
  printf '%s -> ' "$1"
  curl -s -m 20 -o /dev/null -w 'status=%{http_code} content-type=%{content_type}\n' "$2" \
    || echo "COMMAND FAILED: curl $2"
}

s_endpoints() {
  probe "EC2 /"           "$EC2_ADDR/"
  probe "EC2 /style.css"  "$EC2_ADDR/style.css"
  probe "EC2 /cv.pdf"     "$EC2_ADDR/cv.pdf"
  probe "Lambda /"          "$LAMBDA_ADDR/"
  probe "Lambda /style.css" "$LAMBDA_ADDR/style.css"
  probe "Lambda /cv.pdf"    "$LAMBDA_ADDR/cv.pdf"
  probe "S3 direct site/index.html" "https://$BUCKET.s3.$REGION.amazonaws.com/site/index.html"
}

s_lambda_logs() {
  if have "$FUNC"; then
    aws logs tail "/aws/lambda/$FUNC" --since 1d --format short | tail -15 \
      || echo "COMMAND FAILED: aws logs tail"
  else
    echo "COMMAND FAILED: Lambda function not found"
  fi
}

s_log_retention() {
  if have "$FUNC"; then
    try aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$FUNC" \
      --query "logGroups[].{LogGroup:logGroupName,RetentionInDays:retentionInDays}" --output json
  else
    echo "COMMAND FAILED: Lambda function not found"
  fi
}

: > "$OUT"
for name in caller public-access versioning objects ec2-policy lambda-policy \
            security-group instance endpoints lambda-logs log-retention; do
  echo "== $name ==" >> "$OUT"
  "s_${name//-/_}" >> "$OUT" 2>&1
  echo >> "$OUT"
done

echo "DONE"
