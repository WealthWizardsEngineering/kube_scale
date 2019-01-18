#!/usr/bin/env bash

set -o pipefail

usage() {
  echo 'usage: deployments_scale.sh [-a | --action] [-n | --namespace] [-r | --reason] | [-h]'
  echo ''
  echo 'It scales kubernetes deployments to zero or initial size in a given namespace'
  echo ''
  echo ' -a, --action    Action to perform. Can be one of: "scale_to_zero" or "scale_to_initial_size"'
  echo ' -n, --namespace Namespace to use. Use "all" to run cluster-wide with the exception of: kube-system, paltform, istio* namespaces'
  echo ' -r, --reason    Reason that prompted the scaling operation (must not contain spaces!)'
  echo ' -h, --help      Prints this message'
  echo ''
  echo 'deployments_scale.sh -a scale_to_zero -n saturn-green -r OPS-7777'
  exit 1
}

if [[ -z "$1" ]]; then
  usage
  exit 1
fi

while test $# -gt 0; do
    case $1 in
        -a | --action)
          shift
          [[ -z "$1" ]] && usage || ACTION=$1
          ;;
        -n | --namespace)  
          shift
          [[ -z "$1" ]] && usage || NAMESPACE=$1
          ;;
        -r | --reason)
          shift
          [[ -z "$1" ]] && usage
          [[ "$1" =~ ^[tT][eE][sS][tT] ]] && TEST_MODE="true"
          REASON=$1
          ;;
        -h | --help)        
          usage
          ;;
        * )
          usage
          ;;
    esac
    shift
done

echo "ACTION:    $ACTION"
echo "NAMESPACE: $NAMESPACE"
echo

EXCLUDE_NS="kube\|platform\|istio\|ingress"

case $NAMESPACE in
  all)
    NAMESPACE_LIST=$(kubectl get ns --no-headers=true | grep -v $EXCLUDE_NS | awk '{print $1}')
    ;;
  *)
    NAMESPACE_LIST=$NAMESPACE
    ;;  
esac

scale_to_zero() {
  local NAMESPACE=$1
  local NAME="deployment-replicas"
  echo "scale to zero: $NAMESPACE"

  KUBECTL_COMMAND="kubectl -n ${NAMESPACE}"
  TMP_DIR=$(mktemp -dt $NAME.XXXXXXX)

  $KUBECTL_COMMAND get deployments -o json | jq -r '.items[] | "\(.metadata.name) \(.spec.replicas)"' \
    > $TMP_DIR/$NAME.txt

  if [[ ${TEST_MODE} == "true" ]] ; then
    echo "Running in test mode, deployment scaling will not take place"
    cat $TMP_DIR/$NAME.txt
    return
  fi

  PREVIOUS_ACTION=$($KUBECTL_COMMAND get cm $NAME --no-headers=true -o=custom-columns=NAME:.data.previous_action)

  if [[ ${PREVIOUS_ACTION} == "scale_to_zero" ]]; then
    echo "Namespace ${NAMESPACE} was already scaled to zero, skipping it"
    return
  else
    # Now we can safely scale to zero
    $KUBECTL_COMMAND delete cm $NAME
    $KUBECTL_COMMAND create cm $NAME \
      --from-file=$NAME=$TMP_DIR/$NAME.txt \
      --from-literal=previous_action=scale_to_zero

    cat $TMP_DIR/$NAME.txt | \
      awk '{print $1}' | \
      xargs $KUBECTL_COMMAND scale deployment --current-replicas=-1 --replicas=0
  fi
}


