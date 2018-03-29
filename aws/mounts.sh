# Filebeat service installation for bulkhead logs
yum  install -y https://someaddress/filebeat-someversion_x86_64.rpm

mkdir -p /var/log/dcos
mv /etc/filebeat/filebeat.yml.BAK

cat <<EOT >> /etc/filebeat/filebeat/yml
    filebeat.prospectors:
    -input_type: log
    paths:
        - /var/lib/mesos/slave/slaves/*/frameworks/*/executors/bulkhead.*/runs/latest/stdout*
        - /var/lib/mesos/slave/slaves/*/frameworks/*/executors/bulkhead.*/runs/latest/sterr*
    tail_files: true
    output.elasticsearch:
        hosts: ["elasticsearch:9200"]
EOT

# customize hostname
IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
HOSTNAME=$(echo $IP | sed 's^\.^-^g').$(curl http://169.254.169.254/latest/meta-data/instance-id).yourdomainhere #TODO
hostnamectl set-hostname $HOSTNAME
sysctl -w kernel.hostname=$HOSTNAME

# inject puppet address to hosts file
echo 'IP <puppet address> puppetmaster puppet' >> /etc/hosts
echo $IP' '$HOSTNAME >> /etc/hosts


chmod 0755 /etc/systemd/system/dcos-journalctl-filebeat.service
systemctl daemon-reload
systemctl start dcos-journalctl-filebeat.service
systemctl enable dcos-journalctl-filebeat.service
systemctl start filebeat
systemctl enable filebeat