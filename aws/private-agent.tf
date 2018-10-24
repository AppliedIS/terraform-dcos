# Private agent instance deploy
resource "aws_instance" "agent" {
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

  count = "${var.num_of_private_agents}"
  instance_type = "${var.aws_agent_instance_type}"

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
  user_data = "${file("user-data.yaml")}"
  
  # Our Security group to allow http and SSH access
  vpc_security_group_ids = ["${aws_security_group.private_slave.id}","${aws_security_group.admin.id}","${aws_security_group.any_access_internal.id}"]

  #optional IAM role to apply to instances
  iam_instance_profile = "${var.aws_master_iam_role}"
  
  # We're going to launch into the same subnet as our ELB. In a production
  # environment it's more common to have a separate private subnet for
  # backend instances.
  subnet_id = "${var.aws_private_subnet_id}"

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
      "sudo systemctl disable dcos-mesos-slave",
      "sudo systemctl kill -s SIGUSR1 dcos-mesos-slave",
      ]
      
    connection {
      script_path = "${var.script_location}/graceful-agent-remove.sh"
    }
  }
  
  lifecycle {
    ignore_changes = ["tags"]
  }
}

# Create DCOS Mesos Agent Scripts to execute
module "dcos-mesos-agent" {
  source               = "./modules/tf_dcos_core"
  bootstrap_private_ip = "${aws_instance.bootstrap.private_ip}"
  dcos_install_mode    = "${var.state}"
  dcos_version         = "${var.dcos_version}"
  role                 = "dcos-mesos-agent"
}

# Execute generated script on agent
resource "null_resource" "agent" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    cluster_instance_ids = "${null_resource.bootstrap.id}"
  }
  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host = "${element(aws_instance.agent.*.public_ip, count.index)}"
    user = "${module.aws-tested-oses.user}"
    
    host = "${var.bastion_host == "" ? element(aws_instance.agent.*.public_ip, count.index) : element(aws_instance.agent.*.private_ip, count.index)}"
    
    #the connection will use the local SSH agent for authentication.
    bastion_host = "${var.bastion_host}"
    bastion_user = "${var.bastion_user}"
    bastion_private_key = "${file(var.bastion_private_key)}"
  }

  count = "${var.num_of_private_agents}"

  # Wait for bootstrap node to be ready
  provisioner "remote-exec" {
    inline = [
     "until $(curl --output /dev/null --silent --head --fail http://${aws_instance.bootstrap.private_ip}/dcos_install.sh); do printf 'waiting for bootstrap node to serve...'; sleep 20; done"
    ]
    
     connection {
      script_path = "${var.script_location}/exec-dcos-install.sh"
      }
  }

 #Generate and upload slave script to node
  provisioner "file" {
    content     = "${module.dcos-mesos-agent.script}"
    destination = "${var.script_location}/run.sh"
  }

  # install slave script
  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x ${var.script_location}/run.sh",
      "sudo ${var.script_location}/run.sh"
    ]
    
    connection {
      script_path = "${var.script_location}/exec-run.sh"
    }
  }
}

output "Private Agent Public IP Address" {
  value = ["${aws_instance.agent.*.public_ip}"]
}