scale_to_initial_size() {
  local NAMESPACE=$1
  local NAME="deployment-replicas"
  echo "scale to initial size: $NAMESPACE"

  KUBECTL_COMMAND="kubectl -n ${NAMESPACE}"

  if [[ ${TEST_MODE} == "true" ]] ; then
    echo "Running in test mode, deployment scaling will not take place"
    $KUBECTL_COMMAND get configmap $NAME \
      --no-headers=true \
      -o=custom-columns=NAME:.data.$NAME
  else
    $KUBECTL_COMMAND get configmap $NAME \
      --no-headers=true \
      -o=custom-columns=NAME:.data.$NAME | \
      grep -v -e '^$' | \
      awk -v KUBECTL_COMMAND="$KUBECTL_COMMAND" '{system(KUBECTL_COMMAND" scale deployment "$1" --current-replicas=-1 --replicas="$2)}'

    # Update 'previous_action' so we can scale down later on
    $KUBECTL_COMMAND patch cm $NAME -p '{"data":{"previous_action":"scale_to_initial_size"}}'
  fi
}

istio_scale_down() {
  local NAME="hpa-replicas"
  local TMP_DIR=$(mktemp -dt $NAME.XXXXXXX)
  local KUBECTL_COMMAND="kubectl -n istio-system"

  $KUBECTL_COMMAND get hpa -o json | \
  jq -r '.items[] | "\(.metadata.name) \(.spec.minReplicas) \(.spec.maxReplicas)"' \
  > $TMP_DIR/$NAME.txt

  if [[ ${TEST_MODE} == "true" ]] ; then
    echo "Running in test mode, istio hpa scaling will not take place"
    cat $TMP_DIR/$NAME.txt
    return
  fi

  PREVIOUS_ACTION=$($KUBECTL_COMMAND get cm $NAME --no-headers=true -o=custom-columns=NAME:.data.previous_action)

  if [[ ${PREVIOUS_ACTION} == "scale_to_one" ]]; then
    echo "Istio HPA were already scaled down, skipping it"
    return
  else
    # Now we can safely scale down
    $KUBECTL_COMMAND delete cm $NAME
    $KUBECTL_COMMAND create cm $NAME \
      --from-file=$NAME=$TMP_DIR/$NAME.txt \
      --from-literal=previous_action=scale_to_one

    cat $TMP_DIR/$NAME.txt | \
      awk '{print $1}' | \
      xargs $KUBECTL_COMMAND patch hpa -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'
  fi
}


istio_scale_up() {
  local NAME="hpa-replicas"
  local KUBECTL_COMMAND="kubectl -n istio-system"
  local TMP_DIR=$(mktemp -dt $NAME.XXXXXXX)

  echo "Scaling istio to initial size"

  if [[ ${TEST_MODE} == "true" ]] ; then
    echo "Running in test mode, istio scaling will not take place"
    $KUBECTL_COMMAND get configmap $NAME \
      --no-headers=true \
      -o=custom-columns=NAME:.data.$NAME
  else
    $KUBECTL_COMMAND get configmap $NAME \
      --no-headers=true \
      -o=custom-columns=NAME:.data.$NAME | \
      grep -v -e '^$' |
      awk -v Q="'" \
        -v KUBECTL_COMMAND="$KUBECTL_COMMAND" \
        '{system(KUBECTL_COMMAND" patch hpa "$1" -p "Q"{\"spec\":{\"minReplicas\":"$2",\"maxReplicas\":"$3"}}"Q )}'

    # Update 'previous_action' so we can scale down later on
    $KUBECTL_COMMAND patch cm $NAME -p '{"data":{"previous_action":"scale_to_initial_size"}}'
  fi
}

case $ACTION in
  scale_to_zero) 
    for i in $NAMESPACE_LIST; do
      scale_to_zero $i
    done

    if [[ $NAMESPACE == "all" ]]; then
      istio_scale_down
    fi
    ;;
  scale_to_initial_size)
    if [[ $NAMESPACE == "all" ]]; then
      istio_scale_up
    fi

    for i in $NAMESPACE_LIST; do
      scale_to_initial_size $i
    done
    ;;
  *)
    echo "Unsuported action: $ACTION"
    echo "Use 'scale_to_zero' or 'scale_to_initial_size' instead."
    exit 1
    ;;
esac
