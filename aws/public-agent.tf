# Reattach the public ELBs to the agents if they change
resource "aws_elb_attachment" "public-agent-elb" {
  count    = "${var.num_of_public_agents}"
  elb      = "${aws_elb.public-agent-elb.id}"
  instance = "${aws_instance.public-agent.*.id[count.index]}"
}

# Public Agent Load Balancer Access
# Adminrouter Only
resource "aws_elb" "public-agent-elb" {
  name = "${var.dcos_cluster_name}-pub-agt-elb"

  subnets         = ["${var.aws_public_subnet_id}"]
  security_groups = ["${aws_security_group.public_slave.id}"]
  instances       = ["${aws_instance.public-agent.*.id}"]

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
    timeout = 2
    target = "HTTP:9090/_haproxy_health_check"
    interval = 5
  }

  lifecycle {
    ignore_changes = ["name"]
  }
}

resource "aws_instance" "public-agent" {
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

  count = "${var.num_of_public_agents}"
  instance_type = "${var.aws_public_agent_instance_type}"

  ebs_optimized = "true"

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
  vpc_security_group_ids = ["${aws_security_group.public_slave.id}","${aws_security_group.admin.id}","${aws_security_group.any_access_internal.id}"]

  #optional IAM role to apply to instances
  iam_instance_profile = "${var.aws_agent_iam_role}"
  
  # We're going to launch into the same subnet as our ELB. In a production
  # environment it's more common to have a separate private subnet for
  # backend instances.
  subnet_id = "${var.aws_public_subnet_id}"

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

 #on destroy agent removal script
  provisioner "remote-exec" {
    when = "destroy"
    inline = [
      "sudo systemctl disable dcos-mesos-slave-public",
      "sudo systemctl kill -s SIGUSR1 dcos-mesos-slave-public",
      ]
      
    connection {
      script_path = "${var.script_location}/graceful-agent-remove.sh"
    }
  }
  
  lifecycle {
    ignore_changes = ["tags"]
  }
}

# Create DCOS Mesos Public Agent Scripts to execute
module "dcos-mesos-agent-public" {
  source               = "./modules/tf_dcos_core"
  bootstrap_private_ip = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode = "${var.state}"
  dcos_version         = "${var.dcos_version}"
  role                 = "dcos-mesos-agent-public"
}

# Execute generated script on agent
resource "null_resource" "public-agent" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids = "${null_resource.bootstrap.id}"
    current_ec2_instance_id = "${aws_instance.public-agent.*.id[count.index]}"
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    user = "${module.aws-tested-oses.user}"
    
    host = "${var.bastion_host == "" ? element(aws_instance.public-agent.*.public_ip, count.index) : element(aws_instance.public-agent.*.private_ip, count.index)}"
    
    #the connection will use the local SSH agent for authentication.
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    bastion_private_key = "${file(var.bastion_private_key)}"
  }

  count = "${var.num_of_public_agents}"

  # Wait for bootstrap node to be ready
  provisioner "remote-exec" {
    inline = [
     "until $(curl --output /dev/null --silent --head --fail http://${aws_instance.bootstrap.private_ip}/dcos_install.sh); do printf 'waiting for bootstrap node to serve...'; sleep 20; done"
    ]
    
    connection {
      script_path = "${var.script_location}/exec-dcos-install.sh"
      }
  }

  # Generate and upload slave script to node
  provisioner "file" {
    content     = "${module.dcos-mesos-agent.script}"
    destination = "${var.script_location}/run.sh"
  }

  # install slave script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x ${var.script_location}/run.sh"
      "sudo ${var.script_location}/run.sh"
    ]
    
     connection {
      script_path = "${var.script_location}/exec-run.sh"
    }
  }
}

output "Public Agent ELB Address" {
  value = "${aws_elb.public-agent-elb.dns_name}"
}

output "Public Agent Public IP Address" {
  value = ["${aws_instance.public-agent.*.public_ip}"]
}
