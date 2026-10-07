# Floci Test Commands — All Services

Floci IP: `164.102.98.200` (VM)
Endpoint: `http://164.102.98.200:4566`
UI: `http://164.102.98.200:4566/_floci/ui`

> All commands run on **your own machine** (AWS CLI v2 must be installed).

---

## Helpers

```bash
export FLOCI="--endpoint-url=http://164.102.98.200:4566 --region us-east-1"
export FAKE="--access-key fake --secret-key fake"
```

---

## 1. S3 — Object Storage

**What it does:** Used to store files and objects. Works like "folders" in the cloud; each file lives in a "bucket". Ideal for static website publishing, backups, data archives, and media files.

```bash
# Bucket oluştur
aws $FLOCI $FAKE s3 mb s3://test-bucket

# Bucket'ları listele
aws $FLOCI $FAKE s3 ls

# Dosya yükle
echo "merhaba floci" > /tmp/test.txt
aws $FLOCI $FAKE s3 cp /tmp/test.txt s3://test-bucket/

# Dosyaları listele
aws $FLOCI $FAKE s3 ls s3://test-bucket/

# Dosya indir
aws $FLOCI $FAKE s3 cp s3://test-bucket/test.txt /tmp/test-indir.txt

# Public ACL aç
aws $FLOCI $FAKE s3api put-bucket-acl --bucket test-bucket --acl public-read

# Bucket tagging
aws $FLOCI $FAKE s3api put-bucket-tagging --bucket test-bucket --tagging 'TagSet=[{Key=env,Key=test}]'

# Bucket sil (önce içini boşalt)
aws $FLOCI $FAKE s3 rm s3://test-bucket/test.txt
aws $FLOCI $FAKE s3 rb s3://test-bucket
```

---

## 2. SQS — Message Queue

**What it does:** A messaging queue between services. One service sends a message, another reads it later. Used to decouple services, balance load, and run async work in microservice architectures.

```bash
# Kuyruk oluştur
aws $FLOCI $FAKE sqs create-queue --queue-name test-queue

# Kuyruk URL'sini al
aws $FLOCI $FAKE sqs get-queue-url --queue-name test-queue

# Kuyruk attributes
aws $FLOCI $FAKE sqs get-queue-attributes --queue-url http://164.102.98.200:4566/000000000000/test-queue --attribute-names All

# Mesaj gönder
aws $FLOCI $FAKE sqs send-message --queue-url http://164.102.98.200:4566/000000000000/test-queue --message-body "Merhaba SQS"

# Mesaj al
aws $FLOCI $FAKE sqs receive-message --queue-url http://164.102.98.200:4566/000000000000/test-queue

# DLQ (Dead Letter Queue) oluştur
aws $FLOCI $FAKE sqs create-queue --queue-name test-dlq

# Redrive policy ile ana kuyruğa DLQ bağla
aws $FLOCI $FAKE sqs set-queue-attributes --queue-url http://164.102.98.200:4566/000000000000/test-queue --attributes '{"RedrivePolicy":"{\"deadLetterTargetArn\":\"arn:aws:sqs:us-east-1:000000000000:test-dlq\",\"maxReceiveCount\":\"3\"}"}'

# Kuyrukları listele
aws $FLOCI $FAKE sqs list-queues

# Kuyruk sil
aws $FLOCI $FAKE sqs delete-queue --queue-url http://164.102.98.200:4566/000000000000/test-queue
aws $FLOCI $FAKE sqs delete-queue --queue-url http://164.102.98.200:4566/000000000000/test-dlq
```

---

## 3. SNS — Notification (Pub/Sub)

**What it does:** Publishes a message to a topic, and all subscribed services receive it. Unlike SQS: SNS is "send once, everyone receives" (broadcast); SQS is "send once, one receives" (point-to-point). Used for email notifications, SMS, and push notifications.

```bash
# Topic oluştur
aws $FLOCI $FAKE sns create-topic --name test-topic

# Topic ARN'sini al
aws $FLOCI $FAKE sns list-topics

# Topic özelliklerini oku
aws $FLOCI $FAKE sns get-topic-attributes --topic-arn arn:aws:sns:us-east-1:000000000000:test-topic

# SQS'ye abone ol (önce SQS kuyruğu oluştur)
aws $FLOCI $FAKE sqs create-queue --queue-name test-sns-queue
SNS_TOPIC_ARN=$(aws $FLOCI $FAKE sns list-topics --query Topics[0].TopicArn --output text)
SNS_QUEUE_ARN=$(aws $FLOCI $FAKE sqs get-queue-attributes --queue-url http://164.102.98.200:4566/000000000000/test-sns-queue --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws $FLOCI $FAKE sns subscribe --topic-arn "$SNS_TOPIC_ARN" --protocol sqs --notification-endpoint "$SNS_QUEUE_ARN"

# Abonelikleri listele
aws $FLOCI $FAKE sns list-subscriptions

# SMS publish (fake)
aws $FLOCI $FAKE sns publish --topic-arn "$SNS_TOPIC_ARN" --message "Test mesaji"

# Topic sil
aws $FLOCI $FAKE sns delete-topic --topic-arn "$SNS_TOPIC_ARN"
```

---

## 4. DynamoDB — NoSQL

**What it does:** Key-value and document-based NoSQL database. Unlike relational databases the table schema is flexible, with high read/write throughput. Used in apps needing low latency like gaming, IoT, and session management.

```bash
# Tablo oluştur
aws $FLOCI $FAKE dynamodb create-table \
  --table-name test-table \
  --attribute-definitions AttributeName=id,AttributeType=S AttributeName=sort,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH AttributeName=sort,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

# Tabloları listele
aws $FLOCI $FAKE dynamodb list-tables

# Tablo bilgisi
aws $FLOCI $FAKE dynamodb describe-table --table-name test-table

# Item ekle
aws $FLOCI $FAKE dynamodb put-item \
  --table-name test-table \
  --item '{"id": {"S": "1"}, "sort": {"S": "a"}, "data": {"S": "test"}, "count": {"N": "42"}}'

# Batch item ekle
aws $FLOCI $FAKE dynamodb batch-write-item \
  --request-items '{"test-table": [{"PutRequest": {"Item": {"id": {"S": "2"}, "sort": {"S": "b"}, "data": {"S": "batch"}}}}, {"PutRequest": {"Item": {"id": {"S": "3"}, "sort": {"S": "c"}, "data": {"S": "batch2"}}}}]}'

# Item oku
aws $FLOCI $FAKE dynamodb get-item \
  --table-name test-table \
  --key '{"id": {"S": "1"}, "sort": {"S": "a"}}'

# Query
aws $FLOCI $FAKE dynamodb query \
  --table-name test-table \
  --key-condition-expression "id = :id" \
  --expression-attribute-values '{":id": {"S": "1"}}'

# Scan
aws $FLOCI $FAKE dynamodb scan --table-name test-table

# Item güncelle
aws $FLOCI $FAKE dynamodb update-item \
  --table-name test-table \
  --key '{"id": {"S": "1"}, "sort": {"S": "a"}}' \
  --update-expression "SET #d = :d" \
  --expression-attribute-names '{"#d": "data"}' \
  --expression-attribute-values '{":d": {"S": "guncellendi"}}'

# Item sil
aws $FLOCI $FAKE dynamodb delete-item \
  --table-name test-table \
  --key '{"id": {"S": "1"}, "sort": {"S": "a"}}'

# Tablo sil
aws $FLOCI $FAKE dynamodb delete-table --table-name test-table
```

---

## 5. Lambda — Serverless

**What it does:** Write code, run serverless. Your function runs when an event triggers it; you pay only for what you run. Can be triggered by events like S3 uploads, API Gateway requests, or SQS messages.

```bash
# Fonksiyon zip'ini hazırla
mkdir -p /tmp/floci-test
cat > /tmp/floci-test/handler.py << 'EOF'
def handler(event, context):
    print("Event:", event)
    return {"statusCode": 200, "body": "merhaba floci"}
EOF
cat > /tmp/floci-test/requirements.txt << 'EOF'
requests==2.32.0
EOF
cd /tmp/floci-test && zip -r /tmp/fn.zip .

# Fonksiyon oluştur
aws $FLOCI $FAKE lambda create-function \
  --function-name test-fn \
  --runtime python3.12 \
  --role arn:aws:iam::000000000000:role/test-role \
  --handler handler.handler \
  --zip-file fileb:///tmp/fn.zip \
  --timeout 30 \
  --memory-size 256

# Fonksiyonları listele
aws $FLOCI $FAKE lambda list-functions

# Fonksiyon detayı
aws $FLOCI $FAKE lambda get-function --function-name test-fn

# Fonksiyon yapılandırması
aws $FLOCI $FAKE lambda get-function-configuration --function-name test-fn

# Çağır (sync)
aws $FLOCI $FAKE lambda invoke \
  --function-name test-fn \
  --payload '{"key": "value"}' \
  /tmp/response.json
cat /tmp/response.json

# Çağır (async — Event invocation)
aws $FLOCI $FAKE lambda invoke \
  --function-name test-fn \
  --invocation-type Event \
  --payload '{"async": true}' \
  /tmp/async-response.json

# Fonksiyon güncelle (kod)
cat > /tmp/floci-test/handler.py << 'EOF'
def handler(event, context):
    return {"statusCode": 200, "body": "versiyon 2"}
EOF
cd /tmp/floci-test && zip -r /tmp/fn-v2.zip .
aws $FLOCI $FAKE lambda update-function-code \
  --function-name test-fn \
  --zip-file fileb:///tmp/fn-v2.zip

# Fonksiyon sil
aws $FLOCI $FAKE lambda delete-function --function-name test-fn
```

---

## 6. IAM — Identity & Access Management

**What it does:** Answers "who can do what?". Controls access to AWS resources by defining users, groups, roles, and policies. IAM sits behind every AWS operation.

```bash
# Kullanıcı oluştur
aws $FLOCI $FAKE iam create-user --user-name test-user

# Kullanıcıları listele
aws $FLOCI $FAKE iam list-users

# Kullanıcı detayı
aws $FLOCI $FAKE iam get-user --user-name test-user

# Access Key oluştur
aws $FLOCI $FAKE iam create-access-key --user-name test-user

# Policy oluştur
aws $FLOCI $FAKE iam create-policy \
  --policy-name test-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListBucket","Resource":"*"}]}'

# Policy'leri listele
aws $FLOCI $FAKE iam list-policies --scope Local

# Policy ata
ACCOUNT_ID=000000000000
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/test-policy"
aws $FLOCI $FAKE iam attach-user-policy --user-name test-user --policy-arn "$POLICY_ARN"

# Role oluştur
aws $FLOCI $FAKE iam create-role \
  --role-name test-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Rolleri listele
aws $FLOCI $FAKE iam list-roles

# Kullanıcı sil
aws $FLOCI $FAKE iam detach-user-policy --user-name test-user --policy-arn "$POLICY_ARN"
aws $FLOCI $FAKE iam delete-policy --policy-arn "$POLICY_ARN"
aws $FLOCI $FAKE iam delete-user --user-name test-user
```

---

## 7. Secrets Manager

**What it does:** Securely stores sensitive data like passwords, API keys, and certificates, with automatic rotation. Pulled from this service instead of writing plain text into code. PostgreSQL credentials in the Laws/Floci project live here.

```bash
# Secret oluştur (text)
aws $FLOCI $FAKE secretsmanager create-secret \
  --name test-secret \
  --secret-string '{"username":"admin","password":"sifre123"}'

# Secret oluştur (binary)
aws $FLOCI $FAKE secretsmanager create-secret \
  --name test-binary-secret \
  --secret-binary "$(echo -n "binary-data" | base64)"

# Secret'ları listele
aws $FLOCI $FAKE secretsmanager list-secrets

# Secret oku
aws $FLOCI $FAKE secretsmanager get-secret-value --secret-id test-secret

# Secret güncelle
aws $FLOCI $FAKE secretsmanager put-secret-value \
  --secret-id test-secret \
  --secret-string '{"username":"admin","password":"yeni-sifre"}'

# Random secret oluştur
aws $FLOCI $FAKE secretsmanager get-random-password \
  --password-length 16 \
  --require-each-included-type

# Secret sil
aws $FLOCI $FAKE secretsmanager delete-secret --secret-id test-secret --force-delete-without-recovery
aws $FLOCI $FAKE secretsmanager delete-secret --secret-id test-binary-secret --force-delete-without-recovery
```

---

## 8. KMS — Key Management Service

**What it does:** Manages encryption keys. Used to encrypt/decrypt data. Services like S3, RDS, and Lambda integrate with KMS. Keys are protected in a hardware security module (HSM).

```bash
# Key oluştur
aws $FLOCI $FAKE kms create-key --description "test-key" --key-usage ENCRYPT_DECRYPT --origin AWS_KMS

# Key listele
aws $FLOCI $FAKE kms list-keys

# Key detayı
aws $FLOCI $FAKE kms describe-key --key-id alias/test-key

# Alias oluştur
KEY_ID=$(aws $FLOCI $FAKE kms list-keys --query Keys[0].KeyId --output text)
aws $FLOCI $FAKE kms create-alias --alias-name alias/test-key --target-key-id "$KEY_ID"

# Encrypt
echo -n "gizli-veri" > /tmp/plaintext.txt
aws $FLOCI $FAKE kms encrypt \
  --key-id "$KEY_ID" \
  --plaintext fileb:///tmp/plaintext.txt \
  --output text \
  --query CiphertextBlob | base64 --decode > /tmp/ciphertext.bin

# Decrypt
aws $FLOCI $FAKE kms decrypt \
  --ciphertext-blob fileb:///tmp/ciphertext.bin \
  --output text \
  --query Plaintext | base64 --decode

# Key sil (önce schedule, sonra cancel)
aws $FLOCI $FAKE kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7
aws $FLOCI $FAKE kms cancel-key-deletion --key-id "$KEY_ID"
```

---

## 9. CloudFormation — IaC

**What it does:** Defines infrastructure as code. Creates/deletes all AWS resources at once from a JSON/YAML template. The AWS equivalent of OpenTofu.

```bash
# Template oluştur
cat > /tmp/cf-template.yml << 'EOF'
AWSTemplateFormatVersion: "2010-09-09"
Resources:
  TestBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: cf-test-bucket
  TestQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: cf-test-queue
Outputs:
  BucketName:
    Value: !Ref TestBucket
EOF

# Stack oluştur
aws $FLOCI $FAKE cloudformation create-stack \
  --stack-name test-stack \
  --template-body file:///tmp/cf-template.yml

# Stack durumu
aws $FLOCI $FAKE cloudformation describe-stacks --stack-name test-stack

# Stack kaynakları
aws $FLOCI $FAKE cloudformation list-stack-resources --stack-name test-stack

# Stack output'ları
aws $FLOCI $FAKE cloudformation describe-stacks --stack-name test-stack --query "Stacks[0].Outputs"

# Stack güncelle
cat > /tmp/cf-template-v2.yml << 'EOF'
AWSTemplateFormatVersion: "2010-09-09"
Resources:
  TestBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: cf-test-bucket
  TestQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: cf-test-queue
  TestTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: cf-test-topic
EOF
aws $FLOCI $FAKE cloudformation update-stack \
  --stack-name test-stack \
  --template-body file:///tmp/cf-template-v2.yml

# Stack'leri listele
aws $FLOCI $FAKE cloudformation list-stacks

# Stack sil
aws $FLOCI $FAKE cloudformation delete-stack --stack-name test-stack
```

---

## 10. SSM — Systems Manager

**What it does:** A central service for managing EC2 and on-prem servers. Securely stores configuration data (DB URLs, feature flags) with Parameter Store. Also enables SSH-less command execution (Run Command) and patch management.

```bash
# Parameter Store'a parametre ekle
aws $FLOCI $FAKE ssm put-parameter --name /test/param --type String --value "test-degeri"

# Parametre oku (String)
aws $FLOCI $FAKE ssm get-parameter --name /test/param

# Parametre oku (decrypt — SecureString)
aws $FLOCI $FAKE ssm put-parameter --name /test/secure-param --type SecureString --value "gizli-deger"

# Parametreleri listele
aws $FLOCI $FAKE ssm describe-parameters

# Path'den parametreleri al
aws $FLOCI $FAKE ssm get-parameters-by-path --path /test

# Parametre sil
aws $FLOCI $FAKE ssm delete-parameter --name /test/param
aws $FLOCI $FAKE ssm delete-parameter --name /test/secure-param
```

---

## 11. API Gateway v1 (REST)

**What it does:** Used to create, publish, and manage REST APIs. Bridges clients and backend services (Lambda, HTTP, AWS services). Offers rate limiting, API keys, JWT auth, and similar features.

```bash
# REST API oluştur
aws $FLOCI $FAKE apigateway create-rest-api --name test-api --description "Test API"

# API ID'sini al
API_ID=$(aws $FLOCI $FAKE apigateway get-rest-apis --query items[0].id --output text)

# Kaynak (resource) oluştur
ROOT_ID=$(aws $FLOCI $FAKE apigateway get-resources --rest-api-id "$API_ID" --query items[0].id --output text)
RESOURCE_ID=$(aws $FLOCI $FAKE apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part "hello" --query id --output text)

# GET metodu ekle
aws $FLOCI $FAKE apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method GET \
  --authorization-type NONE

# Mock entegrasyon
aws $FLOCI $FAKE apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method GET \
  --type MOCK \
  --request-templates '{"application/json":"{\"statusCode\":200}"}'

# API'yi deploy et
aws $FLOCI $FAKE apigateway create-deployment --rest-api-id "$API_ID" --stage-name test

# API'yi çağır
curl -s "http://164.102.98.200:4566/restapis/$API_ID/test/_user_request_/hello"

# API'leri listele
aws $FLOCI $FAKE apigateway get-rest-apis
```

---

## 12. API Gateway v2 (HTTP)

**What it does:** A faster, cheaper version of REST v1. Designed only for HTTP/WebSocket APIs. Lacks v1 features like SOAP/API keys, but offers lower latency and cost.

