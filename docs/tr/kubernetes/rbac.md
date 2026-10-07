# K8s RBAC Rolleri ve Kubeconfig Yönetimi

## İçindekiler

1. [Giriş: RBAC Nedir?](#1-giriş-rbac-nedir)
2. [Yerleşik (Built-in) Roller](#2-yerleşik-built-in-roller)
3. [Özel (Custom) ClusterRole'ler — 9 Temel Rol](#3-özel-custom-clusterroleler--9-temel-rol)
4. [Aggregated Roller — 5 Rol](#4-aggregated-roller--5-rol)
5. [Aggregation Mantığı Detaylı](#5-aggregation-mantığı-detaylı)
6. [Custom ClusterRole Eklemek (On-the-fly)](#6-custom-clusterrole-eklemek-on-the-fly)
7. [Mevcut Rolleri Genişletmek](#7-mevcut-rolleri-genişletmek)
8. [Kubeconfig Üretme](#8-kubeconfig-üretme)
9. [Yetki Sınırları ve Güvenlik](#9-yetki-sınırları-ve-güvenlik)
10. [Sık Kullanım Senaryoları](#10-sık-kullanım-senaryoları)

---

## 1. Giriş: RBAC Nedir?

Kubernetes'te RBAC (Role-Based Access Control), kimin hangi kaynaklara erişebileceğini belirleyen yetkilendirme mekanizmasıdır. Dört temel nesneden oluşur:

| Nesne | Kapsam | Ne işe yarar |
|---|---|---|
| **Role** | Namespace | Bir namespace içindeki kaynaklara erişim kuralları |
| **ClusterRole** | Cluster geneli | Tüm cluster'daki kaynaklara veya namespace'e özel erişim kuralları |
| **RoleBinding** | Namespace | Role/ClusterRole'u bir kullanıcı/SA'ye namespace içinde bağlar |
| **ClusterRoleBinding** | Cluster geneli | ClusterRole'u bir kullanıcı/SA'ye cluster genelinde bağlar |

**Önemli ayrım**: Bir ClusterRole'u **RoleBinding** ile bağlarsanız, yetkiler sadece o namespace içinde geçerlidir. **ClusterRoleBinding** ile bağlarsanız tüm cluster'da geçerlidir. Bu projede monitoring hariç tüm roller RoleBinding kullanır.

---

## 2. Yerleşik (Built-in) Roller

Kubernetes varsayılan olarak 4 built-in ClusterRole getirir. Bunlar `kubectl` ile hazır gelir, biz tanımlamayız:

| Built-in Rol | Kapsam | Ne Yapabilir | Ne Yapamaz |
|---|---|---|---|
| `view` | Namespace | Çoğu kaynağı okuyabilir (get/list/watch) | Secret, pod/log, RBAC kaynaklarını okuyamaz |
| `edit` | Namespace | Kaynakları oluşturabilir/güncelleyebilir | Secret okuyamaz, RBAC yönetemez |
| `admin` | Namespace | Namespace içinde tam yetki | Namespace'in kendisini silemez, ResourceQuota yönetemez |
| `cluster-admin` | Cluster | **Sınırsız** — her şeyi yapabilir | — |

Bu roller bu projede doğrudan kullanılmaz. Bunun yerine, daha ince taneli (fine-grained) **özel roller** tanımlanmıştır. Built-in rollerin eksikleri:

- `view` → **Secret okuyamaz** (ama bazen admin'in secret görmesi gerekir)
- `edit` → **Secret okuyamaz** (ama deployer'ın secret okuması gerekir)
- `admin` → **Namespace içinde çok geniş** (RBAC yönetimine izin verir, bu da privilege escalation riskidir)
- Hepsi **aggregation** etiketlerine sahiptir (`rbac.authorization.k8s.io/aggregate-to-view: "true"` gibi) ama biz kendi etiket sistemimizi kullanıyoruz

Bu projedeki özel roller, built-in rollerin aksine:

| Özellik | Built-in `edit` | Bizim `deployer` |
|---|---|---|
| Secret okuma | ❌ | ✅ (sınırlı) |
| Pod exec | ✅ (dolaylı) | ❌ |
| Secret yazma | ❌ | ✅ (sınırlı) |
| RBAC yönetimi | ❌ | ❌ |

---

## 3. Özel (Custom) ClusterRole'ler — 9 Temel Rol

Bu roller `ansible/roles/k8s/security/templates/cluster-roles.yaml.j2` dosyasında tanımlanmıştır. Her biri tek bir sorumluluğa odaklanır (Single Responsibility). Herbiri ayrı ayrı **veya** aggregation ile birleşik olarak kullanılabilir.

### 3.1. Okuma Rolleri (Read-only)

#### `pod-reader`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```
**Ne işe yarar**: Sadece pod'ları listelemek için. Log okumaz, exec girmez. En kısıtlı roldür.
**Nerede kullanılır**: Dış denetçiler, salt okunur panel dashboard'ları.
**Built-in karşılığı**: `view` rolünün bir alt kümesi (view çok daha fazlasını görür).

#### `pod-log-reader`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
```
**Ne işe yarar**: Pod'ları ve log'larını okur.
**Nerede kullanılır**: Log toplama sistemleri, debugging araçları.
**Önemli**: `pods/log` ayrı bir subresource'dır. `pod-reader` bunu kapsamaz.

#### `workload-viewer`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "endpoints", "events", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
```
**Ne işe yarar**: Tüm iş yükü kaynaklarını görüntüler. Secret'ları görmez.
**Built-in karşılığı**: `view` rolüne yakındır, ama view daha fazla kaynak türünü kapsar (ör: horizontalpodautoscalers).

#### `full-viewer`
```yaml
rules:
  # ↑ workload-viewer'ın tüm yetkileri + pods/log + aşağıdakiler
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
```
**Ne işe yarar**: Secret ve pod log'ları dahil her şeyi görür. Yazamaz.
**Ne zaman kullanılır**: Admin seviyesinde okuma ihtiyacı. Secret'ları görmek `view` ile mümkün değildir.

---

### 3.2. Yazma Rolleri (Write/Operate)

#### `pod-operator`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/portforward"]
    verbs: ["create"]
```
**Ne işe yarar**: Pod'lar üzerinde tam kontrol. Pod oluşturma, silme, exec ile içine girme, portforward yapma. `exec` ve `portforward` subresource'lar ayrıca tanımlanmıştır — normalde `pods` üzerinde `create` izni bu alt kaynakları kapsamaz.
**Ne zaman kullanılır**: Geliştiricilerin pod içine girip debug yapması gereken durumlar.

#### `workload-operator`
```yaml
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["get", "update", "patch"]
```
**Ne işe yarar**: Deployment, StatefulSet, DaemonSet güncelleyebilir, scale edebilir.
**Yetmez**: Deployment **silme** izni yoktur. Bu bilinçli bir kısıtlamadır — deployment silmek daha üst yetki gerektirir.

#### `config-editor`
```yaml
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```
**Ne işe yarar**: ConfigMap ve Secret tam yönetimi (CRUD).
**Risk**: Secret silebilir → dikkatli kullanılmalı.
**Ne zaman kullanılır**: Sekretleri yöneten araçlar, CI/CD pipeline'ları.

#### `deployer`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update"]
```
**Ne işe yarar**: Bir uygulamayı deploy etmek için gereken minimum yetki. Pod oluşturamaz (deployment üzerinden yapar), secret silemez (sadece oluşturup güncelleyebilir).
**Built-in `edit`'ten farkı**: Secret okuyabilir ve oluşturabilir. Ama pod'lara exec giremez.
**CI/CD için idealdir**: GitHub Actions, GitLab CI, ArgoCD gibi araçlar bu rolle deploy yapar.

---

### 3.3. Monitoring

#### `monitoring-reader`
```yaml
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "nodes/stats", "services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
```
**Ne işe yarar**: Node seviyesinde metrik okur (CPU, memory, disk). Node'lar cluster-scoped kaynaklardır, bu yüzden bu rol ClusterRoleBinding gerektirir.
**Nerede kullanılır**: Prometheus, Grafana, kube-state-metrics gibi monitoring araçları.
**Built-in karşılığı**: Yok. Built-in roller node'lara erişim vermez.

---

## 4. Aggregated Roller — 5 Rol

Bu roller `cluster-roles.yaml.j2` içinde `aggregationRule` ile tanımlanmıştır. Kendi kuralları yoktur — K8s, etiketlere göre otomatik doldurur.

### aggregated-viewer
**İçindekiler**: `pod-reader` + `pod-log-reader` + `workload-viewer`
**Ne yapabilir**:
- Pod'ları görür (`get pods`)
- Log okur (`logs -f`)
- Service, deployment, configmap, pvc, events görür
**Ne yapamaz**:
- Secret okuyamaz
- Pod oluşturamaz/silemez
- Exec giremez

**Built-in `view` ile karşılaştırma**:
- `view` → daha fazla kaynak türü görür (HPA, LimitRange, ResourceQuota dahil)
- Bizim `viewer` → daha az kaynak görür ama pod log'larını okuyabilir (`view` okuyamaz)

### aggregated-developer
**İçindekiler**: `pod-reader` + `pod-log-reader` + `workload-viewer` + `pod-operator` + `workload-operator`
**Ne yapabilir**:
- Tüm görüntüleme yetkileri
- Pod oluşturma/silme
- Deployment güncelleme, scale etme
- Exec ile pod içine girme
**Ne yapamaz**:
- Secret okuyamaz
- Secret/configmap oluşturamaz
- Service oluşturamaz

**Built-in `edit` ile karşılaştırma**:
- `edit` → service/deployment/configmap/secret oluşturabilir (ama secret'ı okuyamaz)
- Bizim `developer` → pod'a exec girebilir (edit giremez), ama service/configmap oluşturamaz

**Bu fark bilinçlidir**: Developer'ın pod'da hata ayıklaması gerekir, deployment yapması gerekmez. Deploy işlemi CI/CD'ye aittir.

### aggregated-deployer
**İçindekiler**: `config-editor` + `deployer`
**Ne yapabilir**:
- Deployment oluşturma/güncelleme/silme
- Service oluşturma/güncelleme/silme
- ConfigMap tam yönetim
- Secret okuma, oluşturma, güncelleme (silemez)
**Ne yapamaz**:
- Pod'lara exec giremez
- Pod oluşturamaz (deployment üzerinden yapar)
- Node'ları göremez

### aggregated-admin
**İçindekiler**: 9 rolün hepsi (monitoring-reader dahil)
**Ne yapabilir**: Namespace içinde her şeyi
**Ne yapamaz**: Namespace'i silemez, cluster-scoped kaynakları yönetemez
**Built-in karşılığı**: `admin` rolüne benzer ama cluster-scoped RBAC yönetimi yoktur

### aggregated-monitoring
**İçindekiler**: `monitoring-reader`
**Binding türü**: ClusterRoleBinding (node'lar cluster-scoped olduğu için)
**Ne yapabilir**: Tüm node'ları, pod'ları, metrikleri okur
**Ne yapamaz**: Hiçbir şey yazamaz

---

## 5. Aggregation Mantığı Detaylı

Kubernetes'in `aggregationRule` özelliği sayesinde bir ClusterRole, etiketlerle diğer ClusterRole'leri otomatik olarak içerebilir.

### Nasıl çalışır?

Bir ClusterRole, **aggregationRule** içerir ve `rules: []` boş bırakılır. K8s, **clusterRoleSelectors** ile eşleşen tüm ClusterRole'leri bulur ve kurallarını birleştirir.

### Örnek: aggregated-developer nasıl oluşur?

Adım 1: Temel roller etiketlenir
```yaml
# pod-reader → etiket: developer
kind: ClusterRole
metadata:
  name: pod-reader
  labels:
    rbac.aggregate/developer: "true"   # ← aggregation etiketi
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```

Adım 2: Aggregated rol bu etiketi seçer
```yaml
kind: ClusterRole
metadata:
  name: aggregated-developer
aggregationRule:
  clusterRoleSelectors:
    - matchLabels:
        rbac.aggregate/developer: "true"   # ← pod-reader, workload-viewer, pod-operator, workload-operator
rules: []   # ← K8s otomatik doldurur
```

Adım 3: K8s, `rbac.aggregate/developer: "true"` etiketi olan TÜM ClusterRole'leri toplar ve kurallarını `aggregated-developer` altında birleştirir.

### Bir rol neden birden çok aggregate'e dahil olur?

```yaml
kind: ClusterRole
metadata:
  name: config-editor
  labels:
    rbac.aggregate/deployer: "true"   # deployer'a dahil
    rbac.aggregate/admin: "true"      # admin'e de dahil
```

Bu sayede `config-editor`:

- Tek başına kullanılabilir (`cluster_role=config-editor`)
- `deployer` aggregate'inin bir parçası olabilir
- `admin` aggregate'inin bir parçası olabilir

Aynı ClusterRole aynı anda **birden çok** aggregate'de yer alabilir.

### Aggregation'ın avantajı

**Yeni bir yetki eklemek** istediğinizde:

1. Yeni bir ClusterRole yazarsınız
2. Hangi aggregate'lere dahil olması gerektiğini label ile belirtirsiniz
3. K8s otomatik olarak onu ilgili aggregated rollere ekler
4. Mevcut binding'leri güncellemeniz gerekmez

**Aggregation olmasaydı**:
Her aggregate'i manuel olarak güncellemeniz, her birine ayrı ayrı rule eklemeniz gerekirdi.

---

## 6. Custom ClusterRole Eklemek (On-the-fly)

Mevcut 9 role ek olarak, `inventory/group_vars/all/all.yml`'ye yeni roller tanımlayabilirsiniz. Template'e dokunmanız gerekmez.

### 6.1. Tek bir rule ile

```yaml
# inventory/group_vars/all/all.yml
custom_cluster_roles:
  - name: redis-operator
    aggregates:
      - developer
    apiGroups: [""]
    resources:
      - pods
      - configmaps
    verbs:
      - get
      - list
      - watch
      - create
      - update
```

### 6.2. Aynı role birden çok rule ile (aynı name)

```yaml
custom_cluster_roles:
  - name: redis-operator
    aggregates: [developer]
    apiGroups: [""]
    resources: [pods, configmaps]
    verbs: [get, list, watch, create, update]
  - name: redis-operator
    aggregates: [admin]
    apiGroups: ["apps"]
    resources: [deployments]
    verbs: [get, list, watch, create, update, delete]
```

Aynı `name` → tek ClusterRole, birden çok rule. `aggregates` otomatik birleşir (developer + admin).

### 6.3. Uygulama

```bash
ansible-playbook playbooks/k8s.yml --tags=security
```

### 6.4. Custom rol için kubeconfig

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=redis-operator \
  -e namespace=redis
```

---

## 7. Mevcut Rolleri Genişletmek

### 7.1. Yeni bir ClusterRole eklemek (template'e)

`cluster-roles.yaml.j2` dosyasına yeni bir blok ekleyin:

```yaml
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: my-new-role
  labels:
    rbac.aggregate/developer: "true"
    rbac.aggregate/admin: "true"
rules:
  - apiGroups: ["example.com"]
    resources: ["myresources"]
    verbs: ["get", "list"]
```

Ardından `ansible-playbook playbooks/k8s.yml --tags=security` ile uygulayın.

### 7.2. Mevcut bir role yeni yetki eklemek

`cluster-roles.yaml.j2`'de ilgili ClusterRole'un `rules` kısmına yeni bir rule ekleyin. Herhangi bir binding güncellemesi gerekmez.

### 7.3. Yeni bir aggregated kubeconfig üretmek

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=developer \
  -e namespace=yeni-namespace
```

### 7.4. Yeni bir aggregated rol eklemek

1. `cluster-roles.yaml.j2`'ye yeni aggregated ClusterRole ekleyin:
```yaml
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: aggregated-auditor
aggregationRule:
  clusterRoleSelectors:
    - matchLabels:
        rbac.aggregate/auditor: "true"
rules: []
```
2. İlgili ClusterRole'lara `rbac.aggregate/auditor: "true"` etiketini ekleyin
3. `kubeconfig_roles` listesine yeni bir entry ekleyin
4. Playbook'u çalıştırın

---

## 8. Kubeconfig Üretme

### 8.1. Varsayılan Kubeconfig'ler

`ansible/outputs/k8s/` dizininde aşağıdaki kubeconfig'ler bulunur:

| Dosya | Kaynak | Açıklama |
|---|---|---|
| `admin.conf` | `k8s/master` rolü (fetch) | **Gerçek cluster-admin** — `/etc/kubernetes/admin.conf`, mode **0644** (homelab pragmatizmi) |
| `viewer.conf` | `k8s/security` rolü | aggregated-viewer → RoleBinding |
| `developer.conf` | `k8s/security` rolü | aggregated-developer → RoleBinding |
| `deployer.conf` | `k8s/security` rolü | aggregated-deployer → RoleBinding |
| `monitoring.conf` | `k8s/security` rolü | aggregated-monitoring → **ClusterRoleBinding** |
| `openbao-auth-reviewer.conf` | `k8s/openbao-ops` (otomatik, her `--tags=openbao-ops` koşusunda) | TokenReview köprüsü (sistem conf'i); built-in `system:auth-delegator` + `cluster_wide=true`; mekanizma §8.2.1, ayrıntı [`k8s-design.md`](../architecture/k8s-design.md) §6.8 |

Bu kubeconfig'ler `.gitignore` ile korunur. Tüm SA'lar `kubeconfig-sa` namespace'inde toplanmıştır (her rol için ayrı namespace yerine tek namespace). Monitoring cluster-wide yetkilidir, diğerleri namespace-scoped'dur.

> **Not:** `aggregated-admin` için ayrı bir kubeconfig üretilmez. `admin.conf` zaten cluster admin yetkisi verir, karışıklığı önlemek için security rolü sadece kısıtlı yetkili roller üretir.

### 8.2. İhtiyaca Özel Kubeconfig (gen-kubeconfig.yml)

`playbooks/gen-kubeconfig.yml` playbook'u, herhangi bir ClusterRole + namespace kombinasyonu için anında kubeconfig üretir.

**Ortak motor:** Tüm üretimler aynı task dosyasını kullanır — `roles/k8s/security/tasks/gen-kubeconfig.yml`. İki giriş vardır:

| Giriş | Ne zaman | Kim kullanır |
|---|---|---|
| CLI: `ansible-playbook playbooks/gen-kubeconfig.yml` | İhtiyaç anında | Operatör (elle) |
| Include: `openbao-ops` → `include_role: … tasks_from: gen-kubeconfig.yml` | `k8s.yml --tags=openbao-ops` her koşuda (idempotent) | Otomatik (reviewer conf) |

**Playbook / include çalışma prensibi:**
1. Verilen `role` veya `cluster_role` parametresine bakar
2. `role` verilmişse → `aggregated-{role}` ClusterRole'unu kullanır (ör: role=developer → aggregated-developer)
3. `cluster_role` verilmişse → ClusterRole **adını aynen** kullanır; kaynak bizimki de olabilir, **built-in** de olabilir (`system:auth-delegator` vb.)
4. Hedef namespace'te bir ServiceAccount oluşturur (yoksa create, varsa idempotent)
5. ClusterRole + ServiceAccount arasında RoleBinding (veya cluster_wide=true ise ClusterRoleBinding) oluşturur
6. ServiceAccount'un token'ını alır (SA token Secret)
7. Cluster CA sertifikası + API server URL'i ile kubeconfig yazar (`outputs/k8s/{sa_name}.conf`, mode 0600)

**Kullanım:**

```bash
cd ansible

# 1. Aggregated rol ile — 5 ana rolden biri
# role= seçenekleri: admin, developer, deployer, monitoring, viewer
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=developer \
  -e namespace=redis

# 2. Tekil ClusterRole ile — 9 temel rolden biri
# cluster_role= seçenekleri: pod-reader, pod-log-reader, workload-viewer,
#   full-viewer, pod-operator, workload-operator, config-editor, deployer,
#   monitoring-reader
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=pod-reader \
  -e namespace=myapp

# 3. Özel SA adı ile — çıktı dosyasının adını belirler
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=deployer \
  -e namespace=backend \
  -e sa_name=github-actions
# Çıktı: outputs/k8s/github-actions.conf

# 4. Cluster-wide erişim ile — monitoring rolleri için zorunlu
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=monitoring \
  -e namespace=monitoring \
  -e cluster_wide=true
# ClusterRoleBinding oluşturur, tüm cluster'da geçerlidir

# 5. Tam parametrelerle
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=viewer \
  -e namespace=production \
  -e sa_name=auditor-john \
  -e cluster_wide=false

# 6. Built-in ClusterRole ile — OpenBao TokenReview reviewer conf'i
# (system:auth-delegator K8s'te hazır gelir; biz SA + binding + conf üretiriz.
#  tokenreviews cluster-scope olduğu için cluster_wide=true zorunlu.)
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=system:auth-delegator \
  -e namespace=kube-system \
  -e sa_name=openbao-auth-reviewer \
  -e cluster_wide=true
# Çıktı: outputs/k8s/openbao-auth-reviewer.conf
```

**Parametre tablosu:**

| Parametre | Zorunlu | Default | Açıklama |
|---|---|---|---|
| `role` | Hayır* | — | Aggregated rol adı: admin, developer, deployer, monitoring, viewer |
| `cluster_role` | Hayır* | — | ClusterRole adı: 9 temel rolden biri **veya built-in** (`system:auth-delegator`, `cluster-admin`, …) |
| `namespace` | **Evet** | — | SA ve RoleBinding'in namespace'i (reviewer: `kube-system`) |
| `sa_name` | Hayır | `{rol veya cluster_role}-{namespace}` | ServiceAccount adı, çıktı dosya adını belirler |
| `cluster_wide` | Hayır | false | true ise ClusterRoleBinding (cluster-wide), false ise RoleBinding (namespace-scoped) |

*`role` veya `cluster_role`'den biri ZORUNLUDUR.

**Çıktı dosyası**: `ansible/outputs/k8s/{sa_name}.conf`

#### 8.2.1 OpenBao reviewer conf'i (otomatik yol)

`openbao-auth-reviewer.conf`, elle CLI ile değil, **`k8s/openbao-ops` rolünün ilk task'ı** olarak üretilir (`ansible/roles/k8s/openbao-ops/tasks/main.yml`):

1. `ensure_ready` (OpenBao reachable + unsealed)
2. `include_role: k8s/security, tasks_from: gen-kubeconfig.yml` ile sabit parametreler:
   - `gen_kc_cluster_role: system:auth-delegator` (built-in)
   - `gen_kc_namespace: kube-system`
   - `gen_kc_sa_name: openbao-auth-reviewer`
   - `gen_kc_cluster_wide: true`
   - `gen_kc_filename: {{ openbao_k8s_reviewer_conf }}` → `outputs/k8s/openbao-auth-reviewer.conf`
3. Conf’dan JWT okunur → `auth/kubernetes/config.token_reviewer_jwt` yazılır (`no_log`)

Çalışma tetiği: `ansible-playbook playbooks/k8s.yml --tags=openbao-ops` (k8s.yml akışında `openbao-ops` her koşuda idempotent).

Conf yoksa openbao-ops fail-loud verir ve elle regen komutunu basar (aynı CLI örneği #6). Ne/neden ve TokenReview detayı: [`k8s-design.md`](../architecture/k8s-design.md) §6.8 + [`openbao-architecture-guide.md`](../openbao/openbao-architecture-guide.md) §6.1.

### 8.3. Kubeconfig Kullanımı

```bash
export KUBECONFIG=outputs/k8s/redis-developer.conf

# Namespace belirtmek zorunlu değildir (RoleBinding zaten namespace'e sınırlıdır)
kubectl get pods -n redis
kubectl logs -n redis my-pod

# Ama yetki dışı namespace'e erişemezsiniz
kubectl get pods -n default
# → Error from server (Forbidden): pods is forbidden
```

---

## 9. Yetki Sınırları ve Güvenlik

### 9.1. Namespace Sınırı

Tüm kubeconfig'ler (monitoring hariç) **RoleBinding** ile namespace'e sınırlıdır. Bu şu anlama gelir:

```bash
# redis namespace'i için developer kubeconfig'i
export KUBECONFIG=outputs/k8s/redis-developer.conf

# Redis namespace'inde çalışır ✅
kubectl get pods -n redis

# Başka namespace'te çalışmaz ❌
kubectl get pods -n default
# → Forbidden
```

Bu izolasyon sayesinde aynı cluster'da farkı ekipler farklı namespace'lerde çalışabilir.

### 9.2. Secret Erişimi

| Rol | Secret okuyabilir mi? | Secret yazabilir mi? | Secret silebilir mi? |
|---|---|---|---|
| **admin** | ✅ Evet | ✅ Evet | ✅ Evet |
| **developer** | ❌ Hayır | ❌ Hayır | ❌ Hayır |
| **deployer** | ✅ Evet (okuma) | ✅ Evet (oluşturma/güncelleme) | ❌ Hayır (silemez) |
| **viewer** | ❌ Hayır | ❌ Hayır | ❌ Hayır |
| **monitoring** | ❌ Hayır | ❌ Hayır | ❌ Hayır |

**Neden developer secret okuyamaz?**
Çünkü K8s'te secret'lar base64 encoded olsa da, pod'a mount edildiğinde düz metin olarak görünür. Secret okuyabilen biri, pod'dan secret'ı çıkarabilir. Bu nedenle developer'dan secret erişimi **bilinçli olarak** kısıtlanmıştır.

### 9.3. Pod exec/portforward

| Rol | exec | portforward |
|---|---|---|
| **admin** | ✅ Evet | ✅ Evet |
| **developer** | ✅ Evet | ✅ Evet |
| **deployer** | ❌ Hayır | ❌ Hayır |
| **viewer** | ❌ Hayır | ❌ Hayır |
| **monitoring** | ❌ Hayır | ❌ Hayır |

### 9.4. Aggregated rol içinde bir ClusterRole'ü devre dışı bırakmak

Aggregation'ı etiketler yönetir. Bir ClusterRole'ü bir aggregate'ten çıkarmak için:

```yaml
# Önce: config-editor deployer'a dahil
metadata:
  labels:
    rbac.aggregate/deployer: "true"

# Sonra: deployer'dan çıkar
metadata:
  labels:
    rbac.aggregate/deployer: "false"    # ← etiketi false yap
```
Ya da etiketi tamamen silin. K8s `aggregationRule`, sadece `"true"` değerindeki etiketleri seçer.

### 9.5. Güvenlik Uyarıları

| Risk | Açıklama | Önlem |
|---|---|---|
| **Privilege Escalation** | Bir ServiceAccount'a `config-editor` verirseniz, secret oluşturup okuyabilir. Bu yetkiyi kötüye kullanıp başka bir SA'nin token'ını çalabilir | Secret erişimini sadece ihtiyacı olan rollere verin |
| **Token sızıntısı** | Kubeconfig dosyası token içerir. Token çalınırsa yetkileri kadar erişim sağlanabilir | `ansible/outputs/k8s/` SA conf'ları `.gitignore` + `chmod 0600`; cluster-admin `admin.conf` master'da **0644** (homelab) |
| **Namespace sınırı aşımı** | ClusterRoleBinding (monitoring) cluster genelindedir | Mümkün olduğunca RoleBinding tercih edin |
| **Aggregation otomatik genişlemesi** | Yeni bir ClusterRole ekleyip yanlış label verirseniz, otomatik olarak aggregate'e dahil olur | Yeni roller eklerken label'ları dikkatlice seçin |

---

## 10. Sık Kullanım Senaryoları

### Senaryo 1: Geliştirici Redis namespace'inde çalışıyor

Bir geliştirici Redis uygulaması üzerinde çalışıyor. Pod'ları görmeli, log okumalı, exec ile hata ayıklamalı. Ama production secret'larına erişmemeli ve deployment yapmamalı.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=developer \
  -e namespace=redis
# Çıktı: outputs/k8s/developer-redis.conf
```

```bash
export KUBECONFIG=outputs/k8s/developer-redis.conf

kubectl get pods -n redis                          # ✅
kubectl logs -f deployment/redis -n redis          # ✅
kubectl exec -it redis-pod -n redis -- /bin/sh     # ✅
kubectl get secrets -n redis                       # ❌ Forbidden
kubectl delete pod redis-pod -n redis              # ✅ (pod-operator sayesinde)
kubectl get pods -n default                        # ❌ Forbidden
```

### Senaryo 2: CI/CD pipeline backend namespace'ine deploy ediyor

GitHub Actions backend uygulamasını deploy ediyor. Deployment oluşturmalı, service güncellemeli, configmap ve secret yönetmeli. Ama pod'lara exec girmemeli.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=deployer \
  -e namespace=backend \
  -e sa_name=github-actions
# Çıktı: outputs/k8s/github-actions.conf
```

```bash
export KUBECONFIG=outputs/k8s/github-actions.conf

kubectl apply -f deployment.yaml -n backend        # ✅
kubectl create configmap app-config -n backend     # ✅
kubectl create secret generic db-creds -n backend  # ✅
kubectl rollout restart deployment/app -n backend   # ✅
kubectl exec -it pod -n backend -- /bin/sh          # ❌ Forbidden
kubectl delete secret db-creds -n backend           # ❌ Forbidden
kubectl get nodes                                   # ❌ Forbidden
```

### Senaryo 3: Monitoring ekibi tüm cluster'ı izliyor

Prometheus tüm node'ların metriklerini toplamalı. Prometheus cluster-wide okuma yetkisine ihtiyaç duyar.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=monitoring \
  -e namespace=monitoring \
  -e cluster_wide=true
# Çıktı: outputs/k8s/monitoring-monitoring.conf
```

```bash
export KUBECONFIG=outputs/k8s/monitoring-monitoring.conf

kubectl get nodes                                   # ✅
kubectl top nodes                                   # ✅
kubectl get pods --all-namespaces                   # ✅
kubectl create deployment test -n default           # ❌ Forbidden
kubectl get secrets -n kube-system                  # ❌ Forbidden
```

### Senaryo 4: Dış denetçiye sadece pod listesi

Bir güvenlik denetçisi sadece production namespace'inde hangi pod'ların çalıştığını görmeli. Başka hiçbir şeye erişmemeli.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=pod-reader \
  -e namespace=production \
  -e sa_name=auditor
# Çıktı: outputs/k8s/auditor.conf
```

```bash
export KUBECONFIG=outputs/k8s/auditor.conf

kubectl get pods -n production                      # ✅
kubectl logs pod -n production                      # ❌ Forbidden
kubectl get services -n production                  # ❌ Forbidden
kubectl get pods -n default                         # ❌ Forbidden
```

### Senaryo 5: Admin yeni bir namespace ayarlıyor

Yeni bir `backend-v2` namespace'i açıldı. Admin bu namespace'te tam yetkiye sahip olmalı.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=admin \
  -e namespace=backend-v2 \
  -e sa_name=devops-lead
# Çıktı: outputs/k8s/devops-lead.conf
```

```bash
export KUBECONFIG=outputs/k8s/devops-lead.conf

kubectl get secrets -n backend-v2                   # ✅
kubectl delete pod -n backend-v2 --all              # ✅
kubectl create rolebinding extra -n backend-v2      # ✅
kubectl delete namespace backend-v2                 # ❌ Forbidden (namespace'i silemez)
```

### Senaryo 6: Geliştiriciye exec yetkisi vermeden log okuma

Bir geliştirici sadece log okumalı, pod içine girmemeli.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=viewer \
  -e namespace=staging \
  -e sa_name=dev-viewer
# Çıktı: outputs/k8s/dev-viewer.conf
```

```bash
export KUBECONFIG=outputs/k8s/dev-viewer.conf

kubectl logs -f deployment/api -n staging           # ✅
kubectl exec -it pod -n staging -- /bin/sh           # ❌ Forbidden
kubectl get pods -n staging                          # ✅
```

---

> **Uyarı**: `ansible/outputs/` dizini `.gitignore` ile korunur, repo'ya gönderilmez. Her kubeconfig bir ServiceAccount token'ı içerir. Token çalınırsa, token'ın yetkili olduğu namespace'te tanımlı işlemler yapılabilir. Token'ları güvenli bir ortamda saklayın.
