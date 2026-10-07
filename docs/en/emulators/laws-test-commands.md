# Laws Test Commands — Verified and Stub Services

Endpoint: `http://<laws-lxc-ip>:4566` (learn the IP from the `laws_endpoint` output after setup)
UI: `http://<laws-lxc-ip>:4566/dashboard`

> All commands run on **your own machine** (AWS CLI v2 installed).
> Laws is a single-binary AWS emulator written in Rust; it runs as a systemd service inside an LXC and is for the `dev` environment only. It lists 184 services but all are in-memory stubs — it doesn't run real engines (Docker, databases).

---

## Access

Laws runs as the `laws.service` systemd service inside an LXC. Setup has two steps: **Tofu** provisions the LXC and generates the `ansible/inventory/laws.ini.generated` inventory; **Ansible** downloads the Laws binary and installs the systemd service.

```bash
# 1. LXC'yi aç (controller'dan, dev ortamı) — envanter de bu adımda üretilir
cd tofu && ./deploy.sh dev laws

# 2. Laws kurulumu (Ansible: binary + systemd servisi)
#    Önce ansible/inventory/group_vars/all/all.yml içinde laws.enable = true yapılmalı
cd ansible
ansible-playbook -i inventory/laws.ini.generated playbooks/laws.yml

# Kurulum sonrası endpoint'i öğren (controller'dan)
cd tofu/stacks/laws && tofu output laws_endpoint

# LXC'yi Proxmox üzerinde bul
pct list | grep laws

# LXC içine gir (servis durumunu görmek için; vmid'yi üstteki listeden al)
pct exec "<vmid>" -- bash
systemctl status laws
```

> After setup, the Laws LXC's IP is directly reachable from your local machine; no SSH needed. For alternative setup paths (manual Tofu), see `README.md` §3.12.

### Embedded Dashboard (v1.2.0+)

Since Laws v1.2.0, the binary includes an embedded real-time dashboard. Reach it with a browser from the controller:

```
http://<laws-lxc-ip>:4566/dashboard
```

The dashboard live-streams every API request (service, action, status code, duration, request/response bodies) over Server-Sent Events via `GET /api/dashboard/events`. `GET /` behaves as bucket-list/health-check:

```bash
# Hızlı health check (GET / bucket listesi döner)
curl "http://<laws-lxc-ip>:4566/"
```

---

## Helpers

```bash
export LAWS="--endpoint-url=http://<laws-lxc-ip>:4566 --region us-east-1"
export LAWS_URL="http://<laws-lxc-ip>:4566"
export FAKE="--access-key fake --secret-key fake"
```

> Replace `<laws-lxc-ip>` with the IP from the `tofu output laws_endpoint` output.

---

## 1. S3 — Object Storage 

**What it does:** Used to store files and objects. Each file lives in a "bucket". Ideal for static site publishing, backup, and archiving.

```bash
# Bucket oluştur
aws $LAWS $FAKE s3 mb s3://laws-test-bucket

# Bucket'ları listele
aws $LAWS $FAKE s3 ls

# Dosya yükle
echo "merhaba laws" > /tmp/laws-test.txt
aws $LAWS $FAKE s3 cp /tmp/laws-test.txt s3://laws-test-bucket/

# Dosyaları listele
aws $LAWS $FAKE s3 ls s3://laws-test-bucket/

# Dosya indir
aws $LAWS $FAKE s3 cp s3://laws-test-bucket/laws-test.txt /tmp/laws-test-indir.txt

# Obje sil
aws $LAWS $FAKE s3 rm s3://laws-test-bucket/laws-test.txt

# Bucket sil (önce içini boşalt)
aws $LAWS $FAKE s3 rb s3://laws-test-bucket
```

---

## 2. DynamoDB — NoSQL 

**What it does:** Serverless NoSQL database. Stores JSON-like items with single-digit millisecond latency.

