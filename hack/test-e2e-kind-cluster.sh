#!/usr/bin/env bash
set -eo pipefail

root="$(dirname "$0")/../"
export PATH="${PATH}:${root:?}bin"
export SRIOV_NETWORK_OPERATOR_IMAGE="${SRIOV_NETWORK_OPERATOR_IMAGE:-sriov-network-operator:latest}"
export SRIOV_NETWORK_CONFIG_DAEMON_IMAGE="${SRIOV_NETWORK_CONFIG_DAEMON_IMAGE:-origin-sriov-network-config-daemon:latest}"
RETRY_MAX=10
INTERVAL=10
TIMEOUT=300
MULTUS_CNI_DS="https://raw.githubusercontent.com/intel/multus-cni/master/images/multus-daemonset.yml"
test_pf_pci_addr="$1"

check_requirements() {
  for cmd in docker kind kubectl ip; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "$cmd is not available"
      exit 1
    fi
  done

  if [ "$test_pf_pci_addr" == "" ]; then
    echo "specify a physical function PCI address as an argument"
    echo "e.g. $0 0000:01:00.0"
    exit 1
  fi
  return 0
}

retry() {
  local status=0
  local retries=${RETRY_MAX:=5}
  local delay=${INTERVAL:=5}
  local to=${TIMEOUT:=20}
  cmd="$*"

  while [ $retries -gt 0 ]
  do
    status=0
    timeout $to bash -c "echo $cmd && $cmd" || status=$?
    if [ $status -eq 0 ]; then
      break;
    fi
    echo "Exit code: '$status'. Sleeping '$delay' seconds before retrying"
    sleep $delay
    let retries--
  done
  return $status
}

echo "## checking requirements"
check_requirements
echo "## delete any existing cluster, deploy control & data plane cluster with KinD"
retry kind delete cluster &&  cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF
echo "## build operator image"
retry docker build -t "${SRIOV_NETWORK_OPERATOR_IMAGE}" -f "${root}Dockerfile" "${root}"
echo "## load operator image into KinD"
kind load docker-image "${SRIOV_NETWORK_OPERATOR_IMAGE}"
echo "## build daemon image"
retry docker build -t "${SRIOV_NETWORK_CONFIG_DAEMON_IMAGE}" -f "${root}Dockerfile.sriov-network-config-daemon" "${root}"
echo "## load daemon image into KinD"
kind load docker-image "${SRIOV_NETWORK_CONFIG_DAEMON_IMAGE}"
echo "## export kube config for utilising locally"
kind export kubeconfig
echo "## exporting KUBECONFIG environment variable to access KinD K8 API server"
export KUBECONFIG="${HOME}/.kube/config"
echo "## wait for coredns"
retry kubectl -n kube-system wait --for=condition=available deploy/coredns --timeout=${TIMEOUT}s
echo "## install multus"
retry kubectl create -f "$MULTUS_CNI_DS"
echo "## wait for multus"
retry kubectl -n kube-system wait --for=condition=ready -l name=multus pod --timeout=${TIMEOUT}s
echo "## find KinD container"
kind_container="$(docker ps -q --filter 'name=kind-worker')"
echo "## validate KinD cluster formed"
[ "$kind_container" == "" ] && echo "could not find a KinD container 'kind-worker'" && exit 5
echo "## make KinD's sysfs writable (required to create VFs)"
docker exec "$kind_container" mount -o remount,rw /sys
echo "## label KinD's control-plane-node as sriov capable"
kubectl label node kind-worker feature.node.kubernetes.io/network-sriov.capable=true --overwrite
echo "## label KinD worker as worker"
kubectl label node kind-worker node-role.kubernetes.io/worker= --overwrite
echo "## building PF/VF netns setter"
go build -o "${root}/hack/pf-vf-netns-set" "${root}/hack/pf-vf-netns-set.go"
echo "## retrieving netns path from container"
netnspath="$(docker inspect --format '{{ .NetworkSettings.SandboxKey }}' "${kind_container}")"
echo "## deploying monitoring of PF/VF network namespace"
"${root}hack/pf-vf-netns-set" --pfpciaddress "${test_pf_pci_addr}" --netnspath "${netnspath}" &
netns_set_pid=$!
echo "## deploying SRIOV Network Operator"
make --directory "${root}" deploy-setup-k8s || true
echo "## Executing E2E tests"
make --directory "${root}" test-e2e-k8s || true
echo "## terminating PF/VF network namespace setter"
kill -9 ${netns_set_pid}