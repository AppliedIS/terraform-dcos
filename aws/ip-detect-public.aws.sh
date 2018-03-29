#!/bih/sh
#Example ip-detect script using an external authority
#uses the AWS metadata service to get the nodes internal 
#ipv4 address
curl -fsSl http://169.254.169.254/latest/meta-data/public-ipv4