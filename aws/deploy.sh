#!/usr/bin/env sh

set -e

PERSONAL_KEY=$1

#version profile
git commit -a -m "automatic backup of cluster deploy repo" || true
git push

eval $(ssh-agent); ssh-add ~/.ssh/mykey.pem

terraform apply terraform.plan