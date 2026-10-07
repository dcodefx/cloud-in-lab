
## Laws vs Floci — Servis Bazında Karşılaştırma

> Son kontrol: 2026-10-01 · Laws v1.2.0 (26 Ağu 2026) · Floci 2.1.0 (15 Eyl 2026)

| Servis | Laws (v1.2.0) | Floci (2.1.0) | Kaynak |
|---|---|---|---|
| **S3** | ✅ Temel CRUD (test edildi) | ✅ versioning, multipart, pre-signed URL, Object Lock, event notifications | Laws GH#149 · Floci GH |
| **DynamoDB** | ✅ CreateTable/PutItem/GetItem/Query/Scan (test edildi) | ✅ GSI/LSI, TTL, transactions, PartiQL, Streams + Lambda ESM | Laws GH#63 · Floci GH |
| **SQS** | ✅ CreateQueue/Send/Receive (test edildi) | ✅ Standard+FIFO, DLQ, batch, tagging | Laws GH#163 · Floci GH |
| **SNS** | ✅ CreateTopic/Subscribe/Publish | ✅ SQS/Lambda/HTTP delivery, tagging | Laws GH#162 · Floci GH |
| **Lambda** | ⚠️ Listede var ama gerçek çalıştırma yok (in-memory stub) | ✅ **Real Docker**, warm pool, ESM trigger, Function URL, MicroVM | Laws GH#108 · Floci GH |
| **IAM** | ✅ CreateUser/CreateRole/AttachRolePolicy | ✅ users, roles, groups, policies, access keys; STS AssumeRole/WebIdentity/SAML | Laws GH#96 · Floci GH |
| **Secrets Manager** | ✅ CreateSecret/GetSecretValue (test edildi) | ✅ versioning, resource policies, tagging | Laws GH#153 · Floci GH |
| **KMS** | ✅ CreateKey/Encrypt/Decrypt | ✅ encrypt/decrypt, sign/verify, data keys, aliases | Laws GH#106 · Floci GH |
| **EC2** | ❌ **Listede var ama çalışmıyor** (S3 fallback, test edildi) | ✅ **Real Docker**; SSH key, UserData, IMDS, VPC kaynakları | Laws GH#65 · Floci GH |
| **Route53** | ✅ CreateHostedZone/ListHostedZones (test edildi) | ✅ Hosted zones, SOA/NS records, change tracking | Laws GH#145 · Floci GH |
| **ECS/EKS** | ⚠️ Listede var (stub) | ✅ **Real Docker**; EKS = k3s, canlı Kubernetes API | Laws GH#67/69 · Floci GH |
| **RDS** | ⚠️ Listede var (CreateDBInstance) | ✅ **Real PostgreSQL/MySQL/MariaDB** + IAM auth + RDS Data API | Laws GH#140 · Floci GH |
| **ElastiCache** | ⚠️ Listede var | ✅ **Real Valkey 8** + IAM auth, SigV4; MemoryDB ayrıca | Laws GH#71 · Floci GH |
| **Neptune** | ⚠️ Listede var (stub) | ✅ **Real Docker** — Gremlin (TinkerPop) veya Neo4j (openCypher) | Laws GH#125 · Floci GH |
| **DocumentDB** | ⚠️ Listede var (stub) | ✅ **Real Docker** — MongoDB uyumlu (mongo:7) | Laws GH#62 · Floci GH |
| **MSK** | ⚠️ Listede var (stub) | ✅ **Real Docker** — Redpanda broker | Laws GH#123 · Floci GH |
| **Amazon MQ** | ⚠️ Listede var (stub) | ✅ **Real Docker** — RabbitMQ (AMQP + yönetim konsolu) | Laws GH#122 · Floci GH |
| **MWAA** | ⚠️ Listede var (stub) | ✅ **Real Docker** — Apache Airflow + Postgres meta DB | Laws GH#124 · Floci GH |
| **OpenSearch** | ⚠️ Listede var (stub) | ✅ **Real Docker** — OpenSearch 2, REST API | Laws GH#129 · Floci GH |
| **CodeBuild** | ⚠️ Listede var (stub) | ✅ **Real Docker** — buildspec, log stream, S3 artifact | Laws GH#35 · Floci GH |
| **Managed Flink** | ❌ Yok | ✅ **Real Docker** — JobManager + TaskManager, JAR S3'ten | — · Floci GH |
| **API Gateway** | ⚠️ Listede var (REST-JSON) | ✅ REST + v2/HTTP API + WebSocket | Laws GH#5/6 · Floci GH |
| **Cognito** | ⚠️ Listede var | ✅ User pools, auth flows, JWKS, Cognito Identity | Laws GH#40 · Floci GH |
| **CloudFormation** | ⚠️ Listede var | ✅ stacks, change sets, StackSets, SAM desteği | Laws GH#26 · Floci GH |
| **Step Functions** | ⚠️ Listede var | ✅ ASL execution, task tokens, execution history | Laws GH#166 · Floci GH |
| **EventBridge** | ⚠️ Listede var | ✅ custom buses, rules, targets; Pipes + Scheduler ayrı servisler | Laws GH#76 · Floci GH |
| **Kinesis** | ⚠️ Listede var | ✅ streams, shards, enhanced fan-out, split/merge | Laws GH#105 · Floci GH |
| **Athena** | ⚠️ Listede var | ✅ DuckDB sidecar ile **gerçek SQL**; Glue katalog | Laws GH#14 · Floci GH |
| **CloudWatch** | ⚠️ Listede var | ✅ logs + metrics + OAM + RUM; Managed Prometheus (AMP) | Laws GH#32/33 · Floci GH |

