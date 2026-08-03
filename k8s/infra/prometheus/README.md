# Prometheus와 Alertmanager

Prometheus, Alertmanager, node-exporter, kube-state-metrics를 `infra` 네임스페이스에 배포합니다. Helm은 사용하지 않습니다.

## 구성

| 구성 요소 | 역할 | production HA |
| --- | --- | --- |
| Prometheus | 메트릭 수집·규칙 평가 | StatefulSet 2 replicas, replica별 PVC |
| Alertmanager | 경보 그룹화·중복 제거·전송 | StatefulSet 3 replicas, gossip cluster |
| node-exporter | 노드 CPU·메모리·디스크 메트릭 | DaemonSet |
| kube-state-metrics | Kubernetes 오브젝트 상태 | Deployment |

`base`는 `openebs-hostpath`를 기본 StorageClass로 사용합니다. 이 로컬 PV는 노드에 고정되므로 운영에서는 `overlays/production/kustomization.yaml`의 `REPLACE_MULTI_NODE_STORAGE_CLASS`를 다중 노드에서 사용할 수 있는 StorageClass 이름으로 바꾸십시오.

## Prometheus 수집 설정

[prometheus.yaml](prometheus.yaml)은 `prometheus.yml.example`을 바탕으로 만든 실제 수집 설정입니다. 패키지 루트 Kustomization이 이 파일을 `prometheus-config` ConfigMap의 `prometheus.yml` 키로 생성하고, Prometheus 컨테이너의 `/etc/prometheus/prometheus.yml`에 읽기 전용으로 마운트합니다. 따라서 annotation 기반 자동 수집 대상을 추가할 때에는 이 파일을 수정하면 됩니다.

Kustomize로 설정을 반영한 뒤에는 Prometheus가 새 파일을 읽도록 Pod를 재시작합니다.

```sh
kubectl apply -k k8s/infra/prometheus/overlays/local
kubectl rollout restart statefulset/prometheus -n infra
```

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

# Kubernetes Service 자동 수집

이 설정은 모든 네임스페이스의 Kubernetes Endpoints를 감시한다. Service에 아래 annotation을 붙이면 같은 Service가 가리키는 각 Pod 또는 exporter endpoint가 `kubernetes-annotated-services` 작업에 자동 등록된다. 새 Service를 추가하거나 Pod 수가 바뀔 때 `prometheus.yml`을 수정하거나 다시 불러올 필요는 없다.

| annotation | 필수 여부 | 동작 |
| --- | --- | --- |
| `prometheus.io/scrape: "true"` | 필수 | 해당 Service만 수집한다. |
| `prometheus.io/path` | 선택 | 비어 있거나 없으면 `/metrics`를 사용한다. |
| `prometheus.io/scheme` | 선택 | 비어 있거나 없으면 `http`를 사용하며, `http` 또는 `https`를 지정한다. |

수집 대상 Service와 Pod의 `app.kubernetes.io/*` 레이블은 Prometheus 레이블에서 점과 슬래시가 밑줄로 바뀐다. 예를 들어 `app.kubernetes.io/name`은 `app_kubernetes_io_name`이 되며, 둘 다 있으면 Service 값을 우선한다. 또한 `namespace`, `service`, `pod`, `node`, `endpoint_port`가 가능한 경우 자동으로 붙는다. `pod`는 재배포 때 바뀔 수 있으므로 일반 대시보드는 `service`나 `app_kubernetes_io_name`으로 묶고, 장애 분석 때 `pod`로 좁히는 것이 좋다.

## Service 예시

Spring Boot Actuator는 전용 metrics Service의 경로만 바꾼다. 애플리케이션에는 Actuator와 Prometheus registry가 활성화되어 있어야 한다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: spring-api-metrics
  namespace: application
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /actuator/prometheus
  labels:
    app.kubernetes.io/name: spring-api
    app.kubernetes.io/component: api
spec:
  selector:
    app.kubernetes.io/name: spring-api
  ports:
    - name: metrics
      port: 8080
      targetPort: http
```

일반 exporter가 기본 `/metrics`를 제공하면 경로 annotation은 생략한다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cache-exporter-metrics
  namespace: data
  annotations:
    prometheus.io/scrape: "true"
  labels:
    app.kubernetes.io/name: cache-exporter
    app.kubernetes.io/component: exporter
spec:
  selector:
    app.kubernetes.io/name: cache-exporter
  ports:
    - name: metrics
      port: 9121
      targetPort: metrics
```

Service port는 이름이 있어야 하며 `metrics`를 권장한다. 이 설정은 이름 없는 포트와 Endpoints에 직접 포함되지 않은 추가 Pod 포트를 버린다.

## 플랫폼별 exporter

데이터베이스나 캐시가 Prometheus 형식의 메트릭을 직접 제공하는 것은 아니다. 일반적으로 별도 exporter가 플랫폼 API에 접속하고, exporter의 `/metrics`를 위와 같은 Service로 노출한다. 접속 정보와 자격 증명은 exporter의 Secret 등에서 관리하며 Prometheus annotation에 넣지 않는다.

- PostgreSQL: `postgres_exporter`
- MySQL/MariaDB: `mysqld_exporter`
- MongoDB: `mongodb_exporter`
- Redis: `redis_exporter`
- Elasticsearch: `elasticsearch_exporter`
- Kafka: Prometheus JMX Exporter
- NGINX: NGINX Prometheus Exporter
- Kubernetes 노드: `node_exporter`

여러 포트를 가진 애플리케이션 Service에 수집 annotation을 직접 붙이면 의도하지 않은 애플리케이션 포트도 후보가 될 수 있다. 같은 selector를 사용하되 이름이 `metrics`인 포트 하나만 가진 전용 metrics Service를 만들고, 그 Service에만 annotation을 붙인다. exporter가 여러 메트릭 포트를 제공하는 경우에도 목적별 전용 Service로 분리한다.

## Kubernetes RBAC

모든 네임스페이스를 검색하므로 Prometheus ServiceAccount에는 ClusterRole이 필요하다. Kubernetes의 읽기 권한은 `get`이며, 지속적인 자동 감지를 위해 `list`, `watch`도 필요하다. 다음은 services, endpoints, pods, nodes와 최신 Kubernetes의 EndpointSlices를 읽는 최소 규칙이다. 현재 설정은 요구 사항에 따라 `endpoints` 역할을 사용하며, EndpointSlices 권한은 해당 역할로 전환할 때 사용한다.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-discovery
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-discovery
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-discovery
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: monitoring
```

## 설정 반영과 Grafana

Service, Endpoint 또는 Pod의 변경은 Kubernetes discovery가 자동 반영하므로 reload가 필요 없다. `prometheus.yml` 자체를 바꿨다면 먼저 `promtool check config prometheus.yml`로 검사한 뒤 다음 방법 중 배포 방식에 맞는 하나로 반영한다.

- Prometheus 프로세스에 `SIGHUP`을 보낸다.
- `--web.enable-lifecycle`이 활성화된 경우 `POST /-/reload`를 호출한다.
- 위 방법을 제공하지 않는 배포에서는 Prometheus Pod를 롤링 재시작한다.

Grafana는 수집 대상을 직접 scrape하지 않는다. Grafana의 데이터 소스로 Prometheus를 등록하고, Prometheus가 저장한 메트릭을 PromQL로 조회한다.