```bash
# Tablo oluştur
aws $LAWS $FAKE dynamodb create-table \
  --table-name laws-test-table \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Tabloları listele
aws $LAWS $FAKE dynamodb list-tables

# Item yaz
aws $LAWS $FAKE dynamodb put-item \
  --table-name laws-test-table \
  --item '{"id":{"S":"1"},"name":{"S":"test"}}'

# Item oku
aws $LAWS $FAKE dynamodb get-item \
  --table-name laws-test-table \
  --key '{"id":{"S":"1"}}'

# Sorgula
aws $LAWS $FAKE dynamodb query \
  --table-name laws-test-table \
  --key-condition-expression 'id = :id' \
  --expression-attribute-values '{":id":{"S":"1"}}'

# Tara
aws $LAWS $FAKE dynamodb scan --table-name laws-test-table

# Item sil
aws $LAWS $FAKE dynamodb delete-item \
  --table-name laws-test-table \
  --key '{"id":{"S":"1"}}'

# Tablo sil
aws $LAWS $FAKE dynamodb delete-table --table-name laws-test-table
```

---

## 3. SQS — Message Queue 

**What it does:** Message queue. Used for async communication between services; messages are processed in order.

```bash
# Kuyruk oluştur
aws $LAWS $FAKE sqs create-queue --queue-name laws-test-queue

# Kuyrukları listele
aws $LAWS $FAKE sqs list-queues

# Mesaj gönder
aws $LAWS $FAKE sqs send-message \
  --queue-url "$LAWS_URL/000000000000/laws-test-queue" \
  --message-body "merhaba laws"

# Mesaj al
aws $LAWS $FAKE sqs receive-message \
  --queue-url "$LAWS_URL/000000000000/laws-test-queue"

# Kuyruk öznitelikleri
aws $LAWS $FAKE sqs get-queue-attributes \
  --queue-url "$LAWS_URL/000000000000/laws-test-queue" \
  --attribute-names All

# Kuyruk sil
aws $LAWS $FAKE sqs delete-queue --queue-url "$LAWS_URL/000000000000/laws-test-queue"
```

---

## 4. SNS — Notification 

**What it does:** Pub/sub messaging. A message published to a topic is distributed to all subscribers (SQS, Lambda, email).

```bash
# Topic oluştur
aws $LAWS $FAKE sns create-topic --name laws-test-topic

# Topic'leri listele
aws $LAWS $FAKE sns list-topics

# E-posta aboneliği ekle
aws $LAWS $FAKE sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:000000000000:laws-test-topic \
  --protocol email \
  --notification-endpoint test@example.com

# Abonelikleri listele
aws $LAWS $FAKE sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:000000000000:laws-test-topic

# Mesaj yayınla
aws $LAWS $FAKE sns publish \
  --topic-arn arn:aws:sns:us-east-1:000000000000:laws-test-topic \
  --message "merhaba sns"

# Topic sil
aws $LAWS $FAKE sns delete-topic --topic-arn arn:aws:sns:us-east-1:000000000000:laws-test-topic
```

---

## 5. IAM — Identity & Access Management 

**What it does:** User, role, and policy management. Determines who can access what.

```bash
# Kullanıcı oluştur
aws $LAWS $FAKE iam create-user --user-name laws-test-user

# Kullanıcıları listele
aws $LAWS $FAKE iam list-users

# Rol oluştur
aws $LAWS $FAKE iam create-role \
  --role-name laws-test-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Rolleri listele
aws $LAWS $FAKE iam list-roles

# Yönetilen politika oluştur
aws $LAWS $FAKE iam create-policy \
  --policy-name laws-test-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"*"}]}'

# Politikayı role bağla
aws $LAWS $FAKE iam attach-role-policy \
  --role-name laws-test-role \
  --policy-arn arn:aws:iam::000000000000:policy/laws-test-policy

# Bağlı politikaları listele
aws $LAWS $FAKE iam list-attached-role-policies --role-name laws-test-role

# Temizlik
aws $LAWS $FAKE iam detach-role-policy --role-name laws-test-role --policy-arn arn:aws:iam::000000000000:policy/laws-test-policy
aws $LAWS $FAKE iam delete-policy --policy-arn arn:aws:iam::000000000000:policy/laws-test-policy
aws $LAWS $FAKE iam delete-role --role-name laws-test-role
aws $LAWS $FAKE iam delete-user --user-name laws-test-user
```

---

## 6. Secrets Manager 

**What it does:** Securely stores sensitive data like passwords and API keys. Pulled from here instead of writing plain text into code.

```bash
# Secret oluştur
aws $LAWS $FAKE secretsmanager create-secret \
  --name laws-test-secret \
  --secret-string '{"username":"admin","password":"sifre123"}'

# Secret'ları listele
aws $LAWS $FAKE secretsmanager list-secrets

# Secret oku
aws $LAWS $FAKE secretsmanager get-secret-value --secret-id laws-test-secret

# Secret'ı güncelle
aws $LAWS $FAKE secretsmanager update-secret \
  --secret-id laws-test-secret \
  --secret-string '{"username":"admin","password":"yeni-sifre"}'

# Secret sil
aws $LAWS $FAKE secretsmanager delete-secret \
  --secret-id laws-test-secret \
  --force-delete-without-recovery
```

---

## 7. KMS — Key Management Service 

**What it does:** Manages encryption keys. Used to encrypt/decrypt data.

```bash
# Key oluştur
aws $LAWS $FAKE kms create-key --description "laws-test-key" --key-usage ENCRYPT_DECRYPT

# Key'leri listele (KeyId'yi al)
aws $LAWS $FAKE kms list-keys

# Alias oluştur
KEY_ID=$(aws $LAWS $FAKE kms list-keys --query Keys[0].KeyId --output text)
aws $LAWS $FAKE kms create-alias --alias-name alias/laws-test-key --target-key-id "$KEY_ID"

# Key detayı
aws $LAWS $FAKE kms describe-key --key-id "$KEY_ID"

# Encrypt
echo -n "gizli-veri" > /tmp/laws-plaintext.txt
aws $LAWS $FAKE kms encrypt \
  --key-id "$KEY_ID" \
  --plaintext fileb:///tmp/laws-plaintext.txt \
  --output text --query CiphertextBlob | base64 --decode > /tmp/laws-ciphertext.bin

# Decrypt
aws $LAWS $FAKE kms decrypt \
  --ciphertext-blob fileb:///tmp/laws-ciphertext.bin \
  --output text --query Plaintext | base64 --decode

# Data key üret
aws $LAWS $FAKE kms generate-data-key --key-id "$KEY_ID" --key-spec AES_256
```

---

## 8. Route53 — DNS 

**What it does:** Managed DNS. Provides zone and record management for domains.

```bash
# Hosted zone oluştur
aws $LAWS $FAKE route53 create-hosted-zone \
  --name test.example.com \
  --caller-reference laws-test-1

# Zone'ları listele (Id'yi al)
aws $LAWS $FAKE route53 list-hosted-zones

# Zone detayı
ZONE_ID=$(aws $LAWS $FAKE route53 list-hosted-zones --query HostedZones[0].Id --output text)
aws $LAWS $FAKE route53 get-hosted-zone --id "$ZONE_ID"

# A kaydı ekle
aws $LAWS $FAKE route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"api.test.example.com","Type":"A","TTL":300,"ResourceRecords":[{"Value":"164.102.98.200"}]}}]}'

# Kayıtları listele
aws $LAWS $FAKE route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID"

# Kaydı sil
aws $LAWS $FAKE route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"api.test.example.com","Type":"A","TTL":300,"ResourceRecords":[{"Value":"164.102.98.200"}]}}]}'

# Zone sil
aws $LAWS $FAKE route53 delete-hosted-zone --id "$ZONE_ID"
```

---

## 9. Lambda — Serverless (stub)

**What it does:** Serverless function execution. Listed in Laws but functions don't actually run.

```bash
# Not: Laws'ta Lambda invoke yüzeysel stub yanıt döner — gerçek çalıştırma yok

# Fonksiyon zip'ini hazırla
mkdir -p /tmp/laws-test
cat > /tmp/laws-test/handler.py << 'EOF'
def handler(event, context):
    return {"statusCode": 200, "body": "merhaba laws"}
EOF
cd /tmp/laws-test && zip -q -r /tmp/laws-fn.zip .

# Fonksiyon oluştur
aws $LAWS $FAKE lambda create-function \
  --function-name laws-test-fn \
  --runtime python3.12 \
  --role arn:aws:iam::000000000000:role/laws-test-role \
  --handler handler.handler \
  --zip-file fileb:///tmp/laws-fn.zip

# Fonksiyonları listele
aws $LAWS $FAKE lambda list-functions

# Fonksiyon çağır (stub yanıt döner)
aws $LAWS $FAKE lambda invoke \
  --function-name laws-test-fn \
  /tmp/laws-invoke-out.json && cat /tmp/laws-invoke-out.json

# Fonksiyon sil
aws $LAWS $FAKE lambda delete-function --function-name laws-test-fn
```

---

