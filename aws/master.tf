# Internal Load Balancer Access
# Mesos Master, Zookeeper, Exhibitor, Adminrouter, Marathon
resource "aws_elb" "internal-master-elb" {
  name = "${var.dcos_cluster_name}-int-master-elb"
  internal = "true"

  subnets         = ["${var.aws_public_subnet_id}"]
  security_groups = ["${aws_security_group.elb.id}","${aws_security_group.master.id}", "${aws_security_group.public_slave.id}", "${aws_security_group.private_slave.id}", "${aws_security_group.any_access_internal.id}"]
  instances       = ["${aws_instance.master.*.id}"]

  listener {
    lb_port	      = 5050
    instance_port     = 5050
    lb_protocol       = "http"
    instance_protocol = "http"
  }

  listener {
    lb_port           = 2181
    instance_port     = 2181
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 8181
    instance_port     = 8181
    lb_protocol       = "http"
    instance_protocol = "http"
  }

  listener {
    lb_port           = 80
    instance_port     = 80
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 443
    instance_port     = 443
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 8080
    instance_port     = 8080
    lb_protocol       = "http"
    instance_protocol = "http"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 5
    target = "TCP:5050"
    interval = 30
  }

  lifecycle {
    ignore_changes = ["name"]
  }
}

# Public Master Load Balancer Access
# Adminrouter Only
resource "aws_elb" "public-master-elb" {
  name = "${var.dcos_cluster_name}-pub-mas-elb"

  subnets         = ["${var.aws_public_subnet_id}"]
  security_groups = ["${aws_security_group.admin.id}", "${aws_security_group.elb.id}", "${aws_security_group.any_access_internal.id}"]
  instances       = ["${aws_instance.master.*.id}"]

  listener {
    lb_port           = 80
    instance_port     = 80
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  listener {
    lb_port           = 443
    instance_port     = 443
    lb_protocol       = "tcp"
    instance_protocol = "tcp"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 5
    target = "TCP:5050"
    interval = 30
  }

  lifecycle {
    ignore_changes = ["name"]
  }
}

resource "aws_instance" "master" {
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  connection {
    # The default username for our AMI
    user = "${module.aws-tested-oses.user}"

    host = "${var.bastion_host == "" ? self.public_ip : self.private_ip}"
    
    # The connection will use the local SSH agent for authentication.
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    bastion_private_key = "${file(var.bastion_private_key)}"
  }

  root_block_device {
    volume_size = "${var.instance_disk_size}"
    volume_type = "gp2"
  }

  count = "${var.num_of_masters}"
  instance_type = "${var.aws_master_instance_type}"

  ebs_optimized  = "true"

  tags {
  #TODO: Add chargeback via appropriate charge code
   owner = "${coalesce(var.owner, data.external.whoami.result["owner"])}"
   expiration = "${var.expiration}"
   Name = "${var.dcos_cluster_name}-master-${count.index + 1}"
   cluster = "${var.dcos_cluster_name}"
   ile-test-project = "${var.dcos_cluster_name}"
  }

  # Lookup the correct AMI based on the region
  # we specified
  ami = "${module.aws-tested-oses.aws_ami}"

  # The name of our SSH keypair we created above.
  key_name = "${var.key_name}"

  # ensure we are starting with default user name
  user_data = "{file("user-data.yaml")}"
  
  # Our Security group to allow http and SSH access
  vpc_security_group_ids = ["${aws_security_group.master.id}","${aws_security_group.admin.id}","${aws_security_group.any_access_internal.id}"]

  #optional IAM role to apply to instances
  iam_instance_profile = "${var.aws_master_iam_role}"
  
  # OS init script
  provisioner "file" {
   content = "${module.aws-tested-oses.os-setup}"
   destination = "${var.script_location}/os-setup.sh"
   }

  provisioner "remote-exec" {
  inline = [
    "echo beginning inline execution...",
    "sudo bash ${var.script_location}/os-setup.sh",
    ]
    
    connection {
      script_path = "${var.script_location}/exec-os-setup.sh"
    }
  }

  # We're going to launch into the same subnet as our ELB. In a production
  # environment it's more common to have a seperate private subnet for
  # backend instances
  subnet_id = "${var.aws_public_subnet_id}"
  
  lifecycle {
    ignore_changes = ["tags", "ami"]
  }
}

# Create DCOS Mesos Master Scripts to execute
module "dcos-mesos-master" {
  source               = "./modules/tf_dcos_core"
  bootstrap_private_ip = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode    = "${var.state}"
  dcos_version         = "${var.dcos_version}"
  role                 = "dcos-mesos-master"
}

resource "null_resource" "master" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids = "${null_resource.bootstrap.id}"
  }
  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    user = "${module.aws-tested-oses.user}"
    
    host = "${var.bastion_host == "" ? element(aws_instance.master.*.public_ip, count.index) : element(aws_instance.master.*.private_ip, count.index)}"
    
    # The connection will use the local SSH agent for authentication.
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    bastion_private_key = "${file(var.bastion_private_key)}"
  }

  count = "${var.num_of_masters}"

  # Wait for bootstrapnode to be ready
  provisioner "remote-exec" {
    inline = [
     "until $(curl --output /dev/null --silent --head --fail http://${aws_instance.bootstrap.private_ip}/dcos_install.sh); do printf 'waiting for bootstrap node to serve...'; sleep 20; done"
    ]
    
     connection {
      script_path = "${var.script_location}/exec-os-setup.sh"
    }
  }

  # Generate and upload master script to node
  provisioner "file" {
    content     = "${module.dcos-mesos-master.script}"
    destination = "${var.script_location}/run.sh"
  }
  
  # Install Master Script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x ${var.script_location}/run.sh",
      "sudo ${var.script_location}/run.sh",
    ]
    
     connection {
      script_path = "${var.script_location}/exec-run.sh"
    }
  }

  # Watch Master Nodes Start
  provisioner "remote-exec" {
    inline = [
      "until $(curl --output /dev/null --silent --head --fail http://${element(aws_instance.master.*.private_ip, count.index)}/); do printf 'loading DC/OS...'; sleep 10; done"
    ]
    
     connection {
      script_path = "${var.script_location}/exec-wait-on-start.sh"
    }
  }
}

output "Master ELB Address" {
  value = "${aws_elb.public-master-elb.dns_name}"
}

output "Mesos Master Public IP" {
  value = ["${aws_instance.master.*.public_ip}"]
}
