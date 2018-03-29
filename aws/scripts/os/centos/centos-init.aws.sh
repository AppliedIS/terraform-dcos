SCRIPT_URL=scale-rle-shared

#run common scripts
sudo yum install -y curl puppet wget xz unzip ipset ntp
curl -L -k ${SCRIPT_URL}/ca-trust.sh | sudo bash

#disable firewall, grow disk and disable SeLinux
curl -L ${SCRIPT_URL}/firewall.sh | sudo bash
curl -L ${SCRIPT_URL}/increaseDisk.sh | sudo bash
curl -L ${SCRIPT_URL}/selinux.sh | sudo bash
curl -L ${SCRIPT_URL}/docker-17.sh | sudo bash

#install AWS CLI
curl -L ${SCRIPT_URL}/pip.sh | sudo bash
curl -L ${SCRIPT_URL}/awscli.sh | sudo bash

#kevin commands - root trusts, awscli and C2S endpoints must be set first for this to work
curl -L ${SCRIPT_URL}/vatcloud.sh | sudo bash

#install goofys
curl -L ${SCRIPT_URL}/goofys.sh | sudo bash

#setup NTP
sudo tee /etc/ntp.conf <<-'EOF'

EOF
sudo systemctl enable ntpd
sudo systemctl restart ntpd

# Setup for scale /DCOS
sudo useradd -u 7498 -g 100 scale
sudo wget -q <docker-creds.zip location> -O /root/docker-creds.zip #TODO
sudo unzip /root/docker-creds.zip -d root

#create required DCOS group
sudo groupadd <group> #TODO

#allow exec on /tmp
sudo sed -i '/tmp/ s/noexec/exec' /etc/fstab

#enable IPv4 IP forwarding
sudo sed -i '/net.ipv4.ip_forward/ s/0/1/' /etc/sysctl.conf
sudo sysctl -p