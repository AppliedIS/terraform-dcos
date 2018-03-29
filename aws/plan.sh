#!/usr/bin/env sh

set -e

PERSONAL_KEY=$1

cp mounts.sh modules/dcos-tested-aws-oses/platform/cloud/aws/dcosspel_7.4/setup.sh

cap-auth -c $PERSONAL_KEY -m ILETST > ~/.aws/credentials

terraform init -backend-config=s3-backend
terraform get
terraform plan -var-file profile -out terraform.plan

echo 
echo If you are happy with this plan simply run: ./deploy.sh
echo
