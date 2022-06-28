#!/bin/bash

export CLUSTER_NAME=rke
export LXC_IMAGE="images:ubuntu/22.04"
export LXC_PROFILES="--profile k8s --profile docker"

export DOCKER_VERSION=20.10.17
# The versions of runc and containerd that come with every docker version
# can be found here: https://github.com/moby/moby/tree/master/hack/dockerfile/install

function init_host(){
	mkdir -p /home/ubuntu/.config/lxc/
	sudo chown -R ubuntu:ubuntu /home/ubuntu/.config
	sudo mkdir -p /mnt/volume/lxd/storage-pools/default
	lxd init --preseed < lxd-init.yaml
	ssh-keygen -b 2048 -t rsa -f /home/ubuntu/.ssh/id_rsa -q -N "" <<<"y" >/dev/null
	SSH_PUBKEY="/home/ubuntu/.ssh/id_rsa.pub"

	# shellcheck disable=SC2024
	sudo lxc profile create k8s
	sudo lxc profile edit k8s < lxc-profile-k8s.yaml
	sudo lxc profile create docker
	# shellcheck disable=SC2024
	sudo lxc profile edit docker < lxc-profile-docker.yaml
}

# Create container with ssh installed and key copied
SSH_TEMPLATE_NAME="${CLUSTER_NAME}-template-ssh"
function create_ssh_container() {
	# shellcheck disable=SC2086
	lxc launch ${LXC_PROFILES} "${LXC_IMAGE}" "${SSH_TEMPLATE_NAME}"
	lxc exec "${SSH_TEMPLATE_NAME}" -- apt update
	lxc exec "${SSH_TEMPLATE_NAME}" -- apt install ssh -y 
	lxc exec "${SSH_TEMPLATE_NAME}" -- mkdir -p /home/ubuntu/.ssh/
	lxc file push ${SSH_PUBKEY} "${SSH_TEMPLATE_NAME}/home/ubuntu/.ssh/authorized_keys" --mode 0700
	# make / shared we will need it for kubelet
	# to test if it worked use:  findmnt  -o TARGET,PROPAGATION /
	lxc exec "${SSH_TEMPLATE_NAME}" -- dd of=/etc/rc.local <<<$(printf "%s\n%s" '#!/bin/sh -e' "mount --make-rshared /")
	lxc exec "${SSH_TEMPLATE_NAME}" -- chmod +x /etc/rc.local
	lxc stop "${SSH_TEMPLATE_NAME}"
}

# Create container with docker
DOCKER_TEMPLATE_NAME=${CLUSTER_NAME}-1-template-docker
function create_docker_container() {
	lxc copy "${SSH_TEMPLATE_NAME}" "${DOCKER_TEMPLATE_NAME}"
	lxc start "${DOCKER_TEMPLATE_NAME}"
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- apt update
	#  open-iscsi is for longhorn https://github.com/kubernetes/minikube/issues/2846
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- apt install curl open-iscsi -y 
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- mkdir /etc/docker
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- dd of=/etc/docker/daemon.json <<<'{ "data-root": "/opt/docker" }'
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- bash -c 'curl -L get.docker.com | VERSION='${DOCKER_VERSION}' bash'
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- sudo usermod -aG docker ubuntu
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- docker info
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- docker run --rm alpine echo "In ${DOCKER_TEMPLATE_NAME} Docker Works!"
	lxc exec "${DOCKER_TEMPLATE_NAME}" -- docker rmi alpine 
	lxc stop "${DOCKER_TEMPLATE_NAME}"
}

function create_rke_node_containers() {
	NODES=$(echo rke{1..3})
	for NODE in ${NODES}; do
		lxc copy "${DOCKER_TEMPLATE_NAME}" "${NODE}"
		lxc start "${NODE}"
	done
}

function clean_rke_nodes_container() {
	NODES=$(echo rke{1..3})
	for NODE in ${NODES}; do
		lxc stop "${NODE}"
		lxc delete "${NODE}"
	done
}

function populate_etc_hosts() {
	# Add node ips to /etc/hosts
	cat /etc/hosts
	NODES=$(echo rke{1..3})
	for NODE in ${NODES}; do
		# shellcheck disable=SC2016
		node_ip=$(lxc exec "${NODE}" -- bash -c 'printf "%s %s" $(ip -4 addr show eth0 | grep -oP "(?<=inet ).*(?=/)") $(hostname)')
		sudo sed -i '/[0-9]\+.[0-9]\+.[0-9]\+\.[0-9]\+ '"${NODE}"'/d' /etc/hosts
		echo "$node_ip" | sudo tee -a /etc/hosts
	done
	cat /etc/hosts
}

# Create rke-server
# for rancher (or rather k3s as of 6.20.2022) server to work on 22.04
# you have to disable cgroups2 running:
# 	echo 'GRUB_CMDLINE_LINUX=systemd.unified_cgroup_hierarchy=false' > /etc/default/grub.d/cgroup.cfg
# 	update-grub
RANCHER_SERVER_VERSION="v2.6.4"
RANCHER_SERVER_PASSWOD="password"
function create_rke_server() {
	RKE_SERVER_NAME="rke-server"
	lxc copy "${DOCKER_TEMPLATE_NAME}" "${RKE_SERVER_NAME}"
	lxc start "${RKE_SERVER_NAME}"
	lxc exec "${RKE_SERVER_NAME}" -- bash -c 'while ! docker ps > /dev/null ; do echo "Waiting for docker service to start" ; sleep 1  ; done'
	lxc exec "${RKE_SERVER_NAME}" -- docker run -d --name rke-server \
		--restart=unless-stopped \
		-e CATTLE_BOOTSTRAP_PASSWORD="${RANCHER_SERVER_PASSWOD}" \
		-p 80:80 -p 443:443 \
		-v /opt/rancher:/var/lib/rancher \
		--privileged \
		rancher/rancher:"${RANCHER_SERVER_VERSION}"
	lxc exec "${RKE_SERVER_NAME}" -- docker logs rke-server -f
}

# Rancher/k8s/kubelet fix for https://www.thedroneely.com/posts/kubernetes-in-a-linux-container/
# from https://gist.github.com/julianlam/07abef272136ea14a627
# for NODE in ${NODES}; do
# 	lxc config device add "${NODE}" kmsg-share unix-char path=/dev/kmsg source="/dev/kmsg"
# done

init_host
create_ssh_container
create_docker_container
create_rke_node_containers
populate_etc_hosts
