# Kubernetes eBPF Networking Observability Project

This project demonstrates how **kernel-level tracing using eBPF** can be used to diagnose networking issues in Kubernetes environments.  
The system deploys a simple microservice setup and introduces controlled network faults to observe how they affect both **kernel networking events and application performance**.

The project combines:

- Kubernetes microservice deployment
- Continuous traffic generation
- eBPF-based kernel observability
- Network fault injection
- Experiment automation and latency measurement

---

# Project Architecture

Traffic Pod → Kubernetes Service → Web Pod (nginx) → Linux Networking Stack → eBPF Tracing

The system allows correlation between:

- Network faults (packet loss, delay)
- Kernel-level events (retransmissions, drops)
- Application-level metrics (latency)

---

# Requirements

Install the following tools on your Linux system:

- Docker
- kubectl
- Kind (Kubernetes in Docker)
- bpftrace
- tc (traffic control)

---

# Installation

## Install Docker

```bash
sudo apt update
sudo apt install docker.io -y
## Steps to Run the GRS eBPF Kubernetes Project

### 1. Clone the Repository

```bash
git clone https://github.com/adi620/GRS-Project.git
cd GRS-Project
```

### 2. Verify Kubernetes Cluster

```bash
kubectl cluster-info
kubectl get nodes
```

### 3. Deploy the Web Application

```bash
kubectl apply -f web-deployment.yaml
```

### 4. Create the Web Service

```bash
kubectl apply -f web-service.yaml
```

### 5. Deploy the Traffic Generator Pod

```bash
kubectl apply -f traffic.yaml
```

### 6. Verify Pods are Running

```bash
kubectl get pods
```

### 7. Test Connectivity Between Pods

```bash
kubectl exec traffic -- curl web
```

### 8. Navigate to Measurement Directory

```bash
cd measurement
```

### 9. Make Scripts Executable

```bash
chmod +x run_baseline_test.sh
chmod +x measure_latency.sh
```

### 10. Run Baseline Latency Test

```bash
./run_baseline_test.sh
```

### 11. Run Latency Measurement Script

```bash
./measure_latency.sh
```

### 12. Navigate Back to Project Root

```bash
cd ..
```

### 13. Inject Fault Using eBPF

```bash
cd fault_injection
sudo ./inject_fault.sh
```

### 14. Measure Latency After Fault Injection

```bash
cd ../measurement
./measure_latency.sh
```

### 15. Cleanup (Optional)

```bash
kubectl delete -f web-deployment.yaml
kubectl delete -f web-service.yaml
kubectl delete -f traffic.yaml
```
