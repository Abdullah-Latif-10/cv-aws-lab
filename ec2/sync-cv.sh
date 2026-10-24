#!/bin/bash
# Copies the site/ prefix of the private bucket into the web root,
# fills in the footer, and logs the result. Credentials come from the instance role.
BUCKET="cv-23l-3080"
PREFIX="site/"
STAGE=/var/lib/cv-site
WEB=/var/www/html
LOG=/var/log/cv-sync.log
export AWS_DEFAULT_REGION="ap-southeast-2"

mkdir -p "$STAGE"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

if aws s3 sync "s3://$BUCKET/$PREFIX" "$STAGE" --delete --only-show-errors \
   && cp -a "$STAGE"/. "$WEB"/ \
   && sed -i "s/{{HOSTED_ON}}/EC2 $ID/" "$WEB/index.html"; then
  RESULT=OK
else
  RESULT=FAILED
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sync $RESULT instance=$ID" >> "$LOG"
[ "$RESULT" = "OK" ]
