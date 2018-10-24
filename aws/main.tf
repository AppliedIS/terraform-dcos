# Specify the provider and access details
provider "aws" {
  profile = "${var.aws_profile}"
  region = "${var.aws_region}"
}

#requires that terraform init be called to get started with s3 backend
# A file called s3-backend should be created with the following contents:
# bucket    = "my-bucket-name"
# key       = "cluster-name/terraform.tfstate"
# endpoint  = "https://s3"


# terraform init -backend-config-s3-backend
terraform {
  backend "s3" {
    region = "us-east-1"
  }
}


# Runs a local script to return the current user in bash
data "external" "whoami" {
  program = ["scripts/local/whoami.sh"]
}

# we are not going to use a custom VPC / route / IGW or subnet, but launch into an existing one. it is assumed
# that this one has external connectivity and public IPs are assigned. 

# Create DCOS Bucket regardless of what exhibitor backend was chosen
resource "aws_s3_bucket" "dcos_bucket" {
  bucket = "${var.aws_bucket_prefix}${var.dcos_cluster_name}-bucket"
  acl    = "private"
  force_destroy = "true"

  tags {
   Name = "${var.aws_bucket_prefix}${var.dcos_cluster_name}-bucket"
   cluster = "${var.dcos_cluster_name}"
   ile-test-project = "${var.dcos_cluster_name}"
  }
}

# A security group that allows all port access to internal vpc
resource "aws_security_group" "any_access_internal" {
  name        = "${var.dcos_cluster_name}-cluster-security-group"
  description = "Manage all ${var.dcos_cluster_name} cluster ports"
  vpc_id      = "${var.aws_vpc_id}"

 # full access internally
 ingress {
  from_port = 0
  to_port = 0
  protocol = "-1"
  self = true
  }

 # full access internally
 egress {
  from_port = 0
  to_port = 0
  protocol = "-1"
  self = true
  }
}

# A security group for the ELB so it is accessible via the web
resource "aws_security_group" "elb" {
  name        = "${var.dcos_cluster_name}-elb-security-group"
  description = "${var.dcos_cluster_name} security group for the elb"
  vpc_id      = "${var.aws_vpc_id}"

  # http access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = ["${aws_security_group.private_slave.id}"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# A security group for Admins to control access
resource "aws_security_group" "admin" {
  name        = "${var.dcos_cluster_name}-admin-security-group"
  description = "${var.dcos_cluster_name} Administrators can manage their machines"
  vpc_id      = "${var.aws_vpc_id}"

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.admin_ssh_cidr}"]
  }

  # http access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${var.admin_cidr}"]
  }

  # httpS access from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${var.admin_cidr}"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# A security group for the ELB so it is accessible via the web
# with some master ports for internal access only
resource "aws_security_group" "master" {
  name        = "${var.dcos_cluster_name}-master-security-group"
  description = "${var.dcos_cluster_name} Security group for masters"
  vpc_id      = "${var.aws_vpc_id}"

 # Mesos Master access from within the vpc
 ingress {
   to_port = 5050
   from_port = 5050
   protocol = "tcp"
   self = true
 }

 # Adminrouter access from within the vpc
 ingress {
   to_port = 80
   from_port = 80
   protocol = "tcp"
   self = true
 }

 # Marathon access from within the vpc
 ingress {
   to_port = 8080
   from_port = 8080
   protocol = "tcp"
   security_groups = ["${aws_security_group.any_access_internal.id}"]
 }

 # Exhibitor access from within the vpc
 ingress {
   to_port = 8181
   from_port = 8181
   protocol = "tcp"
   security_groups = ["${aws_security_group.any_access_internal.id}"]
 }

 # Zookeeper Access from within the vpc
 ingress {
   to_port = 2181
   from_port = 2181
   protocol = "tcp"
   security_groups = ["${aws_security_group.any_access_internal.id}"]
 }

 # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# A security group for public slave so it is accessible via the web
resource "aws_security_group" "public_slave" {
  name        = "${var.dcos_cluster_name}-public-slave-security-group"
  description = "${var.dcos_cluster_name} security group for slave public"
  vpc_id      = "${var.aws_vpc_id}"

  # Allow ports within range
  ingress {
    to_port = 21
    from_port = 0
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ports within range
  ingress {
    from_port = 0
    to_port = 0
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # full access internally
  ingress {
    to_port = 0
    from_port = 0
    protocol = "-1"
    self = true
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# A security group for private slave so it is accessible internally
resource "aws_security_group" "private_slave" {
  name        = "${var.dcos_cluster_name}-private-slave-security-group"
  description = "${var.dcos_cluster_name} security group for slave private"
  vpc_id      = "${var.aws_vpc_id}"

  # full access internally
  ingress {
   from_port = 0
   to_port = 0
   protocol = "-1"
   self = true
   }

  # outbound internet access
  egress {
   from_port = 0
   to_port = 0
   protocol = "-1"
   cidr_blocks = ["0.0.0.0/0"]
   }
}

# Provide tested AMI and user from listed region startup commands
  module "aws-tested-oses" {
      source   = "./modules/dcos-tested-aws-oses"
      os       = "${var.os}"
      region   = "${var.aws_region}"
}