```bash
# HTTP API oluştur
aws $FLOCI $FAKE apigatewayv2 create-api --name test-http-api --protocol-type HTTP

# API ID
HTTP_API_ID=$(aws $FLOCI $FAKE apigatewayv2 get-apis --query Items[0].ApiId --output text)

# Route oluştur
aws $FLOCI $FAKE apigatewayv2 create-route \
  --api-id "$HTTP_API_ID" \
  --route-key "GET /hello" \
  --target "integrations/MOCK"

# Stage oluştur
aws $FLOCI $FAKE apigatewayv2 create-stage --api-id "$HTTP_API_ID" --stage-name prod

# API'yi listele
aws $FLOCI $FAKE apigatewayv2 get-apis

# API sil
aws $FLOCI $FAKE apigatewayv2 delete-api --api-id "$HTTP_API_ID"
```

---

## 13. EC2 — Compute

**What it does:** Used to rent virtual servers (VMs) in the cloud. OS, CPU, RAM, and disk type are selectable. The AWS equivalent of the Proxmox VMs in our project.

```bash
# Instance'ları listele (Floci sanal döner)
aws $FLOCI $FAKE ec2 describe-instances

# Security Groups
aws $FLOCI $FAKE ec2 describe-security-groups

# Key Pair oluştur
aws $FLOCI $FAKE ec2 create-key-pair --key-name test-key --query KeyMaterial --output text > /tmp/test-key.pem
chmod 600 /tmp/test-key.pem

# VPC'leri listele
aws $FLOCI $FAKE ec2 describe-vpcs

# Subnet'leri listele
aws $FLOCI $FAKE ec2 describe-subnets

# AMI'leri listele
aws $FLOCI $FAKE ec2 describe-images --owners self

# Security Group oluştur
aws $FLOCI $FAKE ec2 create-security-group --group-name test-sg --description "Test SG"

# Key Pair sil
aws $FLOCI $FAKE ec2 delete-key-pair --key-name test-key
```

---

## 14. ECS — Elastic Container Service

**What it does:** Cluster management for running Docker containers. Simpler than Kubernetes, integrated with AWS. Containers are defined with Task Definitions; the running container count is set via Services.

```bash
# Cluster oluştur
aws $FLOCI $FAKE ecs create-cluster --cluster-name test-cluster

# Cluster'ları listele
aws $FLOCI $FAKE ecs list-clusters

# Task Definition oluştur
aws $FLOCI $FAKE ecs register-task-definition \
  --family test-task \
  --container-definitions '[{"name":"test-container","image":"nginx:latest","memory":256}]'

# Task Definition'ları listele
aws $FLOCI $FAKE ecs list-task-definitions

# Task çalıştır
aws $FLOCI $FAKE ecs run-task --cluster test-cluster --task-definition test-task

# Task'ları listele
aws $FLOCI $FAKE ecs list-tasks --cluster test-cluster

# Cluster sil
aws $FLOCI $FAKE ecs delete-cluster --cluster test-cluster
```

---

## 15. EKS — Elastic Kubernetes Service

**What it does:** Managed Kubernetes service on AWS. The control plane is managed by AWS; worker nodes run in your account. The AWS equivalent of our project's K8s cluster.

```bash
# Cluster'ları listele
aws $FLOCI $FAKE eks list-clusters

# Cluster oluştur (Floci'de sanal)
aws $FLOCI $FAKE eks create-cluster --name test-eks --role-arn arn:aws:iam::000000000000:role/eks-role --resources-vpc-config '{}'

# Cluster detayı
aws $FLOCI $FAKE eks describe-cluster --name test-eks

# Node group'ları listele
aws $FLOCI $FAKE eks list-nodegroups --cluster-name test-eks

# Cluster sil
aws $FLOCI $FAKE eks delete-cluster --name test-eks
```

---

## 16. Route53 — DNS

**What it does:** DNS management and domain registration service. Does name resolution, health checks, and traffic routing (latency-based, geolocation, weighted).

```bash
# Hosted Zone oluştur
aws $FLOCI $FAKE route53 create-hosted-zone --name test.tofu.lan --caller-reference "$(date +%s)"

# Zone'ları listele
aws $FLOCI $FAKE route53 list-hosted-zones

# Zone ID'yi al
HZ_ID=$(aws $FLOCI $FAKE route53 list-hosted-zones --query HostedZones[0].Id --output text | cut -d/ -f3)

# A record set oluştur
aws $FLOCI $FAKE route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch '{"Changes":[{"Action":"CREATE","ResourceRecordSet":{"Name":"floci.test.tofu.lan","Type":"A","TTL":300,"ResourceRecords":[{"Value":"10.0.0.1"}]}}]}'

# Record set'leri listele
aws $FLOCI $FAKE route53 list-resource-record-sets --hosted-zone-id "$HZ_ID"

# Record sil
aws $FLOCI $FAKE route53 change-resource-record-sets \
  --hosted-zone-id "$HZ_ID" \
  --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"floci.test.tofu.lan","Type":"A","TTL":300,"ResourceRecords":[{"Value":"10.0.0.1"}]}}]}'

# Zone sil
aws $FLOCI $FAKE route53 delete-hosted-zone --id "$HZ_ID"
```

---

## 17. CloudWatch Logs

**What it does:** Centrally collects, stores, and queries logs of AWS resources. Services like Lambda, EC2, and ECS send their logs here. Organized into log groups and streams.

```bash
# Log group oluştur
aws $FLOCI $FAKE logs create-log-group --log-group-name /test/floci

# Log stream oluştur
aws $FLOCI $FAKE logs create-log-stream --log-group-name /test/floci --log-stream-name test-stream

# Log event gönder
aws $FLOCI $FAKE logs put-log-events \
  --log-group-name /test/floci \
  --log-stream-name test-stream \
  --log-events "[{\"timestamp\":$(date +%s%3N),\"message\":\"test log mesaji\"}]"

# Log group'ları listele
aws $FLOCI $FAKE logs describe-log-groups

# Log stream'leri listele
aws $FLOCI $FAKE logs describe-log-streams --log-group-name /test/floci

# Log'ları oku
aws $FLOCI $FAKE logs get-log-events --log-group-name /test/floci --log-stream-name test-stream

# Log group sil
aws $FLOCI $FAKE logs delete-log-group --log-group-name /test/floci
```

---

## 18. CloudWatch Metrics (Monitoring)

**What it does:** Collects performance metrics (CPU, memory, network, disk I/O) of AWS resources; builds graphs and alarms. E.g. send email when CPU passes 90%.

```bash
# Metric listele
aws $FLOCI $FAKE cloudwatch list-metrics --namespace AWS/EC2

# Metric data put
aws $FLOCI $FAKE cloudwatch put-metric-data \
  --namespace Test/Floci \
  --metric-name TestMetric \
  --value 42 \
  --unit Count

# Alarm oluştur
aws $FLOCI $FAKE cloudwatch put-metric-alarm \
  --alarm-name test-alarm \
  --alarm-description "Test alarmi" \
  --metric-name TestMetric \
  --namespace Test/Floci \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold

# Alarm'ları listele
aws $FLOCI $FAKE cloudwatch describe-alarms

# Alarm sil
aws $FLOCI $FAKE cloudwatch delete-alarms --alarm-names test-alarm
```

---

## 19. EventBridge (Events)

**What it does:** A central event bus for routing AWS events. Used to build event-driven architectures like triggering Lambda when a file lands in an S3 bucket.

```bash
# Event bus oluştur
aws $FLOCI $FAKE events create-event-bus --name test-bus

# Event bus'ları listele
aws $FLOCI $FAKE events list-event-buses

# Rule oluştur
aws $FLOCI $FAKE events put-rule \
  --name test-rule \
  --event-pattern '{"source":["test.floci"]}'

# Rule'ları listele
aws $FLOCI $FAKE events list-rules

# Target ekle (SQS)
aws $FLOCI $FAKE sqs create-queue --queue-name test-event-queue
QUEUE_ARN=$(aws $FLOCI $FAKE sqs get-queue-attributes --queue-url http://164.102.98.200:4566/000000000000/test-event-queue --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws $FLOCI $FAKE events put-targets --rule test-rule --targets "Id=1,Arn=$QUEUE_ARN"

# Event gönder
aws $FLOCI $FAKE events put-events \
  --entries '[{"Source":"test.floci","DetailType":"TestEvent","Detail":"{\"key\":\"value\"}","EventBusName":"default"}]'

# Rule sil
aws $FLOCI $FAKE events remove-targets --rule test-rule --ids 1
aws $FLOCI $FAKE events delete-rule --name test-rule
```

---

## 20. EventBridge Scheduler

**What it does:** Used to create scheduled tasks (cron jobs). Triggers targets like Lambda, SQS, or Step Functions at intervals (every 5 min, daily, etc.). Supports cron and rate expressions.

```bash
# Schedule group oluştur
aws $FLOCI $FAKE scheduler create-schedule-group --name test-group

# Schedule oluştur
aws $FLOCI $FAKE scheduler create-schedule \
  --name test-schedule \
  --group-name test-group \
  --schedule-expression "rate(5 minutes)" \
  --flexible-time-window Mode=OFF \
  --target '{"Arn":"arn:aws:lambda:us-east-1:000000000000:function:test-fn","RoleArn":"arn:aws:iam::000000000000:role/scheduler-role"}'

# Schedule'ları listele
aws $FLOCI $FAKE scheduler list-schedules --group-name test-group

# Schedule sil
aws $FLOCI $FAKE scheduler delete-schedule --name test-schedule --group-name test-group
aws $FLOCI $FAKE scheduler delete-schedule-group --name test-group
```

---

## 21. EventBridge Pipes

**What it does:** Streams data from a source (SQS, DynamoDB Streams, Kinesis) to a target (Lambda, Step Functions, API Gateway). Can filter, transform, and enrich. Think of it as a bridge between SQS and Lambda.

```bash
# Pipe oluştur (SQS → Lambda)
aws $FLOCI $FAKE pipes create-pipe \
  --name test-pipe \
  --source arn:aws:sqs:us-east-1:000000000000:test-pipe-queue \
  --target arn:aws:lambda:us-east-1:000000000000:function:test-pipe-fn \
  --role-arn arn:aws:iam::000000000000:role/pipe-role

# Pipe'ları listele
aws $FLOCI $FAKE pipes list-pipes

# Pipe sil
aws $FLOCI $FAKE pipes delete-pipe --name test-pipe
```

---

## 22. Kinesis — Data Streams

**What it does:** Collects and processes real-time data streams (logs, IoT, clickstream). Splits incoming data into shards; multiple consumers can read at once. The managed AWS alternative to Kafka.

```bash
# Stream oluştur
aws $FLOCI $FAKE kinesis create-stream --stream-name test-stream --shard-count 1

# Stream'leri listele
aws $FLOCI $FAKE kinesis list-streams

# Stream detayı
aws $FLOCI $FAKE kinesis describe-stream --stream-name test-stream

# Shard'ları listele
aws $FLOCI $FAKE kinesis list-shards --stream-name test-stream

# Record gönder
aws $FLOCI $FAKE kinesis put-record \
  --stream-name test-stream \
  --data "$(echo -n "test-mesaji" | base64)" \
  --partition-key "pk-1"

# Record al
SHARD_ITERATOR=$(aws $FLOCI $FAKE kinesis get-shard-iterator --stream-name test-stream --shard-id shardId-000000000000 --shard-iterator-type TRIM_HORIZON --query ShardIterator --output text)
aws $FLOCI $FAKE kinesis get-records --shard-iterator "$SHARD_ITERATOR"

# Stream sil
aws $FLOCI $FAKE kinesis delete-stream --stream-name test-stream
```

---

## 23. Step Functions (States)

**What it does:** Builds workflows combining multiple AWS services. Defines step-by-step operations with a visual state machine, e.g.: call Lambda → decide → send SNS notification.

```bash
# State machine oluştur
cat > /tmp/state-machine.json << 'EOF'
{
  "Comment": "Test State Machine",
  "StartAt": "Hello",
  "States": {
    "Hello": {
      "Type": "Pass",
      "Result": "Merhaba Floci",
      "End": true
    }
  }
}
EOF
aws $FLOCI $FAKE stepfunctions create-state-machine \
  --name test-sm \
  --definition file:///tmp/state-machine.json \
  --role-arn arn:aws:iam::000000000000:role/sfn-role

# State machine'leri listele
aws $FLOCI $FAKE stepfunctions list-state-machines

# Execution başlat
aws $FLOCI $FAKE stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:000000000000:stateMachine:test-sm \
  --input '{"key":"value"}'

# Execution'ları listele
SM_ARN=$(aws $FLOCI $FAKE stepfunctions list-state-machines --query stateMachines[0].stateMachineArn --output text)
aws $FLOCI $FAKE stepfunctions list-executions --state-machine-arn "$SM_ARN"

# Execution detayı
EXEC_ARN=$(aws $FLOCI $FAKE stepfunctions list-executions --state-machine-arn "$SM_ARN" --query executions[0].executionArn --output text)
aws $FLOCI $FAKE stepfunctions describe-execution --execution-arn "$EXEC_ARN"

# State machine sil
aws $FLOCI $FAKE stepfunctions delete-state-machine --state-machine-arn "$SM_ARN"
```

---

## 24. ACM — Certificate Manager

**What it does:** Automatically creates, manages, and renews SSL/TLS certificates. Provides free certificates for AWS-integrated services (CloudFront, ELB, API Gateway). The AWS equivalent of cert-manager + OpenBao PKI in our project.

```bash
# Sertifika talep et
aws $FLOCI $FAKE acm request-certificate \
  --domain-name "test.tofu.lan" \
  --validation-method DNS

# Sertifikaları listele
aws $FLOCI $FAKE acm list-certificates

# Sertifika detayı
CERT_ARN=$(aws $FLOCI $FAKE acm list-certificates --query CertificateSummaryList[0].CertificateArn --output text)
aws $FLOCI $FAKE acm describe-certificate --certificate-arn "$CERT_ARN"

# Sertifika sil
aws $FLOCI $FAKE acm delete-certificate --certificate-arn "$CERT_ARN"
```

---

## 25. Cognito — Identity Provider

**What it does:** Ready-made identity management for user signup, sign-in, and authorization. Offers social login (Google, Apple), MFA, and JWT token support. Used to add fast auth to mobile/web apps.

```bash
# User Pool oluştur
aws $FLOCI $FAKE cognito-idp create-user-pool --pool-name test-pool

# User Pool'ları listele
aws $FLOCI $FAKE cognito-idp list-user-pools --max-results 10

# Pool ID'yi al
POOL_ID=$(aws $FLOCI $FAKE cognito-idp list-user-pools --max-results 10 --query UserPools[0].Id --output text)

# App Client oluştur
aws $FLOCI $FAKE cognito-idp create-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-name test-client

# Kullanıcı kaydet
aws $FLOCI $FAKE cognito-idp sign-up \
  --client-id $(aws $FLOCI $FAKE cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --query UserPoolClients[0].ClientId --output text) \
  --username testuser \
  --password Test1234!

# Kullanıcıları listele
aws $FLOCI $FAKE cognito-idp list-users --user-pool-id "$POOL_ID"

# Pool sil
aws $FLOCI $FAKE cognito-idp delete-user-pool --user-pool-id "$POOL_ID"
```

---

## 26. SES — Email Service

**What it does:** Bulk email sending and receiving service. Used for transactional emails (password resets, order confirmations) and marketing emails. Offers high deliverability.

```bash
# Email adresini doğrula
aws $FLOCI $FAKE ses verify-email-identity --email-address test@tofu.lan

# Doğrulanmış adresleri listele
aws $FLOCI $FAKE ses list-identities

# Email gönder
aws $FLOCI $FAKE ses send-email \
  --from test@tofu.lan \
  --destination ToAddresses=alici@tofu.lan \
  --message "Subject={Data=Test Konusu,Charset=utf-8},Body={Text={Data=Test mesaji,Charset=utf-8}}"

# Email gönder (raw)
aws $FLOCI $FAKE ses send-raw-email \
  --raw-message "Data=$(echo -e 'From: test@tofu.lan\nTo: alici@tofu.lan\nSubject: Raw Test\n\nRaw mesaj' | base64 -w0)"
```

---

## 27. Kinesis Firehose

**What it does:** Automatically loads real-time data into S3, Redshift, or Elasticsearch. Unlike Kinesis Streams: no consumer to write, writes directly to the target. Can transform and compress data.

```bash
# Firehose delivery stream oluştur (S3 hedef)
aws $FLOCI $FAKE firehose create-delivery-stream \
  --delivery-stream-name test-firehose \
  --s3-destination-configuration \
  '{"BucketARN":"arn:aws:s3:::test-firehose-bucket","RoleARN":"arn:aws:iam::000000000000:role/firehose-role"}'

# Stream'leri listele
aws $FLOCI $FAKE firehose list-delivery-streams

# Stream detayı
aws $FLOCI $FAKE firehose describe-delivery-stream --delivery-stream-name test-firehose

# Record gönder
aws $FLOCI $FAKE firehose put-record \
  --delivery-stream-name test-firehose \
  --record '{"Data":"dGVzdCByZWNvcmQ="}'

# Stream sil
aws $FLOCI $FAKE firehose delete-delivery-stream --delivery-stream-name test-firehose
```

---

## 28. RDS — Relational Database Service

**What it does:** Runs relational databases like PostgreSQL, MySQL, and MariaDB as managed services. Backups, replication, and automatic patching are handled by AWS. Used for the PostgreSQL–Laws connection in our project.

```bash
# DB instance'ları listele
aws $FLOCI $FAKE rds describe-db-instances

# DB subnet group oluştur
aws $FLOCI $FAKE rds create-db-subnet-group \
  --db-subnet-group-name test-subnet-group \
  --db-subnet-group-description "Test" \
  --subnet-ids subnet-123

# DB instance oluştur
aws $FLOCI $FAKE rds create-db-instance \
  --db-instance-identifier test-pg \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --master-username postgres \
  --master-user-password postgres123 \
  --allocated-storage 20

# Snapshot oluştur
aws $FLOCI $FAKE rds create-db-snapshot \
  --db-instance-identifier test-pg \
  --db-snapshot-identifier test-pg-snapshot

# DB instance sil
aws $FLOCI $FAKE rds delete-db-instance \
  --db-instance-identifier test-pg \
  --skip-final-snapshot
```

---

## 29. ElastiCache — Redis

**What it does:** Managed service for running Redis or Memcached cache servers. Speeds up apps by caching database query results and session data.

