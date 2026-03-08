# Kubernetes eBPF Networking Project

## Setup

Install:

- Docker
- kubectl
- kind
- bpftrace

Create cluster:

kind create cluster --name k8s-ebpf

Deploy services:

kubectl apply -f web-deployment.yaml
kubectl apply -f web-service.yaml

Generate traffic:

kubectl apply -f traffic.yaml