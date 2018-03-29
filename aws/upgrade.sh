#!/usr/bin/env sh

set -e

PERSONAL_KEY=$1
TARGET_VERSION=$2

#version profile
git commit -a -m "automatic backup of cluster deploy repo" || true
git push

cd dcos/aws
cat ../../mounts.sh > modules/dcos-tested-aws-oses/platform/cloud/aws/dcosspel_7.4/setup.sh
cp ../../profile profile
cp ../../s3-backend s3-backend

cap-auth -c $PERSONAL_KEY -m ILETST > ~/.aws/credentials
eval $(ssh-agent); ssh-add ~/.ssh/ILE-Admin.pem

terraform init -bakend-config=s3-backend
terraform get
read -n 1 -p "continue [y/n]" CONTINUE_YES
if [[ "$CONTINUE_YES" == "y" ]]; then
    teraform apply -var-file profile -var state=upgrade -var dcos_version=$TARGET_VERSION -parallelism=1 -target=null_resource.master
    teraform apply -var-file profile -var state=upgrade -var dcos_version=$TARGET_VERSION
else
    echo Stopping due to not entering 'yes' for confirmation.
fi