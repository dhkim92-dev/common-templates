# ELK 로그 수집

`infra` 네임스페이스에 Elasticsearch, Kibana, Logstash를 배포합니다. Helm은 사용하지 않습니다. Logstash는 Beats 입력 포트 `5044`를 열고, 수신한 이벤트를 일 단위 `logs-YYYY.MM.dd` 인덱스에 저장합니다.

## 구성과 보안

| 구성 요소 | 역할 | 기본 구성 |
| --- | --- | --- |
| Elasticsearch | 로그 저장·검색 API | local/test: StatefulSet 1 replica, production: StatefulSet 3 replicas |
| Logstash | Filebeat 이벤트 수신·전송 | Deployment, `logstash.infra.svc:5044` |
| Kibana | 로그 조회 UI | Deployment, `kibana.infra.svc:5601` |

Elasticsearch 보안은 활성화되어 있습니다. 처음 기동할 때 `elk-credentials` Secret의 `elastic-password` 값이 내장 관리자 계정 `elastic`의 초기 비밀번호가 됩니다. `kibana_system`과 최소 권한 `logstash_internal` 계정은 `elk-credentials-init` Job이 생성합니다. 따라서 관리자 비밀번호와 초기 계정 비밀번호를 생성 전에 지정할 수 있습니다.

local/test 오버레이는 `discovery.type=single-node`인 단일 Elasticsearch 노드입니다. production 오버레이는 3개 Elasticsearch 노드로 구성되며, headless Service를 통한 노드 discovery와 transport TLS를 사용합니다. 세 노드가 모두 master-eligible이므로 한 노드가 중단되어도 quorum을 유지합니다. Pod anti-affinity가 세 노드를 서로 다른 Kubernetes 노드에 배치하고, PodDisruptionBudget은 자발적 중단 때 최소 두 노드를 유지합니다. 따라서 production 클러스터에는 최소 3개의 스케줄 가능한 노드가 필요합니다. 외부 노출은 Ingress나 Gateway에서 HTTP TLS와 인증 정책을 별도로 적용하십시오.

## Secret 준비

예시를 복사해 세 값을 서로 다른 난수로 바꾼 뒤 적용합니다. 실제 Secret 파일은 커밋하지 않습니다.

```sh
cp k8s/infra/elk/secrets.example.yaml k8s/infra/elk/secrets.yaml
# secrets.yaml의 REPLACE_WITH_* 값을 변경
kubectl apply -f k8s/infra/elk/secrets.yaml
```

비밀번호를 변경한 경우에는 Secret을 적용한 뒤 초기화 Job을 다시 실행합니다.

```sh
kubectl delete job -n infra elk-credentials-init
kubectl apply -k k8s/infra/elk/overlays/local
```

## 배포와 확인

Logstash 파이프라인을 변경하려면 예시를 실제 ConfigMap 파일로 복사한 뒤 `beats.conf`를 수정합니다.

```sh
cp k8s/infra/elk/logstash_pipeline_configmap.example.yaml \
  k8s/infra/elk/logstash_pipeline_configmap.yaml
# logstash_pipeline_configmap.yaml의 data.beats.conf 수정
kubectl apply -f k8s/infra/elk/logstash_pipeline_configmap.yaml
```

```sh
# 로컬
kubectl apply -k k8s/infra/elk/overlays/local

# production: 아래의 인증서 Secret과 PVC StorageClass 값을 먼저 지정
kubectl apply -k k8s/infra/elk/overlays/production

kubectl get pods,pvc,svc -n infra
kubectl logs -n infra job/elk-credentials-init
kubectl get service -n infra kibana
```

`kibana`는 `NodePort` 서비스입니다. 위 명령의 `PORT(S)`에 표시되는 NodePort와 노드 IP를 사용해 `http://<node-ip>:<node-port>`로 접속합니다. `elastic` 계정과 `elastic-password` 값으로 로그인한 뒤 Kibana **Discover**에서 `logs-*` 데이터 뷰를 만들면 수집 로그를 조회할 수 있습니다.

### Logstash 설정 변경

Logstash 설정은 용도별로 두 ConfigMap으로 분리합니다.

| ConfigMap | 파일 | 변경 반영 방식 |
| --- | --- | --- |
| `logstash-pipeline` | `logstash_pipeline_configmap.yaml`의 `beats.conf` | 자동 재로딩 |
| `logstash-settings` | `logstash.yml` | Pod 재시작 필요 |

`logstash-settings`의 `config.reload.automatic: true`와 `config.reload.interval: 5s`로 인해, `logstash-pipeline` ConfigMap의 변경은 볼륨 갱신 뒤 Logstash가 자동으로 다시 읽습니다. Kubernetes의 ConfigMap 볼륨 갱신에는 보통 수십 초 정도의 지연이 있을 수 있습니다.

`logstash_pipeline_configmap.yaml`은 환경별 파이프라인을 사용자가 관리하는 파일이므로 Kustomize 오버레이에는 포함하지 않습니다. 파일을 수정할 때마다 `kubectl apply -f k8s/infra/elk/logstash_pipeline_configmap.yaml`로 ConfigMap을 갱신하십시오.

파이프라인 문법 오류가 있는 새 설정은 적용되지 않으며, 기존에 정상 동작하던 파이프라인이 계속 사용됩니다. `logstash.yml`, JVM 옵션, 플러그인처럼 런타임 설정을 바꾼 경우에는 다음처럼 명시적으로 재시작하십시오.

```sh
kubectl rollout restart deployment/logstash -n infra
kubectl rollout status deployment/logstash -n infra
```