```bash
# Cache cluster'ları listele
aws $FLOCI $FAKE elasticache describe-cache-clusters

# Cache cluster oluştur
aws $FLOCI $FAKE elasticache create-cache-cluster \
  --cache-cluster-id test-redis \
  --engine redis \
  --cache-node-type cache.t3.micro \
  --num-cache-nodes 1

# Snapshot oluştur
aws $FLOCI $FAKE elasticache create-snapshot \
  --cache-cluster-id test-redis \
  --snapshot-name test-redis-snap

# Cache cluster sil
aws $FLOCI $FAKE elasticache delete-cache-cluster --cache-cluster-id test-redis
```

---

## 30. MemoryDB — Redis

**What it does:** Redis-compatible, persistent in-memory database. Unlike ElastiCache: no data loss, because data is written to durable storage. Preferred when Redis holds critical data.

```bash
# Cluster'ları listele
aws $FLOCI $FAKE memorydb describe-clusters

# Cluster oluştur
aws $FLOCI $FAKE memorydb create-cluster \
  --cluster-name test-memorydb \
  --node-type db.t4g.small \
  --acl-name open-access

# Snapshot oluştur
aws $FLOCI $FAKE memorydb create-snapshot \
  --cluster-name test-memorydb \
  --snapshot-name test-memorydb-snap

# Cluster sil
aws $FLOCI $FAKE memorydb delete-cluster --cluster-name test-memorydb
```

---

## 31. MSK — Kafka

**What it does:** Runs Apache Kafka as a managed service. Used for high-volume message streams, event sourcing, and stream processing. Unlike Kinesis: Kafka API compatible, existing Kafka apps are portable.

```bash
# Cluster'ları listele
aws $FLOCI $FAKE kafka list-clusters

# Cluster oluştur
aws $FLOCI $FAKE kafka create-cluster \
  --cluster-name test-kafka \
  --kafka-version 3.7.0 \
  --number-of-broker-nodes 1 \
  --broker-node-group-info '{"InstanceType":"kafka.t3.small","ClientSubnets":["subnet-123"]}'

# Cluster detayı
aws $FLOCI $FAKE kafka describe-cluster --cluster-arn arn:aws:kafka:us-east-1:000000000000:cluster/test-kafka/123

# Configuration'ları listele
aws $FLOCI $FAKE kafka list-configurations
```

---

## 32. MQ — ActiveMQ/RabbitMQ

**What it does:** Runs classic message brokers like ActiveMQ and RabbitMQ as managed services. Supports JMS, AMQP, and MQTT. Unlike SQS/SNS: uses standard messaging protocols, existing apps move easily.

```bash
# Broker'ları listele
aws $FLOCI $FAKE mq list-brokers

# Broker oluştur
aws $FLOCI $FAKE mq create-broker \
  --broker-name test-mq \
  --engine-type ActiveMQ \
  --engine-version 5.18 \
  --host-instance-type mq.t3.micro \
  --users '[{"Username":"admin","Password":"Admin123!"}]'

# Broker detayı
aws $FLOCI $FAKE mq describe-broker --broker-id test-mq

# Configuration'ları listele
aws $FLOCI $FAKE mq list-configurations
```

---

## 33. ECR — Container Registry

**What it does:** A private registry for storing and managing Docker container images. AWS's private version of Docker Hub. Integrates with ECS and EKS; stores images securely.

```bash
# Repository oluştur
aws $FLOCI $FAKE ecr create-repository --repository-name test-repo

# Repository'leri listele
aws $FLOCI $FAKE ecr describe-repositories

# Repository detayı
aws $FLOCI $FAKE ecr describe-repositories --repository-names test-repo

# Image listele (Floci'de boş döner)
aws $FLOCI $FAKE ecr list-images --repository-name test-repo

# Repository sil
aws $FLOCI $FAKE ecr delete-repository --repository-name test-repo --force
```

---

## 34. ELB — Elastic Load Balancing

**What it does:** Distributes incoming traffic across multiple targets (EC2, ECS, Lambda). Three types: ALB (HTTP/HTTPS), NLB (TCP/UDP), GLB (Geneve). Health checks automatically disable unhealthy targets.

```bash
# Load balancer'ları listele
aws $FLOCI $FAKE elbv2 describe-load-balancers

# Target group oluştur
aws $FLOCI $FAKE elbv2 create-target-group \
  --name test-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id vpc-12345 \
  --target-type instance

# Target group'ları listele
aws $FLOCI $FAKE elbv2 describe-target-groups

# Load balancer oluştur (ALB)
aws $FLOCI $FAKE elbv2 create-load-balancer \
  --name test-alb \
  --subnets subnet-123 \
  --type application

# Listener oluştur
LB_ARN=$(aws $FLOCI $FAKE elbv2 describe-load-balancers --query LoadBalancers[0].LoadBalancerArn --output text)
TG_ARN=$(aws $FLOCI $FAKE elbv2 describe-target-groups --query TargetGroups[0].TargetGroupArn --output text)
aws $FLOCI $FAKE elbv2 create-listener \
  --load-balancer-arn "$LB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"
```

---

## 35. Auto Scaling

**What it does:** Automatically scales EC2 instance count to demand. An ASG (Auto Scaling Group) is defined with min/max/desired capacity. Scales out/in on CloudWatch alarms.

```bash
# Launch configuration oluştur
aws $FLOCI $FAKE autoscaling create-launch-configuration \
  --launch-configuration-name test-lc \
  --image-id ami-12345 \
  --instance-type t3.micro

# Auto Scaling group oluştur
aws $FLOCI $FAKE autoscaling create-auto-scaling-group \
  --auto-scaling-group-name test-asg \
  --launch-configuration-name test-lc \
  --min-size 1 --max-size 3 --desired-capacity 1 \
  --availability-zones us-east-1a

# ASG'leri listele
aws $FLOCI $FAKE autoscaling describe-auto-scaling-groups

# Scaling policy
aws $FLOCI $FAKE autoscaling put-scaling-policy \
  --auto-scaling-group-name test-asg \
  --policy-name scale-up \
  --scaling-adjustment 1 \
  --adjustment-type ChangeInCapacity

# ASG sil
aws $FLOCI $FAKE autoscaling delete-auto-scaling-group --auto-scaling-group-name test-asg --force-delete
aws $FLOCI $FAKE autoscaling delete-launch-configuration --launch-configuration-name test-lc
```

---

## 36. Elastic Beanstalk

**What it does:** Auto-deploys web apps (Node.js, Python, Java, Go, etc.). Upload code without dealing with infrastructure and it runs. Automatically sets up EC2, ELB, Auto Scaling, and RDS.

```bash
# Application oluştur
aws $FLOCI $FAKE elasticbeanstalk create-application --application-name test-app

# Application'ları listele
aws $FLOCI $FAKE elasticbeanstalk describe-applications

# Environment oluştur
aws $FLOCI $FAKE elasticbeanstalk create-environment \
  --application-name test-app \
  --environment-name test-env \
  --solution-stack-name "64bit Amazon Linux 2023 v6.2.0 running Node.js 22"

# Environment'ları listele
aws $FLOCI $FAKE elasticbeanstalk describe-environments

# Application sil
aws $FLOCI $FAKE elasticbeanstalk delete-application --application-name test-app --terminate-env-by-force
```

---

## 37. CloudFront — CDN

**What it does:** Content delivery network (CDN) service. Caches static files (images, CSS, JS) at edge locations around the world for fast loading. Also offers DDoS protection.

```bash
# Distribution oluştur
aws $FLOCI $FAKE cloudfront create-distribution \
  --distribution-config '{
    "CallerReference":"test-ref",
    "Origins":{"Items":[{"Id":"default","DomainName":"test.tofu.lan","OriginPath":"","CustomOriginConfig":{"HTTPPort":80,"HTTPSPort":443,"OriginProtocolPolicy":"match-viewer"}}],"Quantity":1},
    "DefaultCacheBehavior":{"TargetOriginId":"default","ViewerProtocolPolicy":"allow-all","AllowedMethods":{"Items":["GET","HEAD"],"Quantity":2},"CachedMethods":{"Items":["GET","HEAD"],"Quantity":2}},
    "Enabled":true
  }'

# Distribution'ları listele
aws $FLOCI $FAKE cloudfront list-distributions

# Distribution detayı
DIST_ID=$(aws $FLOCI $FAKE cloudfront list-distributions --query DistributionList.Items[0].Id --output text)
aws $FLOCI $FAKE cloudfront get-distribution --id "$DIST_ID"

# Distribution sil (önce disable etmek gerek)
aws $FLOCI $FAKE cloudfront update-distribution --id "$DIST_ID" --distribution-config '{"Enabled":false,"CallerReference":"test-ref"}'
```

---

## 38. WAFv2 — Web Application Firewall

**What it does:** Protects web apps against SQL injection, XSS, DDoS, and similar attacks. Attached in front of CloudFront, ALB, or API Gateway. You can write your own rules or use AWS managed rule groups.

```bash
# Web ACL oluştur
aws $FLOCI $FAKE wafv2 create-web-acl \
  --name test-waf \
  --scope REGIONAL \
  --default-action '{"Allow":{}}' \
  --visibility-config '{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"test-waf"}'

# Web ACL'leri listele
aws $FLOCI $FAKE wafv2 list-web-acls --scope REGIONAL

# IP set oluştur
aws $FLOCI $FAKE wafv2 create-ip-set \
  --name test-ipset \
  --scope REGIONAL \
  --ip-address-version IPV4 \
  --addresses 10.0.0.0/8

# Rule group oluştur
aws $FLOCI $FAKE wafv2 create-rule-group \
  --name test-rule-group \
  --scope REGIONAL \
  --capacity 10 \
  --visibility-config '{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"test-rule-group"}'

# Web ACL sil
WAF_ARN=$(aws $FLOCI $FAKE wafv2 list-web-acls --scope REGIONAL --query WebACLs[0].ARN --output text)
aws $FLOCI $FAKE wafv2 delete-web-acl --name test-waf --scope REGIONAL --id "$(echo $WAF_ARN | rev | cut -d/ -f1 | rev)" --lock-token "$(aws $FLOCI $FAKE wafv2 get-web-acl --name test-waf --scope REGIONAL --id "$(echo $WAF_ARN | rev | cut -d/ -f1 | rev)" --query LockToken --output text)"
```

---

## 39. CloudTrail

**What it does:** Records all API calls in the AWS account (audit log). Answers who called which API when and changed which resource. Required for security and compliance.

```bash
# Trail oluştur
aws $FLOCI $FAKE cloudtrail create-trail \
  --name test-trail \
  --s3-bucket-name test-trail-bucket \
  --is-multi-region-trail

# Trail'leri listele
aws $FLOCI $FAKE cloudtrail describe-trails

# Trail detayı
aws $FLOCI $FAKE cloudtrail get-trail --name test-trail

# Trail status
aws $FLOCI $FAKE cloudtrail get-trail-status --name test-trail

# Trail sil
aws $FLOCI $FAKE cloudtrail delete-trail --name test-trail
```

---

## 40. CodeBuild

**What it does:** Compiles, tests, and packages source code. Manages the build stage of CI/CD pipelines. Build commands are defined in buildspec.yml.

```bash
# Project oluştur
aws $FLOCI $FAKE codebuild create-project \
  --name test-project \
  --source '{"type":"GITHUB","location":"https://github.com/test/repo.git"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role arn:aws:iam::000000000000:role/codebuild-role

# Project'leri listele
aws $FLOCI $FAKE codebuild list-projects

# Build başlat
aws $FLOCI $FAKE codebuild start-build --project-name test-project

# Build'leri listele
aws $FLOCI $FAKE codebuild list-builds --sort-order DESCENDING

# Project sil
aws $FLOCI $FAKE codebuild delete-project --name test-project
```

---

## 41. CodePipeline

**What it does:** Visually defines and manages CI/CD pipelines. Combines source (GitHub), build (CodeBuild), and deploy (CodeDeploy/ECS/Lambda) stages. Sets up the git push → auto test → go-live flow.

```bash
# Pipeline oluştur
aws $FLOCI $FAKE codepipeline create-pipeline \
  --pipeline '{"name":"test-pipeline","roleArn":"arn:aws:iam::000000000000:role/codepipeline-role","stages":[{"name":"Source","actions":[{"name":"Source","actionTypeId":{"category":"Source","owner":"AWS","provider":"S3","version":"1"},"configuration":{"S3Bucket":"test-bucket","S3ObjectKey":"test.zip"},"runOrder":1}]},{"name":"Deploy","actions":[{"name":"Deploy","actionTypeId":{"category":"Deploy","owner":"AWS","provider":"S3","version":"1"},"configuration":{"BucketName":"test-output"},"runOrder":1}]}]}'

# Pipeline'ları listele
aws $FLOCI $FAKE codepipeline list-pipelines

# Pipeline detayı
aws $FLOCI $FAKE codepipeline get-pipeline --name test-pipeline

# Pipeline sil
aws $FLOCI $FAKE codepipeline delete-pipeline --name test-pipeline
```

---

## 42. CodeDeploy

**What it does:** Automates application deployments. Releases new versions to EC2, Lambda, or ECS. Supports rolling update, blue/green, and canary strategies.

```bash
# Application oluştur
aws $FLOCI $FAKE codedeploy create-application --application-name test-codedeploy --compute-platform Server --deployment-config-name CodeDeployDefault.AllAtOnce

# Application'ları listele
aws $FLOCI $FAKE codedeploy list-applications

# Deployment group oluştur
aws $FLOCI $FAKE codedeploy create-deployment-group \
  --application-name test-codedeploy \
  --deployment-group-name test-group \
  --service-role-arn arn:aws:iam::000000000000:role/codedeploy-role

# Application sil
aws $FLOCI $FAKE codedeploy delete-application --application-name test-codedeploy
```

---

## 43. Batch

**What it does:** Manages batch computing jobs. Can run thousands of jobs in parallel, cleans up resources when done. Ideal for data transformation, simulation, and media encoding.

```bash
# Compute environment oluştur
aws $FLOCI $FAKE batch create-compute-environment \
  --compute-environment-name test-batch-env \
  --type MANAGED \
  --service-role arn:aws:iam::000000000000:role/batch-role

# Job queue oluştur
aws $FLOCI $FAKE batch create-job-queue \
  --job-queue-name test-queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=test-batch-env

# Job definition oluştur
aws $FLOCI $FAKE batch register-job-definition \
  --job-definition-name test-job-def \
  --type container \
  --container-properties '{"image":"busybox","command":["echo","hello"],"memory":128,"vcpus":1}'

# Job'ları listele
aws $FLOCI $FAKE batch list-jobs --job-queue test-queue --job-status RUNNABLE
```

---

## 44. Glue — ETL

**What it does:** ETL (Extract, Transform, Load) for data warehouses and data lakes. Reads data from a source, transforms it, and writes to a target (S3, Redshift, RDS). Uses Spark infrastructure.

```bash
# Database oluştur
aws $FLOCI $FAKE glue create-database --database-input '{"Name":"test_glue_db"}'

# Database'leri listele
aws $FLOCI $FAKE glue get-databases

# Table oluştur
aws $FLOCI $FAKE glue create-table \
  --database-name test_glue_db \
  --table-input '{"Name":"test_table","StorageDescriptor":{"Columns":[{"Name":"id","Type":"int"},{"Name":"data","Type":"string"}]}}'

# Table'ları listele
aws $FLOCI $FAKE glue get-tables --database-name test_glue_db

# Crawler oluştur
aws $FLOCI $FAKE glue create-crawler \
  --name test-crawler \
  --role arn:aws:iam::000000000000:role/glue-role \
  --database-name test_glue_db \
  --targets '{"S3Targets":[{"Path":"s3://test-bucket/data"}]}'

# Crawler'ları listele
aws $FLOCI $FAKE glue get-crawlers

# Database sil
aws $FLOCI $FAKE glue delete-database --name test_glue_db
```

---

## 45. Athena — SQL Query

**What it does:** Queries data in S3 directly with SQL. SELECT over CSV/JSON/Parquet files without setting up a database or moving data. Ideal for log analysis in S3.

```bash
# Athena workgroup oluştur
aws $FLOCI $FAKE athena create-work-group --name test-workgroup --configuration '{"ResultConfiguration":{"OutputLocation":"s3://test-athena-results/"}}'

# Workgroup'ları listele
aws $FLOCI $FAKE athena list-work-groups

# Query başlat
QUERY_EXEC_ID=$(aws $FLOCI $FAKE athena start-query-execution \
  --query-string "SELECT 1 as test" \
  --work-group test-workgroup \
  --query QueryExecutionId --output text)

# Query durumu
aws $FLOCI $FAKE athena get-query-execution --query-execution-id "$QUERY_EXEC_ID"

# Query sonucu (eğer tamamlandıysa)
aws $FLOCI $FAKE athena get-query-results --query-execution-id "$QUERY_EXEC_ID"

# Workgroup sil
aws $FLOCI $FAKE athena delete-work-group --work-group test-workgroup
```

---

## 46. EMR — Elastic MapReduce

**What it does:** Runs frameworks like Hadoop, Spark, Hive, and Presto as managed services for big data processing. Used to analyze petabytes of data.

```bash
# Cluster'ları listele
aws $FLOCI $FAKE emr list-clusters

# Cluster oluştur
aws $FLOCI $FAKE emr create-cluster \
  --name test-emr \
  --release-label emr-7.5.0 \
  --applications Name=Spark \
  --instance-groups InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m5.xlarge \
  --service-role EMR_DefaultRole

# Cluster detayı
CLUSTER_ID=$(aws $FLOCI $FAKE emr list-clusters --query Clusters[0].Id --output text)
aws $FLOCI $FAKE emr describe-cluster --cluster-id "$CLUSTER_ID"

# Step ekle
aws $FLOCI $FAKE emr add-steps \
  --cluster-id "$CLUSTER_ID" \
  --steps Type=Spark,Name=test-step,ActionOnFailure=CONTINUE,Jar=command-runner.jar,Args=["spark-submit","--deploy-mode","cluster"]

# Cluster sil
aws $FLOCI $FAKE emr terminate-clusters --cluster-ids "$CLUSTER_ID"
```

---

## 47. Elasticsearch / OpenSearch

**What it does:** Distributed database for search and log analysis. Offers full-text search, structured queries, and visualization (Kibana). The AWS equivalent of Elasticsearch in our project's EFK stack.

```bash
# Domain oluştur
aws $FLOCI $FAKE es create-elasticsearch-domain --domain-name test-es

# Domain'leri listele
aws $FLOCI $FAKE es list-domain-names

# Domain detayı
aws $FLOCI $FAKE es describe-elasticsearch-domain --domain-name test-es

# Domain sil
aws $FLOCI $FAKE es delete-elasticsearch-domain --domain-name test-es
```

