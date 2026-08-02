# Grafana

Grafana는 Prometheus datasource를 자동 등록하고 `infra` 네임스페이스에서 대시보드와 Grafana Alerting을 제공합니다.

## production HA 전제 조건

Grafana HA에서는 내장 SQLite를 사용할 수 없습니다. 두 StatefulSet replica가 하나의 외부 PostgreSQL 데이터베이스를 공유해야 합니다. production overlay는 Grafana 2 replicas와 PDB `minAvailable: 1`을 명시합니다.

Grafana Alerting은 `GF_UNIFIED_ALERTING_HA_PEERS`에 설정된 고정 Pod DNS로 peer를 구성합니다. 따라서 같은 alert rule의 평가·전송은 한 replica만 담당하며 장애 시 다른 replica가 이어받습니다. NetworkPolicy를 사용하는 클러스터는 Grafana pod 사이 TCP/9094를 허용해야 합니다.

## Secret 준비

PostgreSQL 접속 정보와 Grafana 관리자 계정을 Secret으로 제공합니다. 예시를 복사하고 모든 `REPLACE_*` 값을 변경합니다.

```sh
cp k8s/infra/grafana/secrets.example.yaml k8s/infra/grafana/secrets.yaml
kubectl apply -f k8s/infra/grafana/secrets.yaml
```

`grafana-database` Secret은 `GF_DATABASE_*` 환경 변수를 제공하며, `grafana-admin` Secret은 최초 관리자 계정을 제공합니다.

## 배포와 접속

```sh
# 로컬: Grafana 1 replica
kubectl apply -k k8s/infra/grafana/overlays/local

# production: Grafana 2 replicas와 PDB 적용
kubectl apply -k k8s/infra/grafana/overlays/production

kubectl port-forward -n infra service/grafana-web 3000:3000
```

Ingress 또는 Gateway를 사용하는 경우 `grafana-web:3000`을 노출하고 `GF_SERVER_ROOT_URL`을 실제 외부 URL에 맞춰 production overlay 또는 별도 patch에서 변경하십시오.

Prometheus datasource는 `http://prometheus.infra.svc:9090`으로 자동 등록됩니다. 수집 대상·PromQL·Alertmanager 알림 규칙은 [Prometheus 문서](../prometheus/README.md)를 참조하십시오.
