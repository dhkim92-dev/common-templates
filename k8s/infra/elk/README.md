# ELK 로그 수집

`infra` 네임스페이스에 Elasticsearch, Kibana, Logstash를 배포합니다. Helm은 사용하지 않습니다. Logstash는 Beats 입력 포트 `5044`를 열고, 수신한 이벤트를 일 단위 `logs-YYYY.MM.dd` 인덱스에 저장합니다.

## 구성과 보안

| 구성 요소 | 역할 | 기본 구성 |
| --- | --- | --- |
| Elasticsearch | 로그 저장·검색 API | StatefulSet 1 replica, 50Gi PVC |
| Logstash | Filebeat 이벤트 수신·전송 | Deployment, `logstash.infra.svc:5044` |
| Kibana | 로그 조회 UI | Deployment, `kibana.infra.svc:5601` |

Elasticsearch 보안은 활성화되어 있습니다. 처음 기동할 때 `elk-credentials` Secret의 `elastic-password` 값이 내장 관리자 계정 `elastic`의 초기 비밀번호가 됩니다. `kibana_system`과 최소 권한 `logstash_internal` 계정은 `elk-credentials-init` Job이 생성합니다. 따라서 관리자 비밀번호와 초기 계정 비밀번호를 생성 전에 지정할 수 있습니다.

이 기본 구성은 클러스터 내부 HTTP 통신을 사용하며, Elasticsearch는 단일 노드입니다. 외부 노출은 Ingress나 Gateway에서 TLS와 인증 정책을 별도로 적용하십시오. Elasticsearch 다중 노드 HA에는 transport TLS 및 노드 인증서가 필요하므로, 인증서 발급 체계를 정한 뒤 별도 오버레이로 확장해야 합니다.

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

```sh
# 로컬
kubectl apply -k k8s/infra/elk/overlays/local

# 운영: PVC StorageClass 값을 먼저 지정
kubectl apply -k k8s/infra/elk/overlays/production

kubectl get pods,pvc,svc -n infra
kubectl logs -n infra job/elk-credentials-init
kubectl port-forward -n infra service/kibana 5601:5601
```

브라우저에서 `http://localhost:5601`을 열고 `elastic` 계정과 `elastic-password` 값으로 로그인합니다. Kibana **Discover**에서 `logs-*` 데이터 뷰를 만들면 수집 로그를 조회할 수 있습니다.

운영 오버레이는 Elasticsearch PVC의 StorageClass를 `REPLACE_MULTI_NODE_STORAGE_CLASS`로 표시합니다. 클라우드의 다중 노드에서 사용할 StorageClass 이름으로 반드시 바꾼 뒤 적용하십시오. 기본 `openebs-local`은 노드 고정 RWO 볼륨입니다.

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