---

## 48. Config — Resource Compliance

**What it does:** Audits AWS resources for rule compliance. E.g. set a "S3 buckets must not be public" rule; flags non-compliant resources. Records changes and sends alerts.

```bash
# Config recorder oluştur
aws $FLOCI $FAKE config put-configuration-recorder \
  --configuration-recorder name=test-recorder,roleARN=arn:aws:iam::000000000000:role/config-role

# Config rule oluştur
aws $FLOCI $FAKE config put-config-rule \
  --config-rule '{"ConfigRuleName":"test-rule","Source":{"Owner":"AWS","SourceIdentifier":"S3_BUCKET_PUBLIC_READ_PROHIBITED"}}'

# Rule'ları listele
aws $FLOCI $FAKE config describe-config-rules

# Compliance durumu
aws $FLOCI $FAKE config get-compliance-details-by-config-rule --config-rule-name test-rule
```

---

## 49. Service Discovery

**What it does:** Lets microservices find each other. Services register and discover via DNS or API. Integrates with ECS, EKS, and EC2.

```bash
# Namespace oluştur
aws $FLOCI $FAKE servicediscovery create-public-dns-namespace --name test.tofu.lan

# Namespace'leri listele
aws $FLOCI $FAKE servicediscovery list-namespaces

# Service oluştur
aws $FLOCI $FAKE servicediscovery create-service \
  --name test-svc \
  --dns-config '{"NamespaceId":"ns-123","DnsRecords":[{"Type":"A","TTL":300}]}'

# Service'leri listele
aws $FLOCI $FAKE servicediscovery list-services
```

---

## 50. Resource Groups & Tagging

**What it does:** Groups and manages resources with tags. With tags (e.g. Environment=dev, Project=tofu-lar) you can filter resources, analyze costs, and define automation rules.

```bash
# Tag oluştur (S3 bucket üzerinde)
aws $FLOCI $FAKE s3 mb s3://tag-test-bucket
aws $FLOCI $FAKE tagging tag-resources \
  --resource-arn-list arn:aws:s3:::tag-test-bucket \
  --tags Key=env,Value=test

# Tag'leri listele
aws $FLOCI $FAKE tagging get-resources --tag-filters Key=env,Values=test

# Tag sil
aws $FLOCI $FAKE tagging untag-resources \
  --resource-arn-list arn:aws:s3:::tag-test-bucket \
  --tag-keys env

aws $FLOCI $FAKE s3 rb s3://tag-test-bucket
```

---

## 51. Lightsail

**What it does:** AWS's simplified virtual server service. Fixed-price (starting at $3.50/month), predictable cost. Easier than EC2 for small projects, blogs, and dev environments.

```bash
# Instance'ları listele
aws $FLOCI $FAKE lightsail get-instances

# Instance oluştur
aws $FLOCI $FAKE lightsail create-instances \
  --instance-names test-lightsail \
  --availability-zone us-east-1a \
  --blueprint-id ubuntu_22_04 \
  --bundle-id micro_2_0

# Static IP oluştur
aws $FLOCI $FAKE lightsail allocate-static-ip --static-ip-name test-ip

# Instance sil
aws $FLOCI $FAKE lightsail delete-instance --instance-name test-lightsail
```

---

## 52. Backup

**What it does:** Automatically creates and manages backups of AWS resources. Define a backup plan (when, how often, how long to keep); AWS backs up automatically. The AWS equivalent of the maintenance/ directory in our project.

```bash
# Backup plan oluştur
aws $FLOCI $FAKE backup create-backup-plan \
  --backup-plan '{"BackupPlanName":"test-plan","BackupPlanRule":[{"RuleName":"test-rule","TargetBackupVaultName":"Default","ScheduleExpression":"cron(0 5 * * ? *)","StartWindowMinutes":60,"Lifecycle":{"DeleteAfterDays":7}}]}'

# Plan'ları listele
aws $FLOCI $FAKE backup list-backup-plans

# Vault'ları listele
aws $FLOCI $FAKE backup list-backup-vaults

# Plan sil
PLAN_ID=$(aws $FLOCI $FAKE backup list-backup-plans --query BackupPlansList[0].BackupPlanId --output text)
aws $FLOCI $FAKE backup delete-backup-plan --backup-plan-id "$PLAN_ID"
```

---

## 53. Transfer Family — SFTP

**What it does:** Offers a managed server for uploading files to S3 over SFTP, FTPS, and FTP. Used when your customers need to send you files over SFTP. No infrastructure management needed.

```bash
# Server oluştur
aws $FLOCI $FAKE transfer create-server --endpoint-type PUBLIC --identity-provider-type SERVICE_MANAGED

# Server'ları listele
aws $FLOCI $FAKE transfer list-servers

# Kullanıcı oluştur
SERVER_ID=$(aws $FLOCI $FAKE transfer list-servers --query Servers[0].ServerId --output text)
aws $FLOCI $FAKE transfer create-user \
  --server-id "$SERVER_ID" \
  --user-name test-user \
  --role arn:aws:iam::000000000000:role/transfer-role \
  --home-directory /test

# Kullanıcıları listele
aws $FLOCI $FAKE transfer list-users --server-id "$SERVER_ID"

# Server sil
aws $FLOCI $FAKE transfer delete-server --server-id "$SERVER_ID"
```

---

## 54. AppSync — GraphQL API

**What it does:** Managed service for building GraphQL APIs. Offers real-time data (WebSocket/Subscriptions), offline support, and data source (DynamoDB, Lambda, RDS) integration. Ideal for mobile apps.

```bash
# API oluştur
aws $FLOCI $FAKE appsync create-graphql-api \
  --name test-api \
  --authentication-type API_KEY

# API'leri listele
aws $FLOCI $FAKE appsync list-graphql-apis

# API Key oluştur
API_ID=$(aws $FLOCI $FAKE appsync list-graphql-apis --query graphqlApis[0].apiId --output text)
aws $FLOCI $FAKE appsync create-api-key --api-id "$API_ID"

# API Key'leri listele
aws $FLOCI $FAKE appsync list-api-keys --api-id "$API_ID"

# API sil
aws $FLOCI $FAKE appsync delete-graphql-api --api-id "$API_ID"
```

---

## 55. AppConfig

**What it does:** Lets you change app configs (feature flags, allow lists, throttle limits) in a live system without deploying. E.g. open a new feature to 10% of users; roll out to 100% if fine.

```bash
# Application oluştur
aws $FLOCI $FAKE appconfig create-application --name test-appconfig

# Application'ları listele
aws $FLOCI $FAKE appconfig list-applications

# Configuration profile oluştur
APP_ID=$(aws $FLOCI $FAKE appconfig list-applications --query Items[0].Id --output text)
aws $FLOCI $FAKE appconfig create-configuration-profile \
  --application-id "$APP_ID" \
  --name test-profile \
  --location-uri hosted

# Deployment strategy oluştur
aws $FLOCI $FAKE appconfig create-deployment-strategy \
  --name test-strategy \
  --deployment-duration-in-minutes 15 \
  --growth-factor 100 \
  --growth-type LINEAR

# Application sil
aws $FLOCI $FAKE appconfig delete-application --application-id "$APP_ID"
```

---

## 56. CloudControl

**What it does:** Creates/updates/deletes AWS resources (S3, EC2, RDS, ...) through a single uniform API. The programmatic backend of CloudFormation. No need to learn a separate API per resource type.

```bash
# API'yi bekleme — doğrudan resource yönetimi
# Resource listele
aws $FLOCI $FAKE cloudcontrol list-resources --type-name AWS::S3::Bucket

# Resource oluştur
aws $FLOCI $FAKE cloudcontrol create-resource \
  --type-name AWS::S3::Bucket \
  --desired-state '{"BucketName":"cc-test-bucket"}'

# Resource sil
CC_BUCKET_ID=$(aws $FLOCI $FAKE cloudcontrol list-resources --type-name AWS::S3::Bucket --query ResourceDescriptions[0].Identifier --output text)
aws $FLOCI $FAKE cloudcontrol delete-resource --type-name AWS::S3::Bucket --identifier "$CC_BUCKET_ID"
```

---

## 57. Bedrock Runtime — AI

**What it does:** Managed service for calling large language models (LLM) via API. Use models like Claude, Llama, and Mistral through one API. No need to host your own model.

```bash
# Foundation models listele (Floci'de sınırlı)
aws $FLOCI $FAKE bedrock list-foundation-models

# Model inference (Floci mock döner)
aws $FLOCI $FAKE bedrock-runtime invoke-model \
  --model-id anthropic.claude-v3-sonnet \
  --content-type application/json \
  --accept application/json \
  --body '{"prompt":"merhaba","max_tokens":100}' \
  /tmp/bedrock-response.json
cat /tmp/bedrock-response.json

# Model'leri listele
aws $FLOCI $FAKE bedrock list-foundation-models --query modelSummaries[].modelId
```

---

## 58. Textract — Document AI

**What it does:** Automatically extracts text, tables, and form data from documents (PDF, images). An advanced version of OCR (optical character recognition). Used to digitize invoices, ID cards, and contracts.

```bash
# Document analizi başlat
aws $FLOCI $FAKE textract start-document-text-detection \
  --document-location '{"S3Object":{"Bucket":"test-bucket","Name":"test-doc.pdf"}}'

# Document analysis
aws $FLOCI $FAKE textract start-document-analysis \
  --document-location '{"S3Object":{"Bucket":"test-bucket","Name":"test-doc.pdf"}}' \
  --feature-types TABLES FORMS

# Job'ları listele
aws $FLOCI $FAKE textract list-document-text-detection-jobs
```

---

## 59. Transcribe — Speech-to-Text

**What it does:** Converts speech to text (speech recognition). Used for support call records, meeting notes, and video subtitles. Supports multiple languages and custom vocabularies.

```bash
# Transcription job başlat
aws $FLOCI $FAKE transcribe start-transcription-job \
  --transcription-job-name test-job \
  --media '{"MediaFileUri":"s3://test-bucket/audio.mp3"}' \
  --media-format mp3 \
  --language-code tr-TR

# Job'ları listele
aws $FLOCI $FAKE transcribe list-transcription-jobs

# Job detayı
aws $FLOCI $FAKE transcribe get-transcription-job --transcription-job-name test-job

# Medical transcription
aws $FLOCI $FAKE transcribe start-medical-transcription-job \
  --medical-transcription-job-name test-med-job \
  --media '{"MediaFileUri":"s3://test-bucket/audio.mp3"}' \
  --language-code en-US
```

---

## 60. Pricing

**What it does:** Offers an API for querying AWS service prices. Learn a product's price, pricing model (on-demand, reserved, spot), and regional price differences.

```bash
# Servis listele
aws $FLOCI $FAKE pricing describe-services

# Service code ara
aws $FLOCI $FAKE pricing describe-services --service-code AmazonS3 --query Services[0].AttributeNames

# Product listele
aws $FLOCI $FAKE pricing get-products \
  --service-code AmazonS3 \
  --filters Type=TERM_MATCH,Field=productFamily,Value=Storage
```

---

## 61. Cost Explorer

**What it does:** Visualizes and analyzes AWS spend. Shows past spend, forecasts, and per-service breakdown. Offers savings plan recommendations.

```bash
# Cost ve usage sorgula
aws $FLOCI $FAKE ce get-cost-and-usage \
  --time-period Start="$(date +%Y-%m)-01",End="$(date +%Y-%m-%d)" \
  --granularity MONTHLY \
  --metrics BlendedCost

# Cost forecast
aws $FLOCI $FAKE ce get-cost-forecast \
  --time-period Start="$(date +%Y-%m-%d)",End="$(date -d '+30 days' +%Y-%m-%d)" \
  --granularity MONTHLY \
  --metric BlendedCost

# Dimension değerleri
aws $FLOCI $FAKE ce get-dimension-values --dimension SERVICE --time-period Start="2026-01-01",End="2026-12-31"
```

---

## 62. Cost and Usage Report (CUR)

**What it does:** Dumps detailed AWS usage and cost data to S3 in CSV/Parquet. Unlike Cost Explorer: process the raw data with your own analysis tools (Athena, QuickSight).

```bash
# Report definition oluştur
aws $FLOCI $FAKE cur put-report-definition \
  --report-definition '{"ReportName":"test-report","TimeUnit":"HOURLY","Format":"textORcsv","Compression":"GZIP","S3Bucket":"test-cur-bucket","S3Prefix":"cur","S3Region":"us-east-1","AdditionalSchemaElements":["RESOURCES"]}'

# Report definition'ları listele
aws $FLOCI $FAKE cur describe-report-definitions

# Report sil
aws $FLOCI $FAKE cur delete-report-definition --report-name test-report
```

---

## 63. BCM Data Exports

**What it does:** A more flexible, next-generation cost data export service, similar to CUR. Collects Cost Explorer, CUR, and billing data under a single API.

```bash
# Export oluştur
aws $FLOCI $FAKE bcm-data-exports create-export \
  --export '{"Name":"test-export","DataQuery":{"QueryStatement":"SELECT * FROM COST_AND_USAGE_DATAFILE"},"DestinationConfigurations":{"S3Destination":{"S3Bucket":"test-bucket","S3Prefix":"bcm-exports","S3Region":"us-east-1"}}}'

# Export'ları listele
aws $FLOCI $FAKE bcm-data-exports list-exports

# Export sil
aws $FLOCI $FAKE bcm-data-exports delete-export --export-arn arn:aws:bcm-data-exports:us-east-1:000000000000:export/test-export
```

---

## 64. IoT Core

**What it does:** Used to connect and manage IoT devices (sensors, smart devices) to AWS. Can manage millions of devices over MQTT; routes incoming data to other AWS services.

```bash
# Thing oluştur
aws $FLOCI $FAKE iot create-thing --thing-name test-device

# Thing'leri listele
aws $FLOCI $FAKE iot list-things

# Thing type oluştur
aws $FLOCI $FAKE iot create-thing-type --thing-type-name temperature-sensor

# Policy oluştur
aws $FLOCI $FAKE iot create-policy \
  --policy-name test-iot-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"iot:*","Resource":"*"}]}'

# Sertifika oluştur
aws $FLOCI $FAKE iot create-keys-and-certificate --set-as-active

# Thing sil
aws $FLOCI $FAKE iot delete-thing --thing-name test-device
```

---

## 65. IoT Data Plane

**What it does:** Used to read/update IoT device state (shadow) and send/receive messages. The data-plane API of IoT Core. Holds the last known state of devices.

```bash
# Shadow state güncelle
aws $FLOCI $FAKE iot-data update-thing-shadow \
  --thing-name test-device \
  --payload '{"state":{"reported":{"temperature":24}}}' \
  /tmp/shadow-out.json
cat /tmp/shadow-out.json

# Shadow state oku
aws $FLOCI $FAKE iot-data get-thing-shadow \
  --thing-name test-device \
  /tmp/shadow-get.json
cat /tmp/shadow-get.json

# Shadow sil
aws $FLOCI $FAKE iot-data delete-thing-shadow --thing-name test-device
```

---

## 66. S3 Vector Search (S3Vectors)

**What it does:** Indexes vector data (embeddings) in S3 with similarity search. Used as a vector database for RAG (Retrieval-Augmented Generation) and AI apps.

```bash
# Koleksiyon oluştur (Floci'de sınırlı)
aws $FLOCI $FAKE s3vectors create-collection \
  --name test-collection \
  --metadata-config '{"fields":[{"name":"text","dataType":"STRING"}]}'

# Koleksiyon sil
aws $FLOCI $FAKE s3vectors delete-collection --collection-arn arn:aws:s3vectors:us-east-1:000000000000:test-collection
```

---

## 67. Neptune — Graph DB

**What it does:** Graph database. Models data as nodes and edges. Ideal for relationship-dense data like social networks, fraud detection, and recommendation engines. Supports SPARQL and Gremlin.

```bash
# DB instance'ları listele
aws $FLOCI $FAKE neptune describe-db-instances

# DB cluster oluştur
aws $FLOCI $FAKE neptune create-db-cluster \
  --db-cluster-identifier test-neptune \
  --engine neptune \
  --master-username neptune \
  --master-user-password Neptune123!

# DB instance oluştur
aws $FLOCI $FAKE neptune create-db-instance \
  --db-instance-identifier test-neptune-instance \
  --db-cluster-identifier test-neptune \
  --db-instance-class db.r5.large

# DB cluster sil
aws $FLOCI $FAKE neptune delete-db-instance --db-instance-identifier test-neptune-instance --skip-final-snapshot
aws $FLOCI $FAKE neptune delete-db-cluster --db-cluster-identifier test-neptune --skip-final-snapshot
```

---

## 68. DocumentDB — MongoDB-compatible

**What it does:** MongoDB-compatible managed document database. Mimics the MongoDB 5.0/6.0 API; existing MongoDB apps move with minimal changes. Stores JSON documents.

```bash
# DB cluster oluştur
aws $FLOCI $FAKE docdb create-db-cluster \
  --db-cluster-identifier test-docdb \
  --engine docdb \
  --master-username docdb \
  --master-user-password DocDB123!

# DB instance'ları listele
aws $FLOCI $FAKE docdb describe-db-instances

# Cluster sil
aws $FLOCI $FAKE docdb delete-db-cluster --db-cluster-identifier test-docdb --skip-final-snapshot
```

---

## 65. Kafka (MSK) — tekrar #31

(See the MSK — Kafka section)

---

## 69. RDS Data API

**What it does:** Sends SQL queries over HTTP API to RDS PostgreSQL or Aurora Serverless. No connection pool management needed; ideal for running queries directly from Lambda.

```bash
# Execute SQL (PostgreSQL)
aws $FLOCI $FAKE rds-data execute-statement \
  --resource-arn arn:aws:rds:us-east-1:000000000000:cluster:test-pg \
  --secret-arn arn:aws:secretsmanager:us-east-1:000000000000:secret:test-secret \
  --database postgres \
  --sql "SELECT 1 as test"

# Transaction başlat
aws $FLOCI $FAKE rds-data begin-transaction \
  --resource-arn arn:aws:rds:us-east-1:000000000000:cluster:test-pg \
  --database postgres

# Batch execute
aws $FLOCI $FAKE rds-data batch-execute-statement \
  --resource-arn arn:aws:rds:us-east-1:000000000000:cluster:test-pg \
  --database postgres \
  --sql "SELECT generate_series(1,3)"
```

---

## 70. Scheduler (EventBridge Scheduler) — tekrar #20

(See the EventBridge Scheduler section)

---

## 71. Pipes — tekrar #21

(See the EventBridge Pipes section)

---

## 72. Logs — tekrar #17

(See the CloudWatch Logs section)

---

## 73. Monitoring — tekrar #18

(See the CloudWatch Metrics section)

---

## 74. STS — Security Token Service

**What it does:** Generates temporary, time-limited credentials. AssumeRole, federation tokens, and session tokens come through this service. The identity mechanism behind CLI and SDK sessions.

```bash
# Kimlik doğrula (en temel test — accountId ve Arn dönmeli)
aws $FLOCI $FAKE sts get-caller-identity

# Test için rol oluştur (ön koşul)
aws $FLOCI $FAKE iam create-role \
  --role-name test-sts-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Rol üstlen ve geçici credential al
aws $FLOCI $FAKE sts assume-role \
  --role-arn arn:aws:iam::000000000000:role/test-sts-role \
  --role-session-name test-session

# Kısa süreli oturum token'ı al
aws $FLOCI $FAKE sts get-session-token --duration-seconds 900

# Federasyon token'ı al
aws $FLOCI $FAKE sts get-federation-token --name test-federated --duration-seconds 900

# Web identity ile rol üstlen
aws $FLOCI $FAKE sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::000000000000:role/test-sts-role \
  --role-session-name web-session \
  --web-identity-token fake-token

# SAML assertion ile rol üstlen
aws $FLOCI $FAKE sts assume-role-with-saml \
  --role-arn arn:aws:iam::000000000000:role/test-sts-role \
  --principal-arn arn:aws:iam::000000000000:saml-provider/test-idp \
  --saml-assertion fake-assertion

# Erişim anahtarı bilgisi sorgula
aws $FLOCI $FAKE sts get-access-key-info --access-key-id AKIATESTKEY12345

# Rolü temizle
aws $FLOCI $FAKE iam delete-role --role-name test-sts-role
```

---

## 75. Organizations — Multi-Account Management

**What it does:** Manages multiple AWS accounts under one roof. Provides account hierarchy (OU), service control policies (SCP), and account creation automation.

```bash
# Organization kur
aws $FLOCI $FAKE organizations create-organization --feature-set ALL

# Organization detayını gör
aws $FLOCI $FAKE organizations describe-organization

# Kök (root) listele
aws $FLOCI $FAKE organizations list-roots

# Yeni hesap oluştur
aws $FLOCI $FAKE organizations create-account \
  --email test-account@example.com \
  --account-name test-account

# Hesapları listele
aws $FLOCI $FAKE organizations list-accounts

# Organizational unit (OU) oluştur
aws $FLOCI $FAKE organizations create-organizational-unit \
  --name test-ou \
  --parent-id r-fake-root-id

# OU altındaki hesapları listele
aws $FLOCI $FAKE organizations list-accounts-for-parent --parent-id r-fake-root-id

# OU hiyerarşisini listele
aws $FLOCI $FAKE organizations list-organizational-units-for-parent --parent-id r-fake-root-id

# SCP politikası oluştur
aws $FLOCI $FAKE organizations create-policy \
  --name test-scp \
  --type SERVICE_CONTROL_POLICY \
  --content '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'

# SCP listele
aws $FLOCI $FAKE organizations list-policies --filter SERVICE_CONTROL_POLICY

# SCP'yi bir hedefe bağla
aws $FLOCI $FAKE organizations attach-policy --policy-id p-fake --target-id ou-fake

# SCP'yi hedeften ayır ve sil
aws $FLOCI $FAKE organizations detach-policy --policy-id p-fake --target-id ou-fake
aws $FLOCI $FAKE organizations delete-policy --policy-id p-fake

# Hesabı Organization'dan çıkar (temizlik)
aws $FLOCI $FAKE organizations remove-account-from-organization --account-id 111122223333

# Organization'ı sil (temizlik — dikkatli)
aws $FLOCI $FAKE organizations delete-organization
```

---

## 76. MWAA — Managed Airflow

**What it does:** Provides a managed Apache Airflow environment. DAGs are read from S3; scheduled data pipelines are managed. Floci runs real Airflow (LocalExecutor) + a Postgres metadata container.

```bash
# DAG bucket'ı ve rolü hazırla (ön koşul)
aws $FLOCI $FAKE s3 mb s3://test-dags
aws $FLOCI $FAKE iam create-role --role-name mwaa-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"airflow.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Airflow ortamı oluştur
aws $FLOCI $FAKE mwaa create-environment \
  --name test-airflow \
  --airflow-version 2.10.3 \
  --source-bucket test-dags \
  --execution-role-arn arn:aws:iam::000000000000:role/mwaa-role \
  --network-configuration SecurityGroupIds=sg-fake,SubnetIds=subnet-fake

# Ortamları listele
aws $FLOCI $FAKE mwaa list-environments

# Ortam detayını gör (status, webserver URL)
aws $FLOCI $FAKE mwaa get-environment --name test-airflow

# Airflow CLI için token al
aws $FLOCI $FAKE mwaa create-cli-token --name test-airflow

# Web arayüzü için login token al
aws $FLOCI $FAKE mwaa create-web-login-token --name test-airflow

# Ortamı etiketle
aws $FLOCI $FAKE mwaa tag-resource \
  --resource-arn arn:aws:airflow:us-east-1:000000000000:environment/test-airflow \
  --tags Key=env,Value=test

# Etiketleri listele
aws $FLOCI $FAKE mwaa list-tags-for-resource \
  --resource-arn arn:aws:airflow:us-east-1:000000000000:environment/test-airflow

# Ortamı güncelle
aws $FLOCI $FAKE mwaa update-environment --name test-airflow --airflow-configuration-options core.dag_file_processor_timeout=60

# Ortamı sil
aws $FLOCI $FAKE mwaa delete-environment --name test-airflow

# Temizlik
aws $FLOCI $FAKE iam delete-role --role-name mwaa-role
aws $FLOCI $FAKE s3 rb s3://test-dags
```

---

## 77. Apache Flink (Kinesis Analytics V2)

**What it does:** Provides a managed Apache Flink environment for real-time stream processing. In Floci, StartApplication launches a real Flink cluster (JobManager + TaskManager) and pulls the JAR from S3.

```bash
# Uygulama oluştur
aws $FLOCI $FAKE kinesisanalyticsv2 create-application \
  --application-name test-flink \
  --runtime-environment FLINK-1_20 \
  --service-execution-role arn:aws:iam::000000000000:role/flink-role

# Uygulamaları listele
aws $FLOCI $FAKE kinesisanalyticsv2 list-applications

# Uygulama detayını gör
aws $FLOCI $FAKE kinesisanalyticsv2 describe-application --application-name test-flink

# Uygulamayı başlat (Floci'de gerçek Flink cluster'ı başlar)
aws $FLOCI $FAKE kinesisanalyticsv2 start-application --application-name test-flink

# Durumu kontrol et (RUNNING olmalı)
aws $FLOCI $FAKE kinesisanalyticsv2 describe-application --application-name test-flink \
  --query ApplicationDetail.ApplicationStatus

# Uygulamayı durdur
aws $FLOCI $FAKE kinesisanalyticsv2 stop-application --application-name test-flink

# Uygulamayı sil
aws $FLOCI $FAKE kinesisanalyticsv2 delete-application --application-name test-flink
```

---

## 78. Redshift — Data Warehouse

**What it does:** Managed PostgreSQL-based data warehouse. Used for SQL analytics over large datasets and BI reporting.

```bash
# Cluster oluştur
aws $FLOCI $FAKE redshift create-cluster \
  --cluster-identifier test-redshift \
  --master-username admin \
  --master-user-password Redshift123 \
  --node-type ra3.xlplus \
  --number-of-nodes 1

# Cluster'ları listele
aws $FLOCI $FAKE redshift describe-clusters

# Cluster'ı duraklat
aws $FLOCI $FAKE redshift pause-cluster --cluster-identifier test-redshift

# Cluster'ı devam ettir
aws $FLOCI $FAKE redshift resume-cluster --cluster-identifier test-redshift

# Snapshot al
aws $FLOCI $FAKE redshift create-cluster-snapshot \
  --cluster-identifier test-redshift \
  --snapshot-identifier test-snap

# Snapshot'ları listele
aws $FLOCI $FAKE redshift describe-cluster-snapshots

# Snapshot'ı geri yükle
aws $FLOCI $FAKE redshift restore-from-cluster-snapshot \
  --cluster-identifier test-restored \
  --snapshot-identifier test-snap

# Cluster'ı sil (final snapshot atla)
aws $FLOCI $FAKE redshift delete-cluster \
  --cluster-identifier test-restored \
  --skip-final-cluster-snapshot
```

---

## 79. Redshift Data API

**What it does:** Sends SQL queries to a Redshift cluster over HTTPS. No persistent connection needed; ideal for running queries from Lambda.

```bash
# SQL çalıştır
aws $FLOCI $FAKE redshift-data execute-statement \
  --cluster-identifier test-redshift \
  --database dev \
  --sql "SELECT 1 AS test"

# Sorgu durumunu kontrol et (--id'yi önceki komutun cevabından al)
aws $FLOCI $FAKE redshift-data describe-statement --id stmt-1

# Sorgu sonucunu çek
aws $FLOCI $FAKE redshift-data get-statement-result --id stmt-1

# Sorgu geçmişini listele
aws $FLOCI $FAKE redshift-data list-statements

# Birden fazla SQL'i tek transaction içinde çalıştır
aws $FLOCI $FAKE redshift-data batch-execute-statement \
  --cluster-identifier test-redshift \
  --database dev \
  --sqls '["CREATE TABLE test(a INT)","INSERT INTO test VALUES(1)"]'

# Çalışan sorguyu iptal et
aws $FLOCI $FAKE redshift-data cancel-statement --id stmt-1
```

---

## 80. Redshift Serverless

**What it does:** Redshift that scales with usage and needs no node management. Uses namespace and workgroup concepts instead of cluster definitions.

```bash
# Namespace oluştur
aws $FLOCI $FAKE redshift-serverless create-namespace \
  --namespace-name test-ns \
  --admin-username admin \
  --admin-user-password Redshift123

# Namespace'leri listele
aws $FLOCI $FAKE redshift-serverless list-namespaces

# Workgroup oluştur
aws $FLOCI $FAKE redshift-serverless create-workgroup \
  --workgroup-name test-wg \
  --namespace-name test-ns \
  --base-capacity 8

# Workgroup'ları listele
aws $FLOCI $FAKE redshift-serverless list-workgroups

# Workgroup detayını gör
aws $FLOCI $FAKE redshift-serverless get-workgroup --workgroup-name test-wg

# Workgroup'u sil
aws $FLOCI $FAKE redshift-serverless delete-workgroup --workgroup-name test-wg

# Namespace'i sil
aws $FLOCI $FAKE redshift-serverless delete-namespace --namespace-name test-ns
```

---

## 81. DMS — Database Migration Service

**What it does:** Migrates databases (schema + data). Source and target endpoints are defined; a replication instance bridges them.

```bash
# Replikasyon instance'ı oluştur
aws $FLOCI $FAKE dms create-replication-instance \
  --replication-instance-identifier test-dms \
  --replication-instance-class dms.t3.micro

# Instance'ı listele
aws $FLOCI $FAKE dms describe-replication-instances

# Kaynak endpoint (postgres)
aws $FLOCI $FAKE dms create-endpoint \
  --endpoint-identifier test-source \
  --endpoint-type source \
  --engine-name postgres \
  --server-name 164.102.98.200 \
  --port 5432 \
  --username test \
  --password Test123

# Hedef endpoint (mysql)
aws $FLOCI $FAKE dms create-endpoint \
  --endpoint-identifier test-target \
  --endpoint-type target \
  --engine-name mysql \
  --server-name 164.102.98.201 \
  --port 3306 \
  --username test \
  --password Test123

# Endpoint'leri listele
aws $FLOCI $FAKE dms describe-endpoints

# Replikasyon görevi oluştur
aws $FLOCI $FAKE dms create-replication-task \
  --replication-task-identifier test-task \
  --source-endpoint-arn arn:aws:dms:us-east-1:000000000000:endpoint:test-source \
  --target-endpoint-arn arn:aws:dms:us-east-1:000000000000:endpoint:test-target \
  --replication-instance-arn arn:aws:dms:us-east-1:000000000000:rep:test-dms \
  --migration-type full-load \
  --table-mappings '{"rules":[{"rule-type":"selection","rule-id":"1","rule-name":"include-all","object-locator":{"schema-name":"%","table-name":"%"},"rule-action":"include"}]}'

# Görevleri listele
aws $FLOCI $FAKE dms describe-replication-tasks

# Görevi başlat
aws $FLOCI $FAKE dms start-replication-task \
  --replication-task-arn arn:aws:dms:us-east-1:000000000000:task:test-task \
  --start-replication-task-type start-replication

# Görevi durdur
aws $FLOCI $FAKE dms stop-replication-task \
  --replication-task-arn arn:aws:dms:us-east-1:000000000000:task:test-task

# Temizlik: görev → endpoint → instance sırasıyla
aws $FLOCI $FAKE dms delete-replication-task --replication-task-arn arn:aws:dms:us-east-1:000000000000:task:test-task
aws $FLOCI $FAKE dms delete-endpoint --endpoint-arn arn:aws:dms:us-east-1:000000000000:endpoint:test-source
aws $FLOCI $FAKE dms delete-endpoint --endpoint-arn arn:aws:dms:us-east-1:000000000000:endpoint:test-target
aws $FLOCI $FAKE dms delete-replication-instance --replication-instance-arn arn:aws:dms:us-east-1:000000000000:rep:test-dms
```

---

## 82. Timestream for InfluxDB

**What it does:** Provides managed InfluxDB 2.x instances. Used for time-series (IoT sensor, metric) data. Floci runs a real `influxdb:2.7` container; the initial password goes to Secrets Manager.

```bash
# InfluxDB instance'ı oluştur
aws $FLOCI $FAKE timestream-influxdb create-db-instance \
  --name test-influx \
  --allocated-storage 20 \
  --db-instance-type db.influx.medium \
  --username admin \
  --password Influx123 \
  --organization test-org \
  --bucket test-bucket

# Instance'ları listele
aws $FLOCI $FAKE timestream-influxdb list-db-instances

# Instance detayını gör (id'yi önceki cevaptan al)
aws $FLOCI $FAKE timestream-influxdb get-db-instance --identifier db-influx-1

# Depolamayı büyüt
aws $FLOCI $FAKE timestream-influxdb update-db-instance \
  --identifier db-influx-1 \
  --allocated-storage 40

# İlk şifre Secrets Manager'da aranır (Floci davranışı)
aws $FLOCI $FAKE secretsmanager list-secrets --query SecretList[].Name --output text

# Instance'ı sil
aws $FLOCI $FAKE timestream-influxdb delete-db-instance --identifier db-influx-1
```

---

## 83. EFS — Elastic File System

**What it does:** NFS-based shared file system for EC2 and containers. Multiple instances can attach to the same file system at once.

```bash
# Dosya sistemi oluştur
aws $FLOCI $FAKE efs create-file-system --creation-token test-fs

# Dosya sistemlerini listele (FileSystemId'yi al)
aws $FLOCI $FAKE efs describe-file-systems

# Mount target oluştur
aws $FLOCI $FAKE efs create-mount-target \
  --file-system-id fs-fake \
  --subnet-id subnet-fake

# Mount target'ları listele
aws $FLOCI $FAKE efs describe-mount-targets --file-system-id fs-fake

# Access point oluştur (konteyner erişimi için)
aws $FLOCI $FAKE efs create-access-point --file-system-id fs-fake

# Access point'leri listele
aws $FLOCI $FAKE efs describe-access-points

# Koruma ayarını güncelle (Floci'nin uyguladığı op)
aws $FLOCI $FAKE efs update-file-system-protection --file-system-id fs-fake --status ENABLED

# Etiketle
aws $FLOCI $FAKE efs tag-resource --resource-id fs-fake --tags Key=env,Value=test

# Temizlik: access point → mount target → dosya sistemi sırasıyla
aws $FLOCI $FAKE efs delete-access-point --access-point-id fsap-fake
aws $FLOCI $FAKE efs delete-mount-target --mount-target-id fsmt-fake
aws $FLOCI $FAKE efs delete-file-system --file-system-id fs-fake
```

---

## 84. DataSync

**What it does:** Large-scale data transfer between locations like S3, NFS, and EFS. Defines scheduled, verified copy tasks.

```bash
# S3 kaynak konumu oluştur
aws $FLOCI $FAKE datasync create-location-s3 \
  --s3-bucket-arn arn:aws:s3:::test-datasync \
  --subdirectory /data

# Konumları listele (LocationArn'yi al)
aws $FLOCI $FAKE datasync list-locations

# Transfer görevi oluştur
aws $FLOCI $FAKE datasync create-task \
  --source-location-arn arn:aws:datasync:us-east-1:000000000000:location/loc-fake-1 \
  --destination-location-arn arn:aws:datasync:us-east-1:000000000000:location/loc-fake-2 \
  --name test-task

# Görevleri listele
aws $FLOCI $FAKE datasync list-tasks

# Görevi çalıştır
aws $FLOCI $FAKE datasync start-task-execution --task-arn arn:aws:datasync:us-east-1:000000000000:task/task-fake

# Çalışan görevi gör
aws $FLOCI $FAKE datasync describe-task-execution --execution-arn arn:aws:datasync:us-east-1:000000000000:execution/exec-fake

# Temizlik
aws $FLOCI $FAKE datasync delete-task --task-arn arn:aws:datasync:us-east-1:000000000000:task/task-fake
aws $FLOCI $FAKE datasync delete-location --location-arn arn:aws:datasync:us-east-1:000000000000:location/loc-fake-1
aws $FLOCI $FAKE datasync delete-location --location-arn arn:aws:datasync:us-east-1:000000000000:location/loc-fake-2
```

---

## 85. EMR Serverless

**What it does:** Runs Spark/Hive jobs without cluster management. Create an application, submit a job run; capacity is managed automatically.

```bash
# Spark uygulaması oluştur
aws $FLOCI $FAKE emr-serverless create-application \
  --name test-spark \
  --release-label emr-7.1.0 \
  --type SPARK

# Uygulamaları listele (applicationId'yi al)
aws $FLOCI $FAKE emr-serverless list-applications

# Uygulama detayını gör
aws $FLOCI $FAKE emr-serverless get-application --application-id app-1234567890

# Job çalıştır (jar/script S3'te)
aws $FLOCI $FAKE emr-serverless start-job-run \
  --application-id app-1234567890 \
  --execution-role-arn arn:aws:iam::000000000000:role/emr-role \
  --job-driver '{"SparkSubmit":{"EntryPoint":"s3://test-bucket/job.py"}}'

# Job'ları listele
aws $FLOCI $FAKE emr-serverless list-job-runs --application-id app-1234567890

# Job'u iptal et
aws $FLOCI $FAKE emr-serverless cancel-job-run \
  --application-id app-1234567890 \
  --job-run-id jobrun-1

# Uygulamayı durdur
aws $FLOCI $FAKE emr-serverless stop-application --application-id app-1234567890

# Uygulamayı sil
aws $FLOCI $FAKE emr-serverless delete-application --application-id app-1234567890
```

---

## 86. S3 Tables — Iceberg

**What it does:** Apache Iceberg table format over S3. Holds ACID-compliant analytics tables (data lakehouse) in object storage.

```bash
# Table bucket oluştur
aws $FLOCI $FAKE s3tables create-table-bucket --name test-table-bucket

# Bucket'ları listele (tableBucketArn'yi al)
aws $FLOCI $FAKE s3tables list-table-buckets

# Namespace oluştur
aws $FLOCI $FAKE s3tables create-namespace \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket \
  --namespace test-ns

# Namespace'leri listele
aws $FLOCI $FAKE s3tables list-namespaces \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket

# Iceberg tablosu oluştur (metadata dosyasında şema tanımı olmalı)
aws $FLOCI $FAKE s3tables create-table \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket \
  --namespace test-ns \
  --name test-table \
  --format ICEBERG \
  --metadata file://iceberg-table.json

# Tabloları listele
aws $FLOCI $FAKE s3tables list-tables \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket \
  --namespace test-ns

# Tablo detayını gör
aws $FLOCI $FAKE s3tables get-table \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket \
  --namespace test-ns \
  --name test-table

# Temizlik: tablo → namespace → bucket sırasıyla
aws $FLOCI $FAKE s3tables delete-table \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket \
  --namespace test-ns --name test-table
aws $FLOCI $FAKE s3tables delete-namespace \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket \
  --namespace test-ns
aws $FLOCI $FAKE s3tables delete-table-bucket \
  --table-bucket-arn arn:aws:s3tables:us-east-1:000000000000:bucket/test-table-bucket
```

---

## 87. Lake Formation

**What it does:** Central permission management over a data lake. S3 and Glue resources are registered; principal-based table/database access grants are given.

```bash
# Bucket'ı data lake'e kaydet
aws $FLOCI $FAKE lakeformation register-resource \
  --resource-arn arn:aws:s3:::test-lf-bucket

# Kayıtlı kaynakları listele
aws $FLOCI $FAKE lakeformation list-resources

# Data lake ayarlarını gör
aws $FLOCI $FAKE lakeformation get-data-lake-settings

# Rol için ALL izni ver
aws $FLOCI $FAKE lakeformation grant-permissions \
  --principal DataLakePrincipalIdentifier=arn:aws:iam::000000000000:role/test-role \
  --permissions ALL \
  --resource '{"DatabaseName":"test-db"}'

# İzinleri listele
aws $FLOCI $FAKE lakeformation list-permissions

# İzni geri al
aws $FLOCI $FAKE lakeformation revoke-permissions \
  --principal DataLakePrincipalIdentifier=arn:aws:iam::000000000000:role/test-role \
  --permissions ALL \
  --resource '{"DatabaseName":"test-db"}'

# Kaynağı data lake'den çıkar (temizlik)
aws $FLOCI $FAKE lakeformation deregister-resource \
  --resource-arn arn:aws:s3:::test-lf-bucket
```

---

## 88. Global Accelerator

**What it does:** Managed acceleration service routing traffic to the nearest edge location over the AWS global network. Provides static anycast IPs.

```bash
# Accelerator oluştur
aws $FLOCI $FAKE globalaccelerator create-accelerator --name test-accelerator

# Accelerator'ları listele (AcceleratorArn'yi al)
aws $FLOCI $FAKE globalaccelerator list-accelerators

# Accelerator detayını gör
aws $FLOCI $FAKE globalaccelerator describe-accelerator --accelerator-arn arn:aws:globalaccelerator::000000000000:accelerator/acc-fake

# Listener ekle (80/TCP)
aws $FLOCI $FAKE globalaccelerator create-listener \
  --accelerator-arn arn:aws:globalaccelerator::000000000000:accelerator/acc-fake \
  --port-ranges FromPort=80,ToPort=80 \
  --protocol TCP

# Listener'ları listele (ListenerArn'yi al)
aws $FLOCI $FAKE globalaccelerator describe-listeners \
  --accelerator-arn arn:aws:globalaccelerator::000000000000:accelerator/acc-fake

# Endpoint group ekle
aws $FLOCI $FAKE globalaccelerator create-endpoint-group \
  --listener-arn arn:aws:globalaccelerator::000000000000:listener/lsr-fake \
  --endpoint-group-region us-east-1 \
  --endpoint-configurations EndpointId=i-fake,Weight=128

# Endpoint group'ları listele
aws $FLOCI $FAKE globalaccelerator describe-endpoint-groups \
  --listener-arn arn:aws:globalaccelerator::000000000000:listener/lsr-fake

# Temizlik: endpoint group → listener → accelerator sırasıyla
aws $FLOCI $FAKE globalaccelerator delete-endpoint-group --endpoint-group-arn arn:aws:globalaccelerator::000000000000:endpoint-group/egw-fake
aws $FLOCI $FAKE globalaccelerator delete-listener --listener-arn arn:aws:globalaccelerator::000000000000:listener/lsr-fake
aws $FLOCI $FAKE globalaccelerator delete-accelerator --accelerator-arn arn:aws:globalaccelerator::000000000000:accelerator/acc-fake
```

---

## 89. Verified Permissions — Cedar

**What it does:** Stores authorization policies written in Cedar and makes in-app access decisions via `IsAuthorized` queries. Runs with a real Cedar 4 sidecar in Floci.

```bash
# Policy store oluştur
aws $FLOCI $FAKE verifiedpermissions create-policy-store

# Store'ları listele (policyStoreId'yi al)
aws $FLOCI $FAKE verifiedpermissions list-policy-stores

# Store detayını gör
aws $FLOCI $FAKE verifiedpermissions get-policy-store --policy-store-id ps-1112223334

# Şema tanımla (Cedar şeması dosyada: {"CedarJson": "..."} yapısında)
aws $FLOCI $FAKE verifiedpermissions create-schema \
  --policy-store-id ps-1112223334 \
  --definition file://cedar-schema.json

# Şemayı görüntüle
aws $FLOCI $FAKE verifiedpermissions get-schema --policy-store-id ps-1112223334

# Statik Cedar politikası ekle
aws $FLOCI $FAKE verifiedpermissions create-policy \
  --policy-store-id ps-1112223334 \
  --definition '{"Static":{"statement":"permit(principal == User::\"alice\", action == Action::\"view\", resource == Photo::\"photo-1\")"}}'

# Politikaları listele
aws $FLOCI $FAKE verifiedpermissions list-policies --policy-store-id ps-1112223334

# Yetkilendirme kararı al (Cedar sidecar gerçek karar verir)
aws $FLOCI $FAKE verifiedpermissions is-authorized \
  --policy-store-id ps-1112223334 \
  --principal '{"EntityType":"User","EntityId":"alice"}' \
  --action '{"EntityType":"Action","EntityId":"view"}' \
  --resource '{"EntityType":"Photo","EntityId":"photo-1"}'

# Temizlik: politika → store sırasıyla
aws $FLOCI $FAKE verifiedpermissions delete-policy --policy-store-id ps-1112223334 --policy-id policy-fake-1
aws $FLOCI $FAKE verifiedpermissions delete-policy-store --policy-store-id ps-1112223334
```

---

## 90. SWF — Simple Workflow

**What it does:** Orchestrates distributed app steps (decision/activity tasks). Manages timeouts, retries, and child workflows in long-running flows. In Floci, tasks can call real Lambdas.

```bash
# Domain kaydet
aws $FLOCI $FAKE swf register-domain \
  --name test-domain \
  --workflow-execution-retention-period-in-days 1

# Domain'leri listele
aws $FLOCI $FAKE swf list-domains --registration-status REGISTERED

# Domain detayını gör
aws $FLOCI $FAKE swf describe-domain --name test-domain

# Workflow tipi kaydet
aws $FLOCI $FAKE swf register-workflow-type \
  --domain test-domain \
  --name test-workflow \
  --version 1

# Activity tipi kaydet
aws $FLOCI $FAKE swf register-activity-type \
  --domain test-domain \
  --name test-activity \
  --version 1

# Workflow çalıştır
aws $FLOCI $FAKE swf start-workflow-execution \
  --domain test-domain \
  --workflow-id test-exec-1 \
  --workflow-type-name test-workflow \
  --workflow-type-version 1

# Workflow tipini deprecate et (temizlik)
aws $FLOCI $FAKE swf deprecate-workflow-type --domain test-domain --workflow-type-name test-workflow --workflow-type-version 1

# Domain'i deprecate et (temizlik)
aws $FLOCI $FAKE swf deprecate-domain --name test-domain
```

---

## 91. CloudWatch OAM — Observability Access Manager

**What it does:** Shares monitoring resources (metrics, logs) across accounts. Central observability is built on the sink-and-link model.

```bash
# Sink oluştur (kaynağı toplayan taraf)
aws $FLOCI $FAKE oam create-sink --name test-sink

# Sink'leri listele (sinkId'yi al)
aws $FLOCI $FAKE oam list-sinks

# Link oluştur (kaynak gönderen taraf)
aws $FLOCI $FAKE oam create-link \
  --sink-identifier sink-1 \
  --label-template '$ACCOUNT_ID'

# Link'leri listele (linkId'yi al)
aws $FLOCI $FAKE oam list-links

# Link detayını gör
aws $FLOCI $FAKE oam get-link --link-identifier link-1 --sink-identifier sink-1

# Sink'e etiket ekle
aws $FLOCI $FAKE oam tag-resource --resource-arn arn:aws:oam:us-east-1:000000000000:sink/sink-1 --tags Key=env,Value=test

# Temizlik: link → sink sırasıyla
aws $FLOCI $FAKE oam delete-link --link-identifier link-1 --sink-identifier sink-1
aws $FLOCI $FAKE oam delete-sink --identifier sink-1
```

---

## 92. CloudWatch RUM — Real User Monitoring

**What it does:** Collects real-user performance of a web app (page loads, JS errors) from the browser.

```bash
# App monitor oluştur
aws $FLOCI $FAKE rum create-app-monitor --name test-rum --domain example.com

# App monitor'ları listele
aws $FLOCI $FAKE rum list-app-monitors

# App monitor detayını gör
aws $FLOCI $FAKE rum get-app-monitor --name test-rum

# App monitor'u sil
aws $FLOCI $FAKE rum delete-app-monitor --name test-rum
```

---

## 93. Managed Prometheus (AMP)

**What it does:** Managed Prometheus workspace. Includes long-term metric retention and Alertmanager definitions.

```bash
# Workspace oluştur
aws $FLOCI $FAKE amp create-workspace --alias test-amp

# Workspace'leri listele (workspaceId'yi al)
aws $FLOCI $FAKE amp list-workspaces

# Workspace detayını gör
aws $FLOCI $FAKE amp describe-workspace --workspace-id ws-1a2b3c4d5

# Alertmanager tanımı yükle (yaml dosyasında)
aws $FLOCI $FAKE amp create-alert-manager-definition \
  --workspace-id ws-1a2b3c4d5 \
  --data file://alertmanager.yaml

# Alertmanager tanımını gör
aws $FLOCI $FAKE amp describe-alert-manager-definition --workspace-id ws-1a2b3c4d5

# Workspace'i sil
aws $FLOCI $FAKE amp delete-workspace --workspace-id ws-1a2b3c4d5
```

---

## 94. Cognito Identity — Identity Pools