## 10. CloudFormation — IaC (stub)

**What it does:** Defines infrastructure from templates and manages stack lifecycle.

```bash
# Stack oluştur (satır içi şablon)
aws $LAWS $FAKE cloudformation create-stack \
  --stack-name laws-test-stack \
  --template-body '{"Resources":{"MyBucket":{"Type":"AWS::S3::Bucket"}}}'

# Stack'leri listele
aws $LAWS $FAKE cloudformation describe-stacks

# Stack'i güncelle
aws $LAWS $FAKE cloudformation update-stack \
  --stack-name laws-test-stack \
  --template-body '{"Resources":{"MyBucket":{"Type":"AWS::S3::Bucket"}}}'

# Stack sil
aws $LAWS $FAKE cloudformation delete-stack --stack-name laws-test-stack
```

---

## 11. CloudWatch Logs (stub)

**What it does:** Collects and queries application logs centrally.

```bash
# Log grubu oluştur
aws $LAWS $FAKE logs create-log-group --log-group-name /laws/test

# Log stream oluştur
aws $LAWS $FAKE logs create-log-stream \
  --log-group-name /laws/test \
  --log-stream-name app-1

# Log gönder
aws $LAWS $FAKE logs put-log-events \
  --log-group-name /laws/test \
  --log-stream-name app-1 \
  --log-events '[{"timestamp":1730000000000,"message":"merhaba laws"}]'

# Log oku
aws $LAWS $FAKE logs get-log-events \
  --log-group-name /laws/test \
  --log-stream-name app-1
```

---

## 12. CloudWatch Metrics (stub)

**What it does:** Collects custom metrics; creates alarms and graphs.

```bash
# Metrik gönder
aws $LAWS $FAKE cloudwatch put-metric-data \
  --namespace LawsTest \
  --metric-data MetricName=RequestCount,Value=42

# Metrikleri listele
aws $LAWS $FAKE cloudwatch list-metrics --namespace LawsTest

# Metrik verisini çek
aws $LAWS $FAKE cloudwatch get-metric-data \
  --metric-data-queries '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"LawsTest","MetricName":"RequestCount"},"Stat":"Sum"},"Period":60}]' \
  --start-time 2026-10-01T00:00:00Z \
  --end-time 2026-10-02T00:00:00Z

# Alarm oluştur
aws $LAWS $FAKE cloudwatch put-metric-alarm \
  --alarm-name laws-test-alarm \
  --metric-name RequestCount \
  --namespace LawsTest \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold
```

---

## 13. EventBridge — Events (stub)

**What it does:** Event routing. Distributes matching events to targets by rule.

```bash
# Event bus oluştur
aws $LAWS $FAKE events create-event-bus --name laws-test-bus

# Kural oluştur
aws $LAWS $FAKE events put-rule \
  --name laws-test-rule \
  --event-pattern '{"source":["laws.test"]}' \
  --state ENABLED

# Kurala hedef bağla
aws $LAWS $FAKE events put-targets \
  --rule laws-test-rule \
  --targets '[{"Id":"t1","Arn":"arn:aws:sqs:us-east-1:000000000000:laws-test-queue"}]'

# Olay yayınla
aws $LAWS $FAKE events put-events \
  --entries '[{"Source":"laws.test","DetailType":"test","Detail":"{\"msg\":\"merhaba\"}"}]'
```

---

## 14. Kinesis — Data Streams (stub)

**What it does:** High-volume real-time data streaming.

```bash
# Stream oluştur
aws $LAWS $FAKE kinesis create-stream --stream-name laws-test-stream --shard-count 1

# Stream'leri listele
aws $LAWS $FAKE kinesis list-streams

# Kayıt gönder
aws $LAWS $FAKE kinesis put-record \
  --stream-name laws-test-stream \
  --partition-key p1 \
  --data "merhaba kinesis"

# Stream sil
aws $LAWS $FAKE kinesis delete-stream --stream-name laws-test-stream
```

---

## 15. SSM Parameter Store (stub)

**What it does:** Stores configuration parameters hierarchically.

```bash
# Parametre yaz
aws $LAWS $FAKE ssm put-parameter \
  --name /laws/test/param1 \
  --value "merhaba" \
  --type String

# Parametre oku
aws $LAWS $FAKE ssm get-parameter --name /laws/test/param1

# Yolu tara
aws $LAWS $FAKE ssm get-parameters-by-path --path /laws/test

# Parametre sil
aws $LAWS $FAKE ssm delete-parameter --name /laws/test/param1
```

