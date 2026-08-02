# Prometheus와 Alertmanager

Prometheus, Alertmanager, node-exporter, kube-state-metrics를 `infra` 네임스페이스에 배포합니다. Helm은 사용하지 않습니다.

## 구성

| 구성 요소 | 역할 | production HA |
| --- | --- | --- |
| Prometheus | 메트릭 수집·규칙 평가 | StatefulSet 2 replicas, replica별 PVC |
| Alertmanager | 경보 그룹화·중복 제거·전송 | StatefulSet 3 replicas, gossip cluster |
| node-exporter | 노드 CPU·메모리·디스크 메트릭 | DaemonSet |
| kube-state-metrics | Kubernetes 오브젝트 상태 | Deployment |

`base`는 `openebs-local`을 기본 StorageClass로 사용합니다. 이 로컬 PV는 노드에 고정되므로 운영에서는 `overlays/production/kustomization.yaml`의 `REPLACE_MULTI_NODE_STORAGE_CLASS`를 다중 노드에서 사용할 수 있는 StorageClass 이름으로 바꾸십시오.

## Secret 준비

Alertmanager Slack Webhook을 Secret으로 제공합니다. 예시 파일을 복사해 실제 값으로 바꾼 뒤 적용합니다.

```sh
cp k8s/infra/prometheus/base/alertmanager-secret.example.yaml k8s/infra/prometheus/alertmanager-secret.yaml
# alertmanager-secret.yaml의 REPLACE_WITH_SLACK_WEBHOOK_URL 변경
kubectl apply -f k8s/infra/prometheus/alertmanager-secret.yaml
```

## 배포

```sh
# 로컬: Prometheus와 Alertmanager 각각 1 replica
kubectl apply -k k8s/infra/prometheus/overlays/local

# production: Prometheus 2, Alertmanager 3 replicas
kubectl apply -k k8s/infra/prometheus/overlays/production
```

확인 명령입니다.

```sh
kubectl get pods,pvc,endpoints -n infra
kubectl port-forward -n infra service/prometheus 9090:9090
```

Prometheus의 **Status > Targets**에서 `kubernetes-nodes`, `node-exporter`, `kube-state-metrics`가 `UP`인지 확인합니다.

## 메트릭과 경보

다음 PromQL을 Grafana 또는 Prometheus에서 조회할 수 있습니다.

```promql
# 노드 CPU 사용률
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# namespace별 Ready가 아닌 Pod 수
sum by (namespace) (kube_pod_status_ready{condition="true"} == 0)

# 최근 15분 동안 반복 재시작한 컨테이너
increase(kube_pod_container_status_restarts_total[15m]) > 3
```

기본 경보는 `KubernetesNodeNotReady`, `KubernetesPodCrashLooping`, `KubernetesPodNotReady`입니다. 추가 규칙은 [base/prometheus-config.yaml](base/prometheus-config.yaml)의 `alerts.yaml`에 정의합니다.

두 Prometheus replica가 동일 규칙을 평가해도 Alertmanager 3-member cluster가 동일 fingerprint를 deduplication하므로 Slack에는 한 건만 전송됩니다. 이메일·PagerDuty 수신기는 [base/alertmanager.yaml](base/alertmanager.yaml)의 `receivers`와 `route`에 추가하며 토큰은 Secret으로 관리하십시오.

Prometheus replica는 로컬 TSDB를 공유하지 않습니다. 장기 보관, 전역 조회, replica deduplication이 필요하면 Thanos 또는 Mimir를 별도 계층으로 추가합니다.
