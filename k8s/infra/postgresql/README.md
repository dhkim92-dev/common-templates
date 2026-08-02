# PostgreSQL

Grafana가 상태·대시보드·알림 설정을 저장하는 단일 PostgreSQL 인스턴스입니다. 서비스용 데이터베이스는 이 패키지와 분리합니다. PostgreSQL HA는 구성하지 않습니다.

## Secret 준비

초기 데이터베이스·계정·비밀번호는 `postgresql-credentials` Secret으로만 전달합니다. 예시를 복사해 비밀번호를 충분히 긴 난수로 변경한 뒤, PostgreSQL 배포보다 먼저 적용합니다.

```sh
cp k8s/infra/postgresql/secrets.example.yaml k8s/infra/postgresql/secrets.yaml
kubectl apply -f k8s/infra/postgresql/secrets.yaml
```

`POSTGRES_DB`와 `POSTGRES_USER`를 변경하면 Grafana의 고정 접속 설정도 함께 변경해야 합니다. 비밀번호 변경은 기존 데이터 디렉터리의 PostgreSQL 계정을 자동 변경하지 않으므로, 운영 중에는 PostgreSQL에서 비밀번호를 변경한 후 Secret을 갱신하고 Grafana를 재시작하십시오.

## 배포

```sh
# 로컬: openebs-hostpath, 10Gi
kubectl apply -k k8s/infra/postgresql/overlays/local

# production: overlay의 REPLACE_PRODUCTION_STORAGE_CLASS을 클러스터 StorageClass로 변경 후 적용
kubectl apply -k k8s/infra/postgresql/overlays/production
```

Grafana를 함께 사용하려면 PostgreSQL이 Ready가 된 다음 [Grafana 문서](../grafana/README.md)의 배포 순서를 따르십시오. 클러스터 내부 접속 주소는 `postgresql.infra.svc:5432`입니다.