---

## 16. ECR — Container Registry (stub)

**What it does:** Docker image storage service.

```bash
# Repository oluştur
aws $LAWS $FAKE ecr create-repository --repository-name laws/test-repo

# Repository'leri listele
aws $LAWS $FAKE ecr describe-repositories

# Repository sil
aws $LAWS $FAKE ecr delete-repository --repository-name laws/test-repo --force
```

---

## 17. Cognito — Identity Provider (stub)

**What it does:** User signup and authentication (user pool).

```bash
# User pool oluştur
aws $LAWS $FAKE cognito-idp create-user-pool --user-pool-name laws-test-pool

# Pool'ları listele
aws $LAWS $FAKE cognito-idp list-user-pools --max-results 10

# Pool sil
POOL_ID=$(aws $LAWS $FAKE cognito-idp list-user-pools --max-results 10 --query UserPools[0].Id --output text)
aws $LAWS $FAKE cognito-idp delete-user-pool --user-pool-id "$POOL_ID"
```

---

## 18. API Gateway — REST (stub)

**What it does:** REST API definition and management.

```bash
# API oluştur
aws $LAWS $FAKE apigateway create-rest-api --name laws-test-api

# API'leri listele
aws $LAWS $FAKE apigateway get-rest-apis

# API sil
API_ID=$(aws $LAWS $FAKE apigateway get-rest-apis --query items[0].id --output text)
aws $LAWS $FAKE apigateway delete-rest-api --rest-api-id "$API_ID"
```

---

## 19. Step Functions — States (stub)

**What it does:** Visual workflow orchestration.

```bash
# State machine oluştur
aws $LAWS $FAKE stepfunctions create-state-machine \
  --name laws-test-sm \
  --definition '{"StartAt":"Hello","States":{"Hello":{"Type":"Pass","End":true}}}' \
  --role-arn arn:aws:iam::000000000000:role/laws-test-role

# State machine'leri listele
aws $LAWS $FAKE stepfunctions list-state-machines

# Çalıştır
aws $LAWS $FAKE stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:000000000000:stateMachine:laws-test-sm
```

---

## 20. Athena — SQL Query (stub)

**What it does:** Runs standard SQL queries over S3.

```bash
# Work group oluştur
aws $LAWS $FAKE athena create-work-group \
  --name laws-test-wg \
  --configuration '{"ResultConfiguration":{"OutputLocation":"s3://laws-test-bucket/athena/"}}'

# Work group'ları listele
aws $LAWS $FAKE athena list-work-groups

# Sorgu başlat
aws $LAWS $FAKE athena start-query-execution \
  --query-string "SELECT 1 AS test" \
  --work-group laws-test-wg
```

---

## 21. STS — Security Token Service (stub)

**What it does:** Generates temporary credentials.

```bash
# Kimlik doğrula
aws $LAWS $FAKE sts get-caller-identity

# Rol üstlen
aws $LAWS $FAKE sts assume-role \
  --role-arn arn:aws:iam::000000000000:role/laws-test-role \
  --role-session-name laws-session

# Oturum token'ı al
aws $LAWS $FAKE sts get-session-token --duration-seconds 900
```

---

## 22. SES — Email Service (stub)

**What it does:** Email sending service.

```bash
# E-posta kimliği oluştur
aws $LAWS $FAKE ses create-email-identity --email-identity test@example.com

# Kimlikleri listele
aws $LAWS $FAKE ses list-email-identities

# E-posta gönder (v2 API)
aws $LAWS $FAKE sesv2 send-email \
  --from-email-address test@example.com \
  --destination '{"ToAddresses":["hedef@example.com"]}' \
  --content '{"Simple":{"Subject":{"Data":"Laws Test"},"Body":{"Text":{"Data":"merhaba laws"}}}}'
```

---

## 23. CloudTrail (stub)

**What it does:** Records account activity for auditing.

```bash
# Trail oluştur
aws $LAWS $FAKE cloudtrail create-trail \
  --name laws-test-trail \
  --s3-bucket-name laws-test-bucket

# Trail'leri listele
aws $LAWS $FAKE cloudtrail describe-trails

# Loglamayı başlat
aws $LAWS $FAKE cloudtrail start-logging --name laws-test-trail

# Trail sil
aws $LAWS $FAKE cloudtrail delete-trail --name laws-test-trail
```