### Altyapı Karşılaştırması

| Özellik | Laws | Floci |
|---|---|---|
| **Dil/Runtime** | Rust, tek binary (~24 MB) | Java/Quarkus + GraalVM (~40 MB native / ~90 MB Docker) |
| **Startup** | ~1 ms | ~24 ms |
| **RAM (idle)** | ~2 MB | ~13 MB |
| **Docker gerekli** | ❌ Hayır | ❌ Hayır (native binary) / ✅ real-engine servisler için gerekli |
| **Servis sayısı** | 184 (listelenen, in-memory stub) | 130 (desteklenen) |
| **Gerçek engine** | Yok (hepsi in-memory stub) | Lambda/RDS/Neptune/DocumentDB/MSK/MQ/ElastiCache/MemoryDB/ECS/EC2/EKS/MWAA/CodeBuild/OpenSearch/Flink → **real Docker**; Athena → DuckDB sidecar |
| **Persist desteği** | ✅ SQLite (`--persist`) | ✅ 4 mod: memory/persistent/hybrid/WAL |
| **Web konsol** | ✅ v1.2.0'dan itibaren binary'ye gömülü dashboard UI | ✅ `/_floci/ui` (floci-ui sidecar) |
| **Health endpoint** | ❌ Yok | ✅ `/_localstack/health` |
| **IAM enforcement** | ❌ Yok | Varsayılan yok; bazı servislerde opsiyonel auth zorlaması |
| **Auth token** | Gerekmez | Gerekmez |
| **Lisans** | MIT | MIT |
| **GitHub star** | ~66 | ~26.000 |
| **LocalStack uyum** | Kısmen (port 4566) | **Tam drop-in** (env var çevirisi, init script, `Ready.` satırı) |
| **SDK testleri** | Belirtilmemiş | 2.576 otomatik test (5 SDK + Terraform/OpenTofu/CDK) |
| **Ekosistem** | Tek repo | floci-cli, floci-ui, testcontainers modülleri (Java/Node/Python/.NET/Go), floci-az / floci-gcp / floci-oci kardeş emülatörler |
| **Proje olgunluğu** | Yeni (~37 commit) | 2.900+ commit, hızlı sürüm temposu (Eyl 2026: 2.1.0) |

### Özet

- **Laws** — 184 servis *listeler* ama çoğu yüzeysel in-memory stub. EC2 çalışmıyor. Hafif, hızlı, CI/CD'de basit testler için ideal. Lambda/RDS/EC2 gibi servisleri gerçekten çalıştırmaz. v1.2.0 ile birlikte binary'ye gömülü bir dashboard UI geldi.
- **Floci** — 130 desteklenen servis; Lambda'dan MWAA'ya 15+ serviste **real Docker container**, Athena'da DuckDB ile gerçek SQL. 2.576 otomatik uyumluluk testi, CLI, web konsol ve testcontainers modüllerinden oluşan bir ekosistemi var. LocalStack'in bıraktığı boşluğu doldurmak için yazılmış, MIT lisanslı, hiçbir zaman ücretli olmayacak.

**Netice:** Laws hafif CI/CD ve basit AWS SDK testleri için yeterli. Gerçekçi bir AWS deneyimi (Lambda çalıştırma, RDS'ye bağlanma, EC2 provision, Airflow/OpenSearch/Kafka senaryoları) gerekiyorsa Floci çok daha yetkin.