**What it does:** Gives temporary AWS credentials to authenticated or guest (unauthenticated) users. (Unlike the user pools in section #25: identity pools distribute credentials.)

```bash
# Identity pool oluştur
aws $FLOCI $FAKE cognito-identity create-identity-pool \
  --identity-pool-name test-idpool \
  --allow-unauthenticated-identities

# Pool'ları listele (IdentityPoolId'yi al)
aws $FLOCI $FAKE cognito-identity list-identity-pools --max-results 10

# Pool detayını gör
aws $FLOCI $FAKE cognito-identity describe-identity-pool --identity-pool-id us-east-1:POOLFAKE123

# Misafir kullanıcı için identity al
aws $FLOCI $FAKE cognito-identity get-id \
  --identity-pool-id us-east-1:POOLFAKE123 \
  --account-id 000000000000

# Identity için geçici credential al (IdentityId'yi önceki cevaptan al)
aws $FLOCI $FAKE cognito-identity get-credentials-for-identity --identity-id us-east-1:IDENTFAKE1

# Pool'u sil
aws $FLOCI $FAKE cognito-identity delete-identity-pool --identity-pool-id us-east-1:POOLFAKE123
```

---

## 95. Route 53 Resolver

**What it does:** Provides resolver endpoints and rules routing external DNS queries from inside the VCD (FORWARD) or internal queries from outside the VPC (INBOUND).

```bash
# Inbound endpoint oluştur
aws $FLOCI $FAKE route53resolver create-resolver-endpoint \
  --creator-request-id test-req \
  --direction INBOUND \
  --security-group-ids sg-fake \
  --ip-addresses Ip=164.102.98.200,SubnetId=subnet-fake

# Endpoint'leri listele (ResolverEndpointId'yi al)
aws $FLOCI $FAKE route53resolver list-resolver-endpoints

# Forward kuralı oluştur (8.8.8.8'e yönlendir)
aws $FLOCI $FAKE route53resolver create-resolver-rule \
  --rule-type FORWARD \
  --domain-name example.com \
  --resolver-endpoint-id rslvr-in-1 \
  --target-ips Ip=8.8.8.8,Port=53

# Kuralları listele (ResolverRuleId'yi al)
aws $FLOCI $FAKE route53resolver list-resolver-rules

# Kuralı bir VPC'ye bağla
aws $FLOCI $FAKE route53resolver associate-resolver-rule \
  --resolver-rule-id rslrr-fwd-1 \
  --vpc-id vpc-fake

# Bağlantıları listele
aws $FLOCI $FAKE route53resolver list-resolver-rule-associations

# Temizlik: bağlantı → kural → endpoint sırasıyla
aws $FLOCI $FAKE route53resolver disassociate-resolver-rule --resolver-rule-id rslrr-fwd-1 --vpc-id vpc-fake
aws $FLOCI $FAKE route53resolver delete-resolver-rule --resolver-rule-id rslrr-fwd-1
aws $FLOCI $FAKE route53resolver delete-resolver-endpoint --resolver-endpoint-id rslvr-in-1
```

---

## 96. ELB Classic

**What it does:** Classic (generation 1) load balancer. Predecessor of modern ALB/NLB (section #34); tested for compatibility with existing legacy setups.

```bash
# Classic load balancer oluştur
aws $FLOCI $FAKE elb create-load-balancer \
  --load-balancer-name test-elb \
  --listeners Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80 \
  --availability-zones us-east-1a

# Load balancer'ları listele
aws $FLOCI $FAKE elb describe-load-balancers

# Health check yapılandır
aws $FLOCI $FAKE elb configure-health-check \
  --load-balancer-name test-elb \
  --health-check Target=HTTP:80/ping,Interval=30,Timeout=5,HealthyThreshold=2,UnhealthyThreshold=2

# Load balancer'ı sil
aws $FLOCI $FAKE elb delete-load-balancer --load-balancer-name test-elb
```

---

## 97. Application Auto Scaling

**What it does:** Auto-scales capacity of resources like DynamoDB, ECS, and SageMaker. (Unlike EC2 Auto Scaling in section #35.)

```bash
# Ölçeklenebilir hedef kaydet (DynamoDB table'ı için)
aws $FLOCI $FAKE application-autoscaling register-scalable-target \
  --service-namespace dynamodb \
  --resource-id table/test-table \
  --scalable-dimension dynamodb:table:ReadCapacityUnits \
  --min-capacity 1 \
  --max-capacity 10

# Hedefleri listele
aws $FLOCI $FAKE application-autoscaling describe-scalable-targets \
  --service-namespace dynamodb \
  --resource-ids table/test-table

# Target tracking politikası ekle
aws $FLOCI $FAKE application-autoscaling put-scaling-policy \
  --service-namespace dynamodb \
  --resource-id table/test-table \
  --scalable-dimension dynamodb:table:ReadCapacityUnits \
  --policy-name test-tt \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-configuration '{"TargetValue":50,"PredefinedMetricSpecification":{"PredefinedMetricType":"DynamoDBReadCapacityUtilization"}}'

# Politikaları listele
aws $FLOCI $FAKE application-autoscaling describe-scaling-policies \
  --service-namespace dynamodb \
  --resource-id table/test-table

# Hedefi kayıttan çıkar (temizlik)
aws $FLOCI $FAKE application-autoscaling deregister-scalable-target \
  --service-namespace dynamodb \
  --resource-id table/test-table \
  --scalable-dimension dynamodb:table:ReadCapacityUnits
```

---

## 98. CodeArtifact

**What it does:** Provides private package repos (npm, pip, maven). For package proxying and internal artifact management.

```bash
# Domain oluştur
aws $FLOCI $FAKE codeartifact create-domain --domain test-domain

# Domain'leri listele
aws $FLOCI $FAKE codeartifact list-domains

# Repository oluştur
aws $FLOCI $FAKE codeartifact create-repository --domain test-domain --repository test-repo

# Repository'leri listele
aws $FLOCI $FAKE codeartifact list-repositories

# Repository detayını gör
aws $FLOCI $FAKE codeartifact describe-repository --domain test-domain --repository test-repo

# Domain detayını gör
aws $FLOCI $FAKE codeartifact describe-domain --domain test-domain

# Temizlik: repository → domain sırasıyla
aws $FLOCI $FAKE codeartifact delete-repository --domain test-domain --repository test-repo
aws $FLOCI $FAKE codeartifact delete-domain --domain test-domain
```

---

## 99. CodeGuru Reviewer

**What it does:** Automatically reviews code quality and security issues. Attach a repository, run a code review.

```bash
# Repository'yi ilişkilendir
aws $FLOCI $FAKE codeguru-reviewer associate-repository \
  --repository '{"CodeCommit":{"Name":"test-repo"}}'

# İlişkileri listele (AssociationArn'yi al)
aws $FLOCI $FAKE codeguru-reviewer list-repository-associations

# İlişki detayını gör
aws $FLOCI $FAKE codeguru-reviewer describe-repository-association --association-arn arn:aws:codeguru-reviewer:us-east-1:000000000000:association:assoc-1

# Code review başlat
aws $FLOCI $FAKE codeguru-reviewer create-code-review \
  --repository-association-arn arn:aws:codeguru-reviewer:us-east-1:000000000000:association:assoc-1 \
  --type RepositoryAnalysis

# İlişkiyi kaldır (temizlik)
aws $FLOCI $FAKE codeguru-reviewer disassociate-repository --association-arn arn:aws:codeguru-reviewer:us-east-1:000000000000:association:assoc-1
```

---

## 100. Comprehend — Metin Analizi

**What it does:** Sentiment analysis, entity detection, and key-phrase extraction in text.

```bash
# Not: Floci'de mock/sabit yanıt döner

# Duygu analizi
aws $FLOCI $FAKE comprehend detect-sentiment \
  --language-code en \
  --text "Floci is a great local emulator"

# Varlık tespiti
aws $FLOCI $FAKE comprehend detect-entities \
  --language-code en \
  --text "Huseyin lives in Istanbul and works at Namecheap"

# Anahtar cümle tespiti
aws $FLOCI $FAKE comprehend detect-key-phrases \
  --language-code en \
  --text "AWS emulation for local development and testing"

# Sözdizimi (syntax) analizi
aws $FLOCI $FAKE comprehend detect-syntax \
  --language-code en \
  --text "This is a syntax test sentence"
```

---

## 101. Rekognition — Image Analysis

**What it does:** Object/label detection, face indexing, and search in images.

```bash
# Not: Floci'de mock/sabit yanıt döner

# Face collection oluştur
aws $FLOCI $FAKE rekognition create-collection --collection-id test-collection

# Collection'ları listele
aws $FLOCI $FAKE rekognition list-collections

# Görüntüde label tespiti (test.jpg önce bucket'a yüklenmeli)
aws $FLOCI $FAKE rekognition detect-labels \
  --image '{"S3Object":{"Bucket":"test-bucket","Name":"test.jpg"}}'

# Yüz indeksle
aws $FLOCI $FAKE rekognition index-faces \
  --collection-id test-collection \
  --image '{"S3Object":{"Bucket":"test-bucket","Name":"face.jpg"}}'

# Collection'ı sil
aws $FLOCI $FAKE rekognition delete-collection --collection-id test-collection
```

---

## 102. Translate — Machine Translation

**What it does:** Automatically translates text between languages.

```bash
# Not: Floci'de mock/sabit yanıt döner

# Metin çevir
aws $FLOCI $FAKE translate translate-text \
  --text "merhaba dünya" \
  --source-language-code tr \
  --target-language-code en

# Desteklenen dilleri listele
aws $FLOCI $FAKE translate list-languages

# Terminoloji listelerini görüntüle
aws $FLOCI $FAKE translate list-terminologies
```

---

## 103. Bedrock — Control Plane (Guardrail)

**What it does:** The management side of Bedrock: guardrail (content filter) lifecycle, versions, and tags. (The runtime side is in section #57.)

```bash
# Foundation model'leri listele
aws $FLOCI $FAKE bedrock list-foundation-models

# Guardrail oluştur
aws $FLOCI $FAKE bedrock create-guardrail \
  --name test-guardrail \
  --blocked-input-messaging "giris engellendi" \
  --blocked-outputs-messaging "cikis engellendi" \
  --content-policy-config '{"filtersConfig":[{"type":"MISCONDUCT","inputStrength":"HIGH","outputsStrength":"HIGH"}]}' \
  --word-policy-config '{"wordsConfig":[{"text":"yasak-kelime"}]}' \
  --sensitive-information-policy-config '{"piiEntitiesConfig":[]}' \
  --contextual-grounding-policy-config '{"filtersConfig":[]}'

# Guardrail'leri listele (guardrailId'yi al)
aws $FLOCI $FAKE bedrock list-guardrails

# Guardrail detayını gör
aws $FLOCI $FAKE bedrock get-guardrail --guardrail-identifier gr-1a2b3c4d

# Guardrail sürümü oluştur
aws $FLOCI $FAKE bedrock create-guardrail-version --guardrail-identifier gr-1a2b3c4d

# Guardrail'i sil
aws $FLOCI $FAKE bedrock delete-guardrail --guardrail-identifier gr-1a2b3c4d
```

---

## 104. Bedrock AgentCore

**What it does:** Management layer for AI agent runtimes: agent runtime, gateway, memory, and workload identity.

```bash
# Not: Floci'de canned (hazır) yanıt döner

# Agent runtime oluştur
aws $FLOCI $FAKE bedrock-agentcore create-agent-runtime \
  --agent-runtime-name test-agent \
  --role-arn arn:aws:iam::000000000000:role/agentcore-role

# Runtime'ları listele
aws $FLOCI $FAKE bedrock-agentcore list-agent-runtimes

# Runtime detayını gör
aws $FLOCI $FAKE bedrock-agentcore get-agent-runtime --agent-runtime-identifier ar-1a2b3c4d

# Runtime'ı çağır
aws $FLOCI $FAKE bedrock-agentcore invoke-agent-runtime \
  --agent-runtime-identifier ar-1a2b3c4d \
  --runtime-session-id sess-1 \
  --payload "test-input"

# Runtime'ı sil
aws $FLOCI $FAKE bedrock-agentcore delete-agent-runtime --agent-runtime-identifier ar-1a2b3c4d
```

---

## 105. SageMaker

**What it does:** Provides machine learning model training and deployment infrastructure.

```bash
# Not: Floci README'de op detayı belirtilmemiş; önce liste komutları denenmelidir

# Notebook instance'ları listele
aws $FLOCI $FAKE sagemaker list-notebook-instances

# Endpoint'leri listele
aws $FLOCI $FAKE sagemaker list-endpoints

# Endpoint config'leri listele
aws $FLOCI $FAKE sagemaker list-endpoint-configs

# Eğitim işlerini listele
aws $FLOCI $FAKE sagemaker list-training-jobs
```

---

## 106. GuardDuty — Tehdit Tespiti

**What it does:** Detects malicious activity and anomalies. Analyzes CloudTrail and DNS logs.

```bash
# Detector oluştur (etkinleştir)
aws $FLOCI $FAKE guardduty create-detector --enable

# Detector'ları listele (DetectorId'yi al)
aws $FLOCI $FAKE guardduty list-detectors

# Detector detayını gör
aws $FLOCI $FAKE guardduty get-detector --detector-id dt-fake-1

# Finding'leri listele
aws $FLOCI $FAKE guardduty list-findings --detector-id dt-fake-1 --max-results 10

# Detector'ı sil
aws $FLOCI $FAKE guardduty delete-detector --detector-id dt-fake-1
```

---

## 107. Inspector — Vulnerability Scanning

**What it does:** Automatically scans EC2, ECR images, and Lambdas for vulnerabilities.

```bash
# Kapsam (coverage) listele
aws $FLOCI $FAKE inspector list-coverage

# Finding'leri listele
aws $FLOCI $FAKE inspector list-findings --max-results 10

# Filtre oluştur
aws $FLOCI $FAKE inspector create-filter \
  --name test-filter \
  --action NONE \
  --description "test filter"

# Filtreleri listele
aws $FLOCI $FAKE inspector list-filters
```

---

## 108. Macie — Data Classification

**What it does:** Automatically finds and classifies sensitive data (identity, credit cards) in S3.

```bash
# Classification job oluştur
aws $FLOCI $FAKE macie2 create-classification-job \
  --name test-macie-job \
  --job-type ONE_TIME \
  --s3-job-definition '{"bucketDefinitions":[{"accountId":"000000000000","buckets":["test-bucket"]}]}'

# Job'ları listele
aws $FLOCI $FAKE macie2 list-classification-jobs

# Job detayını gör
aws $FLOCI $FAKE macie2 describe-classification-job --job-id mjc-fake-1
```

---

## 109. Detective — Security Investigation

**What it does:** Models account behaviors to investigate security events graph-based.

```bash
# Graph oluştur
aws $FLOCI $FAKE detective create-graph

# Graph'ları listele (GraphArn'yi al)
aws $FLOCI $FAKE detective list-graphs

# Member ekle
aws $FLOCI $FAKE detective create-members \
  --graph-arn arn:aws:detective:us-east-1:000000000000:graph:1a2b3c \
  --members '[{"AccountId":"111111111111","EmailAddress":"test@example.com","MemberId":"111111111111"}]'

# Member'ları gör
aws $FLOCI $FAKE detective get-members --graph-arn arn:aws:detective:us-east-1:000000000000:graph:1a2b3c --account-ids 111111111111

# Member'ları çıkar
aws $FLOCI $FAKE detective delete-members --graph-arn arn:aws:detective:us-east-1:000000000000:graph:1a2b3c --account-ids 111111111111

# Graph'ı sil
aws $FLOCI $FAKE detective delete-graph --graph-arn arn:aws:detective:us-east-1:000000000000:graph:1a2b3c
```

---

## 110. Security Hub

**What it does:** Centrally collects security findings; produces standard compliance (CIS, PCI) scores.

```bash
# Security Hub'ı etkinleştir
aws $FLOCI $FAKE securityhub enable-security-hub

# Hub detayını gör
aws $FLOCI $FAKE securityhub describe-hub

# Etkin product'ları listele
aws $FLOCI $FAKE securityhub list-enabled-products-for-import

# Test finding'i içe aktar
aws $FLOCI $FAKE securityhub batch-import-findings \
  --findings '[{"AwsAccountId":"000000000000","CreatedAt":"2026-10-01T00:00:00Z","Description":"test finding","Id":"test-finding-1","ProductArn":"arn:aws:securityhub:us-east-1::product/test","SchemaVersion":"2018-10-25","Title":"Test Finding","Types":["Software and Configuration Checks"]}]'

# Finding'leri sorgula
aws $FLOCI $FAKE securityhub get-findings \
  --filters '{"Title":[{"Value":"Test","Comparison":"CONTAINS"}]}'

# Security Hub'ı kapat (temizlik)
aws $FLOCI $FAKE securityhub disable-security-hub
```

---

## 111. IAM Access Analyzer

**What it does:** Detects unintended external access paths in resource policies.

```bash
# Analyzer oluştur (ACCOUNT tipi, organization dışı erişimi tarar)
aws $FLOCI $FAKE accessanalyzer create-analyzer \
  --analyzer-name test-analyzer \
  --type ACCOUNT

# Analyzer'ları listele (arn'yi al)
aws $FLOCI $FAKE accessanalyzer list-analyzers

# Analyzer detayını gör
aws $FLOCI $FAKE accessanalyzer get-analyzer --analyzer-arn arn:aws:accessanalyzer:us-east-1:000000000000:analyzer/test-analyzer

# Finding'leri listele
aws $FLOCI $FAKE accessanalyzer list-findings --analyzer-arn arn:aws:accessanalyzer:us-east-1:000000000000:analyzer/test-analyzer --max-results 10

# Analyzer'ı sil
aws $FLOCI $FAKE accessanalyzer delete-analyzer --analyzer-arn arn:aws:accessanalyzer:us-east-1:000000000000:analyzer/test-analyzer
```

---

## 112. IAM Identity Center (SSO)

**What it does:** Central SSO management for user and group access to AWS accounts. Permission sets authorize per account.

```bash
# Instance oluştur
aws $FLOCI $FAKE sso-admin create-instance

# Instance'ları listele (instanceArn + identityStoreId'yi al)
aws $FLOCI $FAKE sso-admin list-instances

# Instance detayını gör
aws $FLOCI $FAKE sso-admin describe-instance --instance-arn arn:aws:sso:::instance/ssoins-1

# Permission set oluştur
aws $FLOCI $FAKE sso-admin create-permission-set \
  --instance-arn arn:aws:sso:::instance/ssoins-1 \
  --name test-ps \
  --description "test permission set"

# Permission set detayını gör (permissionSetArn'yi al)
aws $FLOCI $FAKE sso-admin describe-permission-set \
  --instance-arn arn:aws:sso:::instance/ssoins-1 \
  --permission-set-arn arn:aws:sso:::permissionSet/ssoins-1/ps-1

# Yönetilen politika bağla
aws $FLOCI $FAKE sso-admin attach-managed-policy-to-permission-set \
  --instance-arn arn:aws:sso:::instance/ssoins-1 \
  --permission-set-arn arn:aws:sso:::permissionSet/ssoins-1/ps-1 \
  --managed-policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

# Permission set'i sil (önce detach gerekir)
aws $FLOCI $FAKE sso-admin delete-permission-set \
  --instance-arn arn:aws:sso:::instance/ssoins-1 \
  --permission-set-arn arn:aws:sso:::permissionSet/ssoins-1/ps-1

# OIDC client kaydet (device authorization akışı için)
aws $FLOCI $FAKE sso-oidc register-client \
  --client-name test-client \
  --client-type public
```

---

## 113. Identity Store

**What it does:** Manages the user and group directory of IAM Identity Center. User creation, group membership, and profile info run through this API.

```bash
# Identity store ID'yi al (SSO instance'ından)
aws $FLOCI $FAKE sso-admin list-instances \
  --query Instances[0].IdentityStoreId --output text

# Kullanıcı oluştur
aws $FLOCI $FAKE identitystore create-user \
  --identity-store-id d-fake-1 \
  --user-name test.user \
  --emails '[{"Value":"test@example.com","Primary":true}]'

# Kullanıcıları listele (UserId'yi al)
aws $FLOCI $FAKE identitystore list-users --identity-store-id d-fake-1

# Kullanıcı detayını gör
aws $FLOCI $FAKE identitystore describe-user \
  --identity-store-id d-fake-1 \
  --user-id u-fake-1

# Grup oluştur
aws $FLOCI $FAKE identitystore create-group \
  --identity-store-id d-fake-1 \
  --display-name test-group

# Grupları listele
aws $FLOCI $FAKE identitystore list-groups --identity-store-id d-fake-1

# Kullanıcıyı sil (temizlik)
aws $FLOCI $FAKE identitystore delete-user \
  --identity-store-id d-fake-1 \
  --user-id u-fake-1
```

---

## 114. Network Firewall

**What it does:** Network filtering at VPC level. In Floci, infra tooling can be tested with emulated endpoint attachments.

```bash
# Firewall listesi (Floci'de emulated)
aws $FLOCI $FAKE network-firewall list-firewalls

# Firewall detayını gör (emulated endpoint döner)
aws $FLOCI $FAKE network-firewall describe-firewall \
  --firewall-arn arn:aws:network-firewall:us-east-1:000000000000:firewall/test-firewall
```

---

## 115. CloudHSM

**What it does:** Key storage and cryptographic operations with a hardware security module (HSM).

```bash
# Cluster oluştur
aws $FLOCI $FAKE cloudhsmv2 create-cluster \
  --hsm-type hsm1.medium \
  --subnet-ids subnet-fake

# Cluster'ları listele (ClusterId'yi al)
aws $FLOCI $FAKE cloudhsmv2 describe-clusters

# HSM node ekle
aws $FLOCI $FAKE cloudhsmv2 create-hsm \
  --cluster-id cluster-1A2B3C \
  --availability-zone us-east-1a

# Cluster'ı sil (temizlik)
aws $FLOCI $FAKE cloudhsmv2 delete-cluster --cluster-id cluster-1A2B3C
```

---

## 116. Resource Explorer 2

**What it does:** Queries resources in the account through a single search API. Multi-region resource discovery with index and view models.

```bash
# Index oluştur (bölge varsayılanı)
aws $FLOCI $FAKE resource-explorer-2 create-index

# Index durumunu gör
aws $FLOCI $FAKE resource-explorer-2 get-index

# View oluştur
aws $FLOCI $FAKE resource-explorer-2 create-view --view-name test-view

# View'ları listele
aws $FLOCI $FAKE resource-explorer-2 list-views

# Kaynak ara (S3 bucket'ları)
aws $FLOCI $FAKE resource-explorer-2 search \
  --query-string "resourceType:s3:bucket"

# Tüm kaynakları ara
aws $FLOCI $FAKE resource-explorer-2 search --query-string "*"

# View'ı sil (temizlik)
aws $FLOCI $FAKE resource-explorer-2 delete-view --view-name test-view
```

---

## 117. RAM — Resource Access Manager

**What it does:** Shares resources across accounts and OUs.

```bash
# Organization ile paylaşımı etkinleştir
aws $FLOCI $FAKE ram enable-sharing-with-aws-organization

# Kaynak paylaşımı oluştur
aws $FLOCI $FAKE ram create-resource-share --name test-share

# Paylaşımları listele (resourceShareArn'yi al)
aws $FLOCI $FAKE ram list-resource-shares

# Paylaşımı sil (temizlik)
aws $FLOCI $FAKE ram delete-resource-share --resource-share-arn arn:aws:ram:us-east-1:000000000000:resource-share/rs-1
```

---

## 118. Service Quotas

**What it does:** Lists service quotas and creates increase requests. Floci returns a static quota catalog.

```bash
# Servisleri listele
aws $FLOCI $FAKE service-quotas list-services

# CodeBuild kotalarını listele (quota kodlarını gör)
aws $FLOCI $FAKE service-quotas list-service-quotas --service-code codebuild

# Belirli kota detayını gör
aws $FLOCI $FAKE service-quotas get-service-quota \
  --service-code codebuild \
  --quota-code L-FAKE0123

# Kota artırımı talep et
aws $FLOCI $FAKE service-quotas request-service-quota-increase \
  --service-code codebuild \
  --quota-code L-FAKE0123 \
  --desired-value 100

# Talep geçmişini listele
aws $FLOCI $FAKE service-quotas list-requested-service-quota-change-history
```

---

## 119. AWS Account Management

**What it does:** Manages the account's name, contact, and alternate contact info.

```bash
# Hesap bilgilerini gör
aws $FLOCI $FAKE account get-account-information

# Alternatif iletişim bilgisini gör (fatura)
aws $FLOCI $FAKE account get-alternate-contact --alternate-contact-type BILLING

# Alternatif iletişim bilgisini güncelle
aws $FLOCI $FAKE account put-alternate-contact \
  --alternate-contact-type BILLING \
  --contact '{"Name":"Ops","EmailAddress":"ops@example.com","PhoneNumber":"+905550000000","Title":"Ops Lead","AddressLine1":"Test Address"}'

# Hesap adını güncelle
aws $FLOCI $FAKE account put-account-name --account-name test-account
```

---

## 120. Service Catalog

**What it does:** Approved product and portfolio management. Users provision products self-service.

```bash
# Portföy oluştur
aws $FLOCI $FAKE servicecatalog create-portfolio --display-name "Test Portfolio"

# Portföyleri listele (PortfolioId'yi al)
aws $FLOCI $FAKE servicecatalog list-portfolios

# Ürün ara
aws $FLOCI $FAKE servicecatalog search-products

# Portföyü sil (temizlik)
aws $FLOCI $FAKE servicecatalog delete-portfolio --id port-fake-1
```

---

## 121. Control Tower

**What it does:** Sets up landing zones in multi-account environments and manages guardrails (controls).

```bash
# Landing zone'ları listele
aws $FLOCI $FAKE controltower list-landing-zones

# Landing zone detayını gör
aws $FLOCI $FAKE controltower get-landing-zone --landing-zone-id lz-fake-1

# Etkin control'leri listele (target: OU arn'si)
aws $FLOCI $FAKE controltower list-enabled-controls \
  --target-identifier arn:aws:organizations::000000000000:ou/o-fake/ou-fake-xxxx
```

---

## 122. Control Catalog

**What it does:** Lists the Control Tower and Security Hub control catalog.

```bash
# Kontrolleri listele
aws $FLOCI $FAKE controlcatalog list-controls

# Kontrol detayını gör
aws $FLOCI $FAKE controlcatalog get-control --control-id ctrl-fake-1

# Kontrol domain'lerini listele
aws $FLOCI $FAKE controlcatalog list-domains
```

---

## 123. Marketplace Catalog

**What it does:** Lists AWS Marketplace products and manages purchase entities.

```bash
# Not: Floci'de op detayı dokümante edilmemiş; önce liste komutları denenmelidir

# AMI ürünlerini listele
aws $FLOCI $FAKE marketplace-catalog list-entities --entity-type AmiProduct

# SaaS ürünlerini listele
aws $FLOCI $FAKE marketplace-catalog list-entities --entity-type SaaSProduct

# Entity detayını gör
aws $FLOCI $FAKE marketplace-catalog describe-entity \
  --catalog AWSMarketplace \
  --entity-id ent-fake-1 \
  --entity-type SaaSProduct
```

---

## 124. Connect — Contact Center

**What it does:** Provides call center (contact center) instances. Used for inbound/outbound call management.

```bash
# Instance oluştur
aws $FLOCI $FAKE connect create-instance \
  --identity-management-type CONNECT_MANAGED \
  --no-inbound-call-enabled \
  --no-outbound-call-enabled

# Instance'ları listele (Id'yi al)
aws $FLOCI $FAKE connect list-instances

# Instance detayını gör
aws $FLOCI $FAKE connect describe-instance --instance-id fake-instance-1

# Instance'ı sil (temizlik)
aws $FLOCI $FAKE connect delete-instance --instance-id fake-instance-1
```

---

## 125. AppIntegrations

**What it does:** Manages application and event integration definitions. Used for Connect and EventBridge integrations.

```bash
# Uygulama oluştur
aws $FLOCI $FAKE appintegrations create-application --name test-app

# Uygulamaları listele
aws $FLOCI $FAKE appintegrations list-applications

# Event integration oluştur
aws $FLOCI $FAKE appintegrations create-event-integration \
  --name test-event \
  --event-filter '{"Source":"test-source"}' \
  --event-bridge-bus arn:aws:events:us-east-1:000000000000:event-bus/default

# Event integration'ları listele
aws $FLOCI $FAKE appintegrations list-event-integrations

# Temizlik
aws $FLOCI $FAKE appintegrations delete-event-integration --name test-event
aws $FLOCI $FAKE appintegrations delete-application --arn arn:aws:appintegrations:us-east-1:000000000000:application/app-1
```

---

## 126. Budgets

**What it does:** Defines account-based cost budgets and alert thresholds.

```bash
# Bütçe oluştur (100 USD/ay maliyet)
aws $FLOCI $FAKE budgets create-budget \
  --account-id 000000000000 \
  --budget '{"BudgetName":"test-budget","BudgetLimit":{"Amount":"100","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'

# Bütçeleri listele
aws $FLOCI $FAKE budgets list-budgets --account-id 000000000000

# Bütçe detayını gör
aws $FLOCI $FAKE budgets describe-budget \
  --account-id 000000000000 \
  --budget-name test-budget

# Bütçeyi sil (temizlik)
aws $FLOCI $FAKE budgets delete-budget \
  --account-id 000000000000 \
  --budget-name test-budget
```

---

## 127. BCM Pricing Calculator

**What it does:** Creates and prices local workload cost estimates (bill estimate).

```bash
# Tahmin listesi
aws $FLOCI $FAKE bcm-pricing-calculator list-bill-estimates

# Tahmin oluştur
aws $FLOCI $FAKE bcm-pricing-calculator create-bill-estimate \
  --name test-estimate \
  --bill-interval '{"StartMonth":{"Month":10,"Year":2026},"EndMonth":{"Month":10,"Year":2026}}'

# Tahmin detayını gör
aws $FLOCI $FAKE bcm-pricing-calculator get-bill-estimate --bill-estimate-id be-fake-1

# Tahmini sil (temizlik)
aws $FLOCI $FAKE bcm-pricing-calculator delete-bill-estimate --bill-estimate-id be-fake-1
```

---

## 128. FIS — Fault Injection Service

**What it does:** Defines controlled experiment (fault injection) templates. In Floci, runs are safe control-plane simulations; no real faults are injected.

```bash
# Deney şablonu oluştur
aws $FLOCI $FAKE fis create-experiment-template \
  --description "test template" \
  --role-arn arn:aws:iam::000000000000:role/fis-role \
  --actions '{"stop-instance":{"ActionId":"aws:fis:inject-api-internal-error","Parameters":{}}}'

# Şablonları listele (id'yi al)
aws $FLOCI $FAKE fis list-experiment-templates

# Şablon detayını gör
aws $FLOCI $FAKE fis get-experiment-template --id EXP-T-fake1

# Deneyi başlat (Floci'de güvenli simülasyon)
aws $FLOCI $FAKE fis start-experiment --experiment-template-id EXP-T-fake1

# Deneyleri listele
aws $FLOCI $FAKE fis list-experiments

# Şablonu sil (temizlik)
aws $FLOCI $FAKE fis delete-experiment-template --id EXP-T-fake1
```

---

## 129. DLM — Data Lifecycle Manager

**What it does:** Defines automatic snapshot lifecycle policies for EBS volumes. In Floci, policies are stored but no real snapshots are created.

```bash
# Yaşam döngüsü politikası oluştur
aws $FLOCI $FAKE dlm create-lifecycle-policy \
  --description test-dlm \
  --state ENABLED \
  --execution-role-arn arn:aws:iam::000000000000:role/dlm-role \
  --policy-details '{"ResourceTypes":["VOLUME"],"TargetTags":[{"Key":"dlm","Value":"test"}],"Schedules":[{"Name":"daily","CreateRule":{"Interval":24,"IntervalUnit":"HOURS","Times":["03:00"]}}]}'

# Politikaları listele (policyId'yi al)
aws $FLOCI $FAKE dlm list-lifecycle-policies

# Politika detayını gör
aws $FLOCI $FAKE dlm get-lifecycle-policy --policy-id policy-fake-1

# Politikayı sil (temizlik)
aws $FLOCI $FAKE dlm delete-lifecycle-policy --policy-id policy-fake-1
```

---

## Bulk Cleanup (after tests)

```bash
# S3
aws $FLOCI $FAKE s3 rb s3://test-bucket 2>/dev/null
aws $FLOCI $FAKE s3 rb s3://cf-test-bucket 2>/dev/null

# SQS
for url in $(aws $FLOCI $FAKE sqs list-queues --query QueueUrls --output text 2>/dev/null); do
  aws $FLOCI $FAKE sqs delete-queue --queue-url "$url"
done

# DynamoDB
for table in $(aws $FLOCI $FAKE dynamodb list-tables --output text 2>/dev/null); do
  aws $FLOCI $FAKE dynamodb delete-table --table-name "$table"
done

# Lambda
for fn in $(aws $FLOCI $FAKE lambda list-functions --query Functions[].FunctionName --output text 2>/dev/null); do
  aws $FLOCI $FAKE lambda delete-function --function-name "$fn"
done

# CloudFormation
for stack in $(aws $FLOCI $FAKE cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query StackSummaries[].StackName --output text 2>/dev/null); do
  aws $FLOCI $FAKE cloudformation delete-stack --stack-name "$stack"
done

# IAM users
for user in $(aws $FLOCI $FAKE iam list-users --query Users[].UserName --output text 2>/dev/null); do
  for policy_arn in $(aws $FLOCI $FAKE iam list-attached-user-policies --user-name "$user" --query AttachedPolicies[].PolicyArn --output text 2>/dev/null); do
    aws $FLOCI $FAKE iam detach-user-policy --user-name "$user" --policy-arn "$policy_arn"
  done
  for key in $(aws $FLOCI $FAKE iam list-access-keys --user-name "$user" --query AccessKeyMetadata[].AccessKeyId --output text 2>/dev/null); do
    aws $FLOCI $FAKE iam delete-access-key --user-name "$user" --access-key-id "$key"
  done
  aws $FLOCI $FAKE iam delete-user --user-name "$user"
done

# Secrets Manager
for secret in $(aws $FLOCI $FAKE secretsmanager list-secrets --query SecretList[].Name --output text 2>/dev/null); do
  aws $FLOCI $FAKE secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery
done

# Log groups
for group in $(aws $FLOCI $FAKE logs describe-log-groups --query logGroups[].logGroupName --output text 2>/dev/null); do
  aws $FLOCI $FAKE logs delete-log-group --log-group-name "$group"
done

# Redshift
for cid in $(aws $FLOCI $FAKE redshift describe-clusters --query Clusters[].ClusterIdentifier --output text 2>/dev/null); do
  aws $FLOCI $FAKE redshift delete-cluster --cluster-identifier "$cid" --skip-final-cluster-snapshot
done

# MWAA
for env in $(aws $FLOCI $FAKE mwaa list-environments --query Environments --output text 2>/dev/null); do
  aws $FLOCI $FAKE mwaa delete-environment --name "$env"
done

# Flink: önce durdur, sonra sil
for app in $(aws $FLOCI $FAKE kinesisanalyticsv2 list-applications --query ApplicationSummaries[].ApplicationName --output text 2>/dev/null); do
  aws $FLOCI $FAKE kinesisanalyticsv2 stop-application --application-name "$app" 2>/dev/null
  aws $FLOCI $FAKE kinesisanalyticsv2 delete-application --application-name "$app"
done

# DMS: görev → endpoint → instance sırasıyla
for t in $(aws $FLOCI $FAKE dms describe-replication-tasks --query ReplicationTasks[].ReplicationTaskArn --output text 2>/dev/null); do
  aws $FLOCI $FAKE dms delete-replication-task --replication-task-arn "$t"
done
for e in $(aws $FLOCI $FAKE dms describe-endpoints --query Endpoints[].EndpointArn --output text 2>/dev/null); do
  aws $FLOCI $FAKE dms delete-endpoint --endpoint-arn "$e"
done
for r in $(aws $FLOCI $FAKE dms describe-replication-instances --query ReplicationInstances[].ReplicationInstanceArn --output text 2>/dev/null); do
  aws $FLOCI $FAKE dms delete-replication-instance --replication-instance-arn "$r"
done

# EFS: access point → mount target → dosya sistemi sırasıyla
for ap in $(aws $FLOCI $FAKE efs describe-access-points --query AccessPoints[].AccessPointId --output text 2>/dev/null); do
  aws $FLOCI $FAKE efs delete-access-point --access-point-id "$ap"
done
for fs in $(aws $FLOCI $FAKE efs describe-file-systems --query FileSystems[].FileSystemId --output text 2>/dev/null); do
  for mt in $(aws $FLOCI $FAKE efs describe-mount-targets --file-system-id "$fs" --query MountTargets[].MountTargetId --output text 2>/dev/null); do
    aws $FLOCI $FAKE efs delete-mount-target --mount-target-id "$mt"
  done
  aws $FLOCI $FAKE efs delete-file-system --file-system-id "$fs"
done

# DataSync: görev → konum sırasıyla
for t in $(aws $FLOCI $FAKE datasync list-tasks --query Tasks[].TaskArn --output text 2>/dev/null); do
  aws $FLOCI $FAKE datasync delete-task --task-arn "$t"
done
for l in $(aws $FLOCI $FAKE datasync list-locations --query Locations[].LocationArn --output text 2>/dev/null); do
  aws $FLOCI $FAKE datasync delete-location --location-arn "$l"
done

# EMR Serverless
for app in $(aws $FLOCI $FAKE emr-serverless list-applications --query applications[].id --output text 2>/dev/null); do
  aws $FLOCI $FAKE emr-serverless stop-application --application-id "$app" 2>/dev/null
  aws $FLOCI $FAKE emr-serverless delete-application --application-id "$app"
done

# S3 Tables (tablolar ve namespace'ler önce silinmeli)
for b in $(aws $FLOCI $FAKE s3tables list-table-buckets --query tableBuckets[].arn --output text 2>/dev/null); do
  aws $FLOCI $FAKE s3tables delete-table-bucket --table-bucket-arn "$b"
done

# Global Accelerator: endpoint group → listener → accelerator sırasıyla
for acc in $(aws $FLOCI $FAKE globalaccelerator list-accelerators --query Accelerators[].AcceleratorArn --output text 2>/dev/null); do
  for lst in $(aws $FLOCI $FAKE globalaccelerator describe-listeners --accelerator-arn "$acc" --query Listeners[].ListenerArn --output text 2>/dev/null); do
    for eg in $(aws $FLOCI $FAKE globalaccelerator describe-endpoint-groups --listener-arn "$lst" --query EndpointGroups[].EndpointGroupArn --output text 2>/dev/null); do
      aws $FLOCI $FAKE globalaccelerator delete-endpoint-group --endpoint-group-arn "$eg"
    done
    aws $FLOCI $FAKE globalaccelerator delete-listener --listener-arn "$lst"
  done
  aws $FLOCI $FAKE globalaccelerator delete-accelerator --accelerator-arn "$acc"
done

# Cognito identity pool'ları
for p in $(aws $FLOCI $FAKE cognito-identity list-identity-pools --max-results 50 --query IdentityPools[].IdentityPoolId --output text 2>/dev/null); do
  aws $FLOCI $FAKE cognito-identity delete-identity-pool --identity-pool-id "$p"
done

# ELB Classic
for elb in $(aws $FLOCI $FAKE elb describe-load-balancers --query LoadBalancerDescriptions[].LoadBalancerName --output text 2>/dev/null); do
  aws $FLOCI $FAKE elb delete-load-balancer --load-balancer-name "$elb"
done

# CodeArtifact: repo → domain sırasıyla
for d in $(aws $FLOCI $FAKE codeartifact list-domains --query domains[].name --output text 2>/dev/null); do
  for r in $(aws $FLOCI $FAKE codeartifact list-repositories-in-domain --domain "$d" --query repositories[].name --output text 2>/dev/null); do
    aws $FLOCI $FAKE codeartifact delete-repository --domain "$d" --repository "$r"
  done
  aws $FLOCI $FAKE codeartifact delete-domain --domain "$d"
done

# GuardDuty
for det in $(aws $FLOCI $FAKE guardduty list-detectors --query DetectorIds --output text 2>/dev/null); do
  aws $FLOCI $FAKE guardduty delete-detector --detector-id "$det"
done

# Access Analyzer
for an in $(aws $FLOCI $FAKE accessanalyzer list-analyzers --query analyzers[].arn --output text 2>/dev/null); do
  aws $FLOCI $FAKE accessanalyzer delete-analyzer --analyzer-arn "$an"
done

# Detective
for grn in $(aws $FLOCI $FAKE detective list-graphs --query GraphList[].Arn --output text 2>/dev/null); do
  aws $FLOCI $FAKE detective delete-graph --graph-arn "$grn"
done

# Security Hub
aws $FLOCI $FAKE securityhub disable-security-hub 2>/dev/null

# Budgets
for b in $(aws $FLOCI $FAKE budgets list-budgets --account-id 000000000000 --query Budgets[].BudgetName --output text 2>/dev/null); do
  aws $FLOCI $FAKE budgets delete-budget --account-id 000000000000 --budget-name "$b"
done

# FIS şablonları
for t in $(aws $FLOCI $FAKE fis list-experiment-templates --query experimentTemplates[].id --output text 2>/dev/null); do
  aws $FLOCI $FAKE fis delete-experiment-template --id "$t"
done

# DLM politikaları
for p in $(aws $FLOCI $FAKE dlm list-lifecycle-policies --query Policies[].policyId --output text 2>/dev/null); do
  aws $FLOCI $FAKE dlm delete-lifecycle-policy --policy-id "$p"
done

# Connect instance'ları
for c in $(aws $FLOCI $FAKE connect list-instances --query InstanceSummaryList[].Id --output text 2>/dev/null); do
  aws $FLOCI $FAKE connect delete-instance --instance-id "$c"
done

# SWF domain'leri (deprecate)
for dmn in $(aws $FLOCI $FAKE swf list-domains --registration-status REGISTERED --query DomainInfos[].name --output text 2>/dev/null); do
  aws $FLOCI $FAKE swf deprecate-domain --name "$dmn"
done
```

> **Note:** Some services (Bedrock Runtime, AgentCore, Textract, Transcribe, Comprehend, Rekognition, Translate, Pricing, CE, CUR) return mock/fixed responses in Floci. For some control-plane services (SageMaker, Marketplace, Network Firewall), op details are undocumented; list (list/get) commands should be tried first. Real AWS behavior shouldn't be expected.