---

## 24. Backup (stub)

**What it does:** Manages backup vaults and plans.

```bash
# Vault oluştur
aws $LAWS $FAKE backup create-backup-vault --backup-vault-name laws-test-vault

# Vault'ları listele
aws $LAWS $FAKE backup list-backup-vaults

# Vault sil
aws $LAWS $FAKE backup delete-backup-vault --backup-vault-name laws-test-vault
```

---

## 25. Organizations (stub)

**What it does:** Multi-account management.

```bash
# Organization kur
aws $LAWS $FAKE organizations create-organization --feature-set ALL

# Hesap oluştur
aws $LAWS $FAKE organizations create-account \
  --email laws-account@example.com \
  --account-name laws-test-account

# Hesapları listele
aws $LAWS $FAKE organizations list-accounts

# Organization sil (temizlik)
aws $LAWS $FAKE organizations delete-organization
```

---

## 26. Auto Scaling (stub)

**What it does:** Auto-scales EC2 capacity.

```bash
# ASG oluştur
aws $LAWS $FAKE autoscaling create-auto-scaling-group \
  --auto-scaling-group-name laws-test-asg \
  --min-size 1 --max-size 3 --desired-capacity 1

# ASG'leri listele
aws $LAWS $FAKE autoscaling describe-auto-scaling-groups

# Kapasiteyi değiştir
aws $LAWS $FAKE autoscaling set-desired-capacity \
  --auto-scaling-group-name laws-test-asg \
  --desired-capacity 2

# ASG sil
aws $LAWS $FAKE autoscaling delete-auto-scaling-group --auto-scaling-group-name laws-test-asg
```

---

## 27. Batch (stub)

**What it does:** Batch job compute environment.

```bash
# Compute environment oluştur
aws $LAWS $FAKE batch create-compute-environment \
  --compute-environment-name laws-test-ce \
  --type MANAGED \
  --state ENABLED \
  --compute-resources '{"type":"EC2","minvCpus":1,"maxvCpus":8,"subnets":["subnet-fake"],"securityGroupIds":["sg-fake"],"instanceRole":"arn:aws:iam::000000000000:role/laws-test-role"}'

# Compute environment'ları listele
aws $LAWS $FAKE batch describe-compute-environments

# Job kuyrukları
aws $LAWS $FAKE batch list-job-queues
```

---

## 28. CodeBuild (stub)

**What it does:** Build and test automation.

```bash
# Proje oluştur
aws $LAWS $FAKE codebuild create-project \
  --name laws-test-project \
  --source '{"type":"NO_SOURCE"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:5.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role arn:aws:iam::000000000000:role/laws-test-role

# Projeleri listele
aws $LAWS $FAKE codebuild list-projects

# Build başlat
aws $LAWS $FAKE codebuild start-build --project-name laws-test-project

# Proje sil
aws $LAWS $FAKE codebuild delete-project --name laws-test-project
```

---

## 29. CodePipeline (stub)

**What it does:** Continuous delivery (CD) pipeline orchestration.

```bash
# Pipeline'ları listele
aws $LAWS $FAKE codepipeline list-pipelines

# Pipeline çalıştır
aws $LAWS $FAKE codepipeline start-pipeline-execution --name laws-test-pipeline
```

---

## 30. ECS (stub)

**What it does:** Container orchestration.

```bash
# Cluster oluştur
aws $LAWS $FAKE ecs create-cluster --cluster-name laws-test-cluster

# Cluster'ları listele
aws $LAWS $FAKE ecs list-clusters

# Cluster sil
aws $LAWS $FAKE ecs delete-cluster --cluster laws-test-cluster
```

---

## 31. EKS (stub)

**What it does:** Managed Kubernetes control plane.

```bash
# Cluster oluştur
aws $LAWS $FAKE eks create-cluster \
  --name laws-test-eks \
  --role-arn arn:aws:iam::000000000000:role/laws-test-role \
  --resources-vpc-config subnetIds=subnet-fake,securityGroupIds=sg-fake

# Cluster'ları listele
aws $LAWS $FAKE eks list-clusters

# Cluster detayı
aws $LAWS $FAKE eks describe-cluster --name laws-test-eks

# Cluster sil
aws $LAWS $FAKE eks delete-cluster --name laws-test-eks
```

