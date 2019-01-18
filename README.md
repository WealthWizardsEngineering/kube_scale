# kube_scale
Sample bash script to help scaling Kubernetes deployments to zero and back to initial size in a given namespace or cluster wide.
In conjunction with [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml) and a cron job, you get scheduled Kube cluster scaling.
#

```
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
```

This script assumes Istio is installed on the cluster. Istio components are not scaled to zero, but down to 1 pod and back to initial size when needed. Obviously, feel free to use it if/as you see it.


If you have a Jenkins server somewhere, then you can do something like (or just use your favourite cron scheduler): 

```
.............................................................................................
  properties ([
    parameters([
      string(name: 'action', defaultValue: 'test', description: 'Scaling action. Use scale_to_zero or scale_to_initial_size'),
      string(name: 'namespace', defaultValue: '', description: 'Namespace to scale (i.e. saturn-green, or use all to apply cluster wide)'),
      string(name: 'reason', defaultValue: '', description: 'Scaling reason')
    ]),
    pipelineTriggers([
        parameterizedCron('''
          20 00 * * 2-6 %action=scale_to_zero;namespace=all;reason=triggered_by_cron
          00 05 * * 1-5 %action=scale_to_initial_size;namespace=all;reason=triggered_by_cron
        ''')
    ])
  ])
  ...................................................................................
          sh """
            export KUBECONFIG=${kubectl_config_file}
            ./deployments_scale.sh -a ${action} -n ${namespace} -r ${reason}
        """
...................................................................................       

```
