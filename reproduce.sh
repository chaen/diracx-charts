#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
set -x

script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

tmp_dir=$(mktemp -d)
demo_dir="${script_dir}/.demo"
mkdir -p "${demo_dir}"
export KUBECONFIG="${demo_dir}/kube.conf"
export HELM_DATA_HOME="${demo_dir}/helm_data"

function check_hostname(){

  # Force the use of ipv4.

  # Check that the hostname resolves to an IP address
  # dig doesn't consider the effect of /etc/hosts so we use ping instead
  if ! ip_address=$(ping -c 1 "$1" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1); then
    printf "%b ping command exited with a non-zero exit code\n" ${SKULL_EMOJI}
    return 1
  fi
  if [[ -z "${ip_address}" ]]; then
    printf "%b No IP address found hostname %s\n" ${SKULL_EMOJI} "${1}"
    return 1
  fi
  if [[ "${ip_address}" == 127.* ]]; then
    printf "%b Hostname %s resolves to 127.0.0.1 but this is not supported\n" ${SKULL_EMOJI} "${1}"
    return 1
  fi
  if ! docker_ip_address=$(docker run --rm alpine ping -c 1 "$1" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1); then
    printf "%b ping command exited with a non-zero exit code from within docker\n" ${SKULL_EMOJI}
    return 1
  fi
  if [[ "${ip_address}" != "${docker_ip_address}" ]]; then
    printf "%b Hostname %s resolves to %s but within docker it resolves to %s\n" ${SKULL_EMOJI} "${1}" "${ip_address}" "${docker_ip_address}"
    return 1
  fi
}

function element_not_in_array() {
  local element=$1
  shift
  local elements=("$@")
  local found=0

  for existing_element in "${elements[@]}"; do
      if [[ "$existing_element" == "$element" ]]; then
          found=1
          break
      fi
  done

  return $found
}

# Parse command-line switches
exit_when_done=0
mount_containerd=1
offline_mode=0
declare -a helm_arguments=()
enable_coverage=0
editable_python=1
open_telemetry=0
declare -a ci_values_files=()
declare -a docker_images_to_load=()


# We download kind/kubectl/helm into the .demo directory to avoid having any
# requirements on the user's machine
# Inspect the current system
system_name=$(uname -s | tr '[:upper:]' '[:lower:]')
system_arch=$(uname -m)
if [[ "${system_arch}" == "x86_64" ]]; then
    system_arch="amd64"
fi

# Download kind
printf "%b Downloading kind\n"
curl --no-progress-meter -L "https://kind.sigs.k8s.io/dl/v0.19.0/kind-${system_name}-${system_arch}" > "${demo_dir}/kind"

# Download kubectl
printf "%b Downloading kubectl\n"
latest_version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl --no-progress-meter -L "https://dl.k8s.io/release/${latest_version}/bin/${system_name}/${system_arch}/kubectl" > "${demo_dir}/kubectl"

# Download helm
printf "%b Downloading helm\n"
curl --no-progress-meter -L "https://get.helm.sh/helm-v3.12.0-${system_name}-${system_arch}.tar.gz" > "${tmp_dir}/helm.tar.gz"
mkdir -p "${tmp_dir}/helm-tarball"
tar xzf "${tmp_dir}/helm.tar.gz" -C "${tmp_dir}/helm-tarball"
mv "${tmp_dir}/helm-tarball/${system_name}-${system_arch}/helm" "${demo_dir}"

# Make the binaries executable
chmod +x "${demo_dir}/kubectl" "${demo_dir}/kind" "${demo_dir}/helm"

# Install helm plugins to ${HELM_DATA_HOME}
"${demo_dir}/helm" plugin install https://github.com/databus23/helm-diff



# Create the cluster itself
printf "%b Starting Kind cluster...\n"
"${demo_dir}/kind" create cluster \
  --kubeconfig "${KUBECONFIG}" \
  --wait "1m" \
  --name diracx-demo




echo "CHRIS"

echo "${KUBECONFIG}"
cat  "${KUBECONFIG}"

#"${demo_dir}/kubectl" get pods
curl  -L "$(grep server ${KUBECONFIG}  | awk '{print $NF}')"

"${demo_dir}/kubectl" cluster-info

echo "CHRIS"


# Try to find a suitable hostname/IP-address for the demo. This must be not
# resolve to a loopback address as pods need to be able to communicate with
# each other via this address. For example, the DiracX service pod needs to be
# able to communicate with dex via this while users also use the same
# address/IP-address.
machine_ip=""
machine_hostname=$(hostname | tr '[:upper:]' '[:lower:]')
if ! check_hostname "${machine_hostname}"; then
  if [[ "$(uname -s)" = "Linux" ]]; then
    machine_ip=$(docker inspect --format '{{ .NetworkSettings.Networks.kind.Gateway }}' diracx-demo-control-plane)
    if [[ -z "${machine_ip}" ]]; then
      printf "%b Error: Failed to find IP address from docker\n" ${SKULL_EMOJI}
      exit 1
    fi
    machine_hostname="${machine_ip}.nip.io"
  fi
  if ! check_hostname "${machine_hostname}"; then
    machine_ip=$(ifconfig | grep 'inet ' | awk '{ print $2 }' | grep -v '^127' | head -n 1 | cut -d '/' -f 1)
    # We use nip.io to have an actual DNS name and be allowed to specify this in
    # the ingress host
    machine_hostname="${machine_ip}.nip.io"
    if ! check_hostname "${machine_hostname}"; then
      echo "Failed to find an appropriate hostname for the demo."
      exit 1
    fi
  fi
  printf "%b Using IP address %s instead \n" ${INFO_EMOJI} "${machine_hostname}"
fi
if [ "${machine_ip}" ]; then
  helm_arguments+=("--set" "developer.ipAlias=${machine_ip}")
fi