---

## 32. RDS (stub)

**What it does:** Managed relational database.

```bash
# DB instance oluştur
aws $LAWS $FAKE rds create-db-instance \
  --db-instance-identifier laws-test-db \
  --engine mysql \
  --db-instance-class db.t3.micro \
  --master-username admin \
  --master-user-password Laws123 \
  --allocated-storage 20

# Instance'ları listele
aws $LAWS $FAKE rds describe-db-instances

# Instance sil
aws $LAWS $FAKE rds delete-db-instance \
  --db-instance-identifier laws-test-db \
  --skip-final-snapshot
```

---

## 33. ElastiCache (stub)

**What it does:** Managed Redis/Memcached cache.

```bash
# Cache cluster oluştur
aws $LAWS $FAKE elasticache create-cache-cluster \
  --cache-cluster-id laws-test-cache \
  --engine redis \
  --cache-node-type cache.t3.micro \
  --num-cache-nodes 1

# Cluster'ları listele
aws $LAWS $FAKE elasticache describe-cache-clusters

# Cluster sil
aws $LAWS $FAKE elasticache delete-cache-cluster --cache-cluster-id laws-test-cache
```

---

## EC2 — Known Limitation

The Laws README lists `RunInstances`, `DescribeInstances`, `TerminateInstances` for EC2. But these requests fall through to the S3 handler inside Laws: the call doesn't error, but the response comes back in S3 shape instead of EC2.

```bash
# Gözlem: yanıtın S3 (bucket listesi) biçiminde döndüğü görülür
aws $LAWS $FAKE ec2 describe-instances
```

So EC2 scenarios can't be tested with Laws; Floci is used for these scenarios (see `floci-test-commands.md` #13).

---

## Bulk Cleanup (after tests)

```bash
# S3
for b in $(aws $LAWS $FAKE s3 ls --query 'Buckets[].Name' --output text 2>/dev/null); do
  aws $LAWS $FAKE s3 rb "s3://$b" --force 2>/dev/null
done

# DynamoDB
for t in $(aws $LAWS $FAKE dynamodb list-tables --output text 2>/dev/null); do
  aws $LAWS $FAKE dynamodb delete-table --table-name "$t"
done

# SQS
for url in $(aws $LAWS $FAKE sqs list-queues --query QueueUrls --output text 2>/dev/null); do
  aws $LAWS $FAKE sqs delete-queue --queue-url "$url"
done

# SNS
for arn in $(aws $LAWS $FAKE sns list-topics --query Topics[].TopicArn --output text 2>/dev/null); do
  aws $LAWS $FAKE sns delete-topic --topic-arn "$arn"
done

# IAM: rolleri ve kullanıcıları temizle
for role in $(aws $LAWS $FAKE iam list-roles --query Roles[].RoleName --output text 2>/dev/null); do
  for pol in $(aws $LAWS $FAKE iam list-attached-role-policies --role-name "$role" --query AttachedPolicies[].PolicyArn --output text 2>/dev/null); do
    aws $LAWS $FAKE iam detach-role-policy --role-name "$role" --policy-arn "$pol"
  done
  aws $LAWS $FAKE iam delete-role --role-name "$role"
done
for user in $(aws $LAWS $FAKE iam list-users --query Users[].UserName --output text 2>/dev/null); do
  aws $LAWS $FAKE iam delete-user --user-name "$user"
done

# Secrets Manager
for secret in $(aws $LAWS $FAKE secretsmanager list-secrets --query SecretList[].Name --output text 2>/dev/null); do
  aws $LAWS $FAKE secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery
done

# CloudFormation
for stack in $(aws $LAWS $FAKE cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query StackSummaries[].StackName --output text 2>/dev/null); do
  aws $LAWS $FAKE cloudformation delete-stack --stack-name "$stack"
done

# Route53
for zone in $(aws $LAWS $FAKE route53 list-hosted-zones --query HostedZones[].Id --output text 2>/dev/null); do
  aws $LAWS $FAKE route53 delete-hosted-zone --id "$zone"
done
```

---

> **Note:** Laws lists 184 services; this guide covers the most common 33. For the full list and each service's supported operations, see the [huseyinbabal/laws](https://github.com/huseyinbabal/laws) README. All services are in-memory stubs; real AWS behavior shouldn't be expected.