### production Elasticsearch 인증서와 스토리지

production은 `elasticsearch-transport-tls` Secret 없이는 기동하지 않습니다. Secret에는 `ca.crt`, `tls.crt`, `tls.key` 키가 필요합니다. 세 Pod가 사용하는 인증서에는 최소한 다음 DNS SAN을 포함하십시오.

- `elasticsearch-0.elasticsearch-headless.infra.svc`
- `elasticsearch-1.elasticsearch-headless.infra.svc`
- `elasticsearch-2.elasticsearch-headless.infra.svc`

사내 CA 또는 인증서 관리 체계로 해당 파일을 발급한 뒤 다음처럼 생성합니다. 실제 개인키와 인증서는 Git에 커밋하지 않습니다. 키 형식은 암호화되지 않은 PEM이어야 합니다.

```sh
kubectl create secret generic elasticsearch-transport-tls \
  --namespace infra \
  --from-file=ca.crt=/secure/path/ca.crt \
  --from-file=tls.crt=/secure/path/tls.crt \
  --from-file=tls.key=/secure/path/tls.key
```

`overlays/production/transport-tls.secret.example.yaml`은 Secret의 키 구조만 보여 주는 예시입니다. placeholder 값을 적용하지 마십시오.

운영 오버레이의 `REPLACE_MULTI_NODE_STORAGE_CLASS`를 클라우드에서 다중 노드에 사용할 StorageClass 이름으로 바꾼 뒤 적용하십시오. 각 노드는 독립적인 200Gi RWO PVC를 사용합니다. 기본 `openebs-hostpath`는 노드 고정 볼륨이므로 다중 노드 production 용도로 사용하지 않습니다.

처음 production 클러스터를 생성한 후 green 상태를 확인합니다.

```sh
kubectl get pods -n infra -l app.kubernetes.io/name=elasticsearch
kubectl exec -n infra elasticsearch-0 -- \
  curl --fail -u elastic:<elastic-password> http://localhost:9200/_cluster/health?pretty
```

`cluster.initial_master_nodes`는 새 클러스터의 최초 부트스트랩에만 필요한 값입니다. 정상적으로 클러스터가 구성된 뒤에는 `overlays/production/elasticsearch-production.yaml`에서 해당 환경 변수를 제거하고 다시 적용하십시오. 기존 데이터 PVC를 삭제하지 않은 상태에서 노드를 재시작하거나 수를 조정할 때는 이 값을 다시 추가하지 않습니다.

## Filebeat로 애플리케이션 로그 수집

Spring Boot 애플리케이션은 Logback file appender로 공유 볼륨의 파일에 로그를 기록하고, 같은 Pod의 Filebeat sidecar가 그 파일을 읽어 Logstash로 전송하는 방식입니다. Filebeat는 파일 offset을 registry에 기록하므로 컨테이너가 재시작되어도 이미 전송한 위치부터 계속 읽습니다. 로그 파일과 Filebeat registry를 각각 `emptyDir`로 공유합니다.

애플리케이션 Pod의 두 컨테이너가 같은 `app-logs` 볼륨을 마운트해야 합니다.

```yaml
spec:
  containers:
    - name: app
      volumeMounts:
        - name: app-logs
          mountPath: /var/log/app
    - name: filebeat
      image: docker.elastic.co/beats/filebeat:8.19.17
      args: ["-e", "-c", "/etc/filebeat/filebeat.yml"]
      volumeMounts:
        - name: app-logs
          mountPath: /var/log/app
          readOnly: true
        - name: filebeat-data
          mountPath: /usr/share/filebeat/data
        - name: filebeat-config
          mountPath: /etc/filebeat/filebeat.yml
          subPath: filebeat.yml
  volumes:
    - name: app-logs
      emptyDir: {}
    - name: filebeat-data
      emptyDir: {}
    - name: filebeat-config
      configMap:
        name: app-filebeat-config
```

`app-filebeat-config` ConfigMap의 핵심 설정입니다. 애플리케이션별 label과 namespace를 추가하면 Kibana에서 필터하기 쉽습니다.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-filebeat-config
data:
  filebeat.yml: |
    filebeat.inputs:
      - type: filestream
        id: application-log
        paths: ["/var/log/app/*.log"]
        parsers:
          - ndjson:
              target: ""
              add_error_key: true
    processors:
      - add_fields:
          target: labels
          fields:
            application: REPLACE_APPLICATION_NAME
    output.logstash:
      hosts: ["logstash.infra.svc:5044"]
```

Logback은 `/var/log/app/application.log`처럼 위 `paths`와 일치하는 파일에 JSON 한 줄 로그를 기록하십시오. `logging/logback` 템플릿처럼 Spring 설정 값으로 레벨을 받는 구성이라면 환경별 `application.yaml`에서 `logging.level`만 바꿔도 됩니다. 일반 텍스트 로그도 전송되지만, 검색 필드를 안정적으로 쓰려면 JSON 로그를 권장합니다.

Filebeat가 Logstash에 연결하지 못하면 sidecar 로그와 Logstash 상태를 확인합니다.

```sh
kubectl logs -n <application-namespace> <pod-name> -c filebeat
kubectl logs -n infra deployment/logstash
kubectl get endpoints -n infra logstash
```

Logstash의 `5044` 포트는 기본적으로 Beats 인증을 추가하지 않았습니다. 애플리케이션 namespace에서 `infra` namespace의 `logstash:5044`로만 접근할 수 있도록 NetworkPolicy를 추가하는 것을 권장합니다.
