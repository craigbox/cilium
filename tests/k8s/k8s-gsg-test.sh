#!/bin/bash

NAMESPACE="kube-system" 

source "../helpers.bash"
source /home/vagrant/.profile
function cleanup {
	kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/master/examples/minikube/l3_l4_l7_policy.yaml
	kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/master/examples/minikube/l3_l4_policy.yaml
	kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/master/examples/minikube/demo.yaml
	kubectl delete -f cilium-ds.yaml
	kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/master/examples/kubernetes/rbac.yaml
}

trap cleanup exit

echo "KUBECONFIG: $KUBECONFIG"

cleanup

until [ "$(kubectl get cs | grep -v "STATUS" | grep -c "Healthy")" -eq "3" ]; do 
	echo "---- Waiting for cluster to get into a good state ----"
done


echo "----- adding RBAC for Cilium -----"
kubectl create -f https://raw.githubusercontent.com/cilium/cilium/master/examples/kubernetes/rbac.yaml

echo "----- deploying Cilium Daemon Set onto cluster -----"
wget https://raw.githubusercontent.com/cilium/cilium/master/examples/kubernetes/cilium-ds.yaml
sed -i s/"\/var\/lib\/kubelet\/kubeconfig"/"\/etc\/kubernetes\/kubelet.conf"/g cilium-ds.yaml
sed -i s/"cilium\/cilium:stable"/"localhost:5000\/cilium:${DOCKER_IMAGE_TAG}"/g cilium-ds.yaml
kubectl apply -f cilium-ds.yaml

until [ "$(kubectl get ds --namespace ${NAMESPACE} | grep -v 'READY' | awk '{ print $4}' | grep -c '1')" -eq "3" ]; do
	echo "----- Waiting for Cilium to get into 'ready' state in Minikube cluster -----"
done

CILIUM_POD=$(kubectl -n ${NAMESPACE} get pods -l k8s-app=cilium | grep -v 'AGE' | awk '{ print $1 }')
wait_for_kubectl_cilium_status ${NAMESPACE} ${CILIUM_POD}

echo "----- deploying demo application onto cluster -----"
kubectl create -f https://raw.githubusercontent.com/cilium/cilium/master/examples/minikube/demo.yaml

until [ "$(kubectl get pods | grep -v STATUS | grep -c "Running")" -eq "4" ]; do
	echo "----- Waiting for demo apps to get into 'Running' state -----"
done

echo "----- adding L3 L4 policy  -----"
kubectl create -f https://raw.githubusercontent.com/cilium/cilium/master/examples/minikube/l3_l4_policy.yaml

until [ "$(kubectl -n ${NAMESPACE} exec ${CILIUM_POD} cilium endpoint list | grep -c 'ready')" -eq "5" ]; do
	echo "----- Waiting for endpoints to get into 'ready' state -----"
done

echo "----- testing L3/L4 policy -----"
APP2_POD=$(kubectl get pods -l id=app2 -o jsonpath='{.items[0].metadata.name}')
SVC_IP=$(kubectl get svc app1-service -o jsonpath='{.spec.clusterIP}' )

echo "----- testing app2 can reach app1 (expected behavior: can reach) -----"
RETURN=$(kubectl $ID exec $APP2_POD -- curl -s --output /dev/stderr -w '%{http_code}' --connect-timeout 10 -XGET $SVC_IP)
if [[ "${RETURN//$'\n'}" != "200" ]]; then
	abort "Error: could not reach pod allowed by L3 L4 policy"
fi

echo "----- testing that app3 cannot reach app 1 (expected behavior: cannot reach)"
APP3_POD=$(kubectl get pods -l id=app3 -o jsonpath='{.items[0].metadata.name}')
RETURN=$(kubectl exec $APP3_POD -- curl -s --output /dev/stderr -w '%{http_code}' --connect-timeout 10 -XGET $SVC_IP)
if [[ "${RETURN//$'\n'}" != "000" ]]; then
	abort "Error: unexpectedly reached pod allowed by L3 L4 Policy, received return code ${RETURN}"
fi

echo "------ performing HTTP GET on ${SVC_IP}/public from service2 ------"
RETURN=$(kubectl exec $APP2_POD -- curl -s --output /dev/stderr -w '%{http_code}' --connect-timeout 10 http://${SVC_IP}/public)
if [[ "${RETURN//$'\n'}" != "200" ]]; then
	abort "Error: Could not reach ${SVC_IP}/public on port 80"
fi

echo "------ performing HTTP GET on ${SVC_IP}/private from service2 ------"
RETURN=$(kubectl exec $APP2_POD -- curl -s --output /dev/stderr -w '%{http_code}' --connect-timeout 10 http://${SVC_IP}/private)
if [[ "${RETURN//$'\n'}" != "200" ]]; then
	abort "Error: Could not reach ${SVC_IP}/public on port 80"
fi

echo "----- creating L7-aware policy -----"
kubectl create -f https://raw.githubusercontent.com/cilium/cilium/master/examples/minikube/l3_l4_l7_policy.yaml

CILIUM_POD=$(kubectl -n ${NAMESPACE} get pods -l k8s-app=cilium | grep -v 'AGE' | awk '{ print $1 }')
until [ "$(kubectl -n ${NAMESPACE} exec ${CILIUM_POD} cilium endpoint list | grep -c 'ready')" -eq "5" ]; do
       echo "----- Waiting for endpoints to get into 'ready' state -----"
done

echo "------ performing HTTP GET on ${SVC_IP}/public from service2 ------"
RETURN=$(kubectl exec $APP2_POD -- curl -s --output /dev/stderr -w '%{http_code}' --connect-timeout 10 http://${SVC_IP}/public)
if [[ "${RETURN//$'\n'}" != "200" ]]; then
	abort "Error: Could not reach ${SVC_IP}/public on port 80"
fi

echo "------ performing HTTP GET on ${SVC_IP}/private from service2 ------"
RETURN=$(kubectl exec $APP2_POD -- curl -s --output /dev/stderr -w '%{http_code}' --connect-timeout 10 http://${SVC_IP}/private)
if [[ "${RETURN//$'\n'}" != "403" ]]; then
	abort "Error: Unexpected success reaching  ${SVC_IP}/private on port 80"
fi

echo "------ L7 policy success ! ------"
