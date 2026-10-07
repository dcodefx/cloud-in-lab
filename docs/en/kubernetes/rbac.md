# K8s RBAC Roles and Kubeconfig Management

## Table of Contents

1. [Introduction: What Is RBAC?](#1-introduction-what-is-rbac)
2. [Built-in Roles](#2-built-in-roles)
3. [Custom ClusterRoles — 9 Core Roles](#3-custom-clusterroles--9-core-roles)
4. [Aggregated Roles — 5 Roles](#4-aggregated-roles--5-roles)
5. [Aggregation Logic in Detail](#5-aggregation-logic-in-detail)
6. [Adding Custom ClusterRoles (On-the-fly)](#6-adding-custom-clusterroles-on-the-fly)
7. [Extending Existing Roles](#7-extending-existing-roles)
8. [Generating Kubeconfigs](#8-generating-kubeconfigs)
9. [Permission Boundaries and Security](#9-permission-boundaries-and-security)
10. [Common Usage Scenarios](#10-common-usage-scenarios)

---

## 1. Introduction: What Is RBAC?

In Kubernetes, RBAC (Role-Based Access Control) is the authorization mechanism that determines who can access which resources. It consists of four fundamental objects:

| Object | Scope | What it does |
|---|---|---|
| **Role** | Namespace | Access rules for resources within a single namespace |
| **ClusterRole** | Cluster-wide | Access rules for resources across the entire cluster, or namespace-specific rules |
| **RoleBinding** | Namespace | Binds a Role/ClusterRole to a user/SA within a namespace |
| **ClusterRoleBinding** | Cluster-wide | Binds a ClusterRole to a user/SA across the entire cluster |

**Important distinction**: If you bind a ClusterRole with a **RoleBinding**, the permissions apply only within that namespace. If you bind it with a **ClusterRoleBinding**, they apply across the entire cluster. In this project, all roles except monitoring use RoleBinding.

---

## 2. Built-in Roles

Kubernetes ships with 4 built-in ClusterRoles by default. These come ready-made with `kubectl`; we don't define them ourselves:

| Built-in Role | Scope | What it can do | What it cannot do |
|---|---|---|---|
| `view` | Namespace | Can read most resources (get/list/watch) | Cannot read Secrets, pod/log, or RBAC resources |
| `edit` | Namespace | Can create/update resources | Cannot read Secrets, cannot manage RBAC |
| `admin` | Namespace | Full authority within the namespace | Cannot delete the namespace itself, cannot manage ResourceQuota |
| `cluster-admin` | Cluster | **Unrestricted** — can do anything | — |

These roles are not used directly in this project. Instead, more fine-grained **custom roles** are defined. The shortcomings of the built-in roles:

- `view` → **Cannot read Secrets** (but sometimes an admin needs to see secrets)
- `edit` → **Cannot read Secrets** (but a deployer needs to read secrets)
- `admin` → **Too broad within the namespace** (allows RBAC management, which is a privilege escalation risk)
- All of them **have aggregation labels** (like `rbac.authorization.k8s.io/aggregate-to-view: "true"`) but we use our own labeling system

Unlike the built-in roles, the custom roles in this project:

| Feature | Built-in `edit` | Our `deployer` |
|---|---|---|
| Secret read | ❌ | ✅ (limited) |
| Pod exec | ✅ (indirectly) | ❌ |
| Secret write | ❌ | ✅ (limited) |
| RBAC management | ❌ | ❌ |

---

## 3. Custom ClusterRoles — 9 Core Roles

These roles are defined in `ansible/roles/k8s/security/templates/cluster-roles.yaml.j2`. Each one focuses on a single responsibility (Single Responsibility). Each can be used individually **or** combined via aggregation.

### 3.1. Read-only Roles

#### `pod-reader`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```
**What it does**: Lists pods only. No log reading, no exec. The most restricted role.
**Where it's used**: External auditors, read-only panel dashboards.
**Built-in equivalent**: A subset of the `view` role (view sees far more).

#### `pod-log-reader`
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
```
**What it does**: Reads pods and their logs.
**Where it's used**: Log aggregation systems, debugging tools.
**Important**: `pods/log` is a separate subresource. `pod-reader` does not cover it.

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
**What it does**: Views all workload resources. Does not see Secrets.
**Built-in equivalent**: Close to the `view` role, but view covers more resource types (e.g., horizontalpodautoscalers).

#### `full-viewer`
```yaml
rules:
  # ↑ All permissions of workload-viewer + pods/log + the following
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
```
**What it does**: Sees everything including Secrets and pod logs. Cannot write.
**When it's used**: Admin-level read access. Seeing Secrets is not possible with `view`.

---

### 3.2. Write Roles (Write/Operate)

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
**What it does**: Full control over pods. Creating, deleting pods, exec'ing into them, port-forwarding. The `exec` and `portforward` subresources are defined separately — normally `create` permission on `pods` does not cover these subresources.
**When it's used**: Situations where developers need to get inside a pod to debug.

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
**What it does**: Can update and scale Deployments, StatefulSets, DaemonSets.
**Limitations**: Does not include permission to delete a Deployment. This is a deliberate restriction — deleting a deployment requires higher privileges.

#### `config-editor`
```yaml
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```
**What it does**: Full management of ConfigMaps and Secrets (CRUD).
**Risk**: Can delete Secrets → use with caution.
**When it's used**: Tools that manage secrets, CI/CD pipelines.

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
**What it does**: The minimum permission needed to deploy an application. Cannot create pods (does it through deployments), cannot delete secrets (can only create and update them).
**Difference from built-in `edit`**: Can read and create Secrets. But cannot exec into pods.
**Ideal for CI/CD**: Tools like GitHub Actions, GitLab CI, ArgoCD deploy with this role.

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
**What it does**: Reads node-level metrics (CPU, memory, disk). Nodes are cluster-scoped resources, which is why this role requires a ClusterRoleBinding.
**Where it's used**: Monitoring tools like Prometheus, Grafana, kube-state-metrics.
**Built-in equivalent**: None. Built-in roles do not grant access to nodes.

---

## 4. Aggregated Roles — 5 Roles

These roles are defined in `cluster-roles.yaml.j2` with `aggregationRule`. They have no rules of their own — K8s fills them in automatically based on labels.

### aggregated-viewer
**Contains**: `pod-reader` + `pod-log-reader` + `workload-viewer`
**What it can do**:
- Sees pods (`get pods`)
- Reads logs (`logs -f`)
- Sees Service, deployment, configmap, pvc, events
**What it cannot do**:
- Cannot read Secrets
- Cannot create/delete pods
- Cannot exec into pods

**Comparison with built-in `view`**:
- `view` → sees more resource types (including HPA, LimitRange, ResourceQuota)
- Our `viewer` → sees fewer resources but can read pod logs (`view` cannot)

### aggregated-developer
**Contains**: `pod-reader` + `pod-log-reader` + `workload-viewer` + `pod-operator` + `workload-operator`
**What it can do**:
- All viewing permissions
- Create/delete pods
- Update, scale deployments
- Exec into pods
**What it cannot do**:
- Cannot read Secrets
- Cannot create Secrets/configmaps
- Cannot create Services

**Comparison with built-in `edit`**:
- `edit` → can create service/deployment/configmap/secret (but cannot read secrets)
- Our `developer` → can exec into pods (edit cannot), but cannot create service/configmap

**This difference is deliberate**: A developer needs to debug inside a pod, not deploy. Deployment is the job of CI/CD.

### aggregated-deployer
**Contains**: `config-editor` + `deployer`
**What it can do**:
- Create/update/delete deployments
- Create/update/delete services
- Full ConfigMap management
- Read, create, update Secrets (cannot delete)
**What it cannot do**:
- Cannot exec into pods
- Cannot create pods (does it through deployments)
- Cannot see nodes

### aggregated-admin
**Contains**: All 9 roles (including monitoring-reader)
**What it can do**: Everything within the namespace
**What it cannot do**: Cannot delete the namespace, cannot manage cluster-scoped resources
**Built-in equivalent**: Similar to the `admin` role but without cluster-scoped RBAC management

### aggregated-monitoring
**Contains**: `monitoring-reader`
**Binding type**: ClusterRoleBinding (because nodes are cluster-scoped)
**What it can do**: Reads all nodes, pods, metrics
**What it cannot do**: Cannot write anything

---

## 5. Aggregation Logic in Detail

Thanks to Kubernetes's `aggregationRule` feature, a ClusterRole can automatically include other ClusterRoles via labels.

### How does it work?

A ClusterRole contains an **aggregationRule** and leaves `rules: []` empty. K8s finds all ClusterRoles matching the **clusterRoleSelectors** and merges their rules.

### Example: How aggregated-developer is formed

Step 1: Base roles are labeled
```yaml
# pod-reader → label: developer
kind: ClusterRole
metadata:
  name: pod-reader
  labels:
    rbac.aggregate/developer: "true"   # ← aggregation label
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```

Step 2: The aggregated role selects this label
```yaml
kind: ClusterRole
metadata:
  name: aggregated-developer
aggregationRule:
  clusterRoleSelectors:
    - matchLabels:
        rbac.aggregate/developer: "true"   # ← pod-reader, workload-viewer, pod-operator, workload-operator
rules: []   # ← K8s fills this in automatically
```

Step 3: K8s collects ALL ClusterRoles with the label `rbac.aggregate/developer: "true"` and merges their rules under `aggregated-developer`.

### Why does a role belong to multiple aggregates?

```yaml
kind: ClusterRole
metadata:
  name: config-editor
  labels:
    rbac.aggregate/deployer: "true"   # included in deployer
    rbac.aggregate/admin: "true"      # also included in admin
```

This way `config-editor`:

- Can be used on its own (`cluster_role=config-editor`)
- Can be part of the `deployer` aggregate
- Can be part of the `admin` aggregate

The same ClusterRole can belong to **multiple** aggregates at the same time.

### Advantage of aggregation

When you want to **add a new permission**:

1. You write a new ClusterRole
2. You specify with labels which aggregates it should belong to
3. K8s automatically adds it to the relevant aggregated roles
4. You don't need to update existing bindings

**Without aggregation**:
You would have to manually update each aggregate and add separate rules to each one.

---

## 6. Adding Custom ClusterRoles (On-the-fly)

In addition to the existing 9 roles, you can define new roles in `inventory/group_vars/all/all.yml`. You don't need to touch the template.

### 6.1. With a single rule

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

### 6.2. With multiple rules for the same role (same name)

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

Same `name` → single ClusterRole, multiple rules. `aggregates` are merged automatically (developer + admin).

### 6.3. Applying

```bash
ansible-playbook playbooks/k8s.yml --tags=security
```

### 6.4. Kubeconfig for a custom role

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=redis-operator \
  -e namespace=redis
```

---

## 7. Extending Existing Roles

### 7.1. Adding a new ClusterRole (to the template)

Add a new block to the `cluster-roles.yaml.j2` file:

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

Then apply it with `ansible-playbook playbooks/k8s.yml --tags=security`.

### 7.2. Adding a new permission to an existing role

Add a new rule to the relevant ClusterRole's `rules` section in `cluster-roles.yaml.j2`. No binding update is needed.

### 7.3. Generating a new aggregated kubeconfig

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=developer \
  -e namespace=new-namespace
```

### 7.4. Adding a new aggregated role

1. Add a new aggregated ClusterRole to `cluster-roles.yaml.j2`:
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
2. Add the label `rbac.aggregate/auditor: "true"` to the relevant ClusterRoles
3. Add a new entry to the `kubeconfig_roles` list
4. Run the playbook

---

## 8. Generating Kubeconfigs

### 8.1. Default Kubeconfigs

The following kubeconfigs are found in the `ansible/outputs/k8s/` directory:

| File | Source | Description |
|---|---|---|
| `admin.conf` | `k8s/master` role (fetch) | **Real cluster-admin** — `/etc/kubernetes/admin.conf`, mode **0644** (homelab pragmatism) |
| `viewer.conf` | `k8s/security` role | aggregated-viewer → RoleBinding |
| `developer.conf` | `k8s/security` role | aggregated-developer → RoleBinding |
| `deployer.conf` | `k8s/security` role | aggregated-deployer → RoleBinding |
| `monitoring.conf` | `k8s/security` role | aggregated-monitoring → **ClusterRoleBinding** |
| `openbao-auth-reviewer.conf` | `k8s/openbao-ops` (automatic, on every `--tags=openbao-ops` run) | TokenReview bridge (system conf); built-in `system:auth-delegator` + `cluster_wide=true`; mechanism in §8.2.1, details in [`k8s-design.md`](../architecture/k8s-design.md) §6.8 |

These kubeconfigs are protected by `.gitignore`. All SAs are collected in the `kubeconfig-sa` namespace (a single namespace instead of a separate one for each role). Monitoring is cluster-wide; the others are namespace-scoped.

> **Note:** No separate kubeconfig is generated for `aggregated-admin`. `admin.conf` already grants cluster admin privileges; to avoid confusion, the security role only generates restricted-privilege kubeconfigs.

### 8.2. Purpose-built Kubeconfig (gen-kubeconfig.yml)

The `playbooks/gen-kubeconfig.yml` playbook generates a kubeconfig on the spot for any ClusterRole + namespace combination.

**Shared engine:** All generation workflows use the same task file — `roles/k8s/security/tasks/gen-kubeconfig.yml`. There are two entry points:

| Entry | When | Who uses it |
|---|---|---|
| CLI: `ansible-playbook playbooks/gen-kubeconfig.yml` | On demand | Operator (manually) |
| Include: `openbao-ops` → `include_role: … tasks_from: gen-kubeconfig.yml` | On every `k8s.yml --tags=openbao-ops` run (idempotent) | Automatic (reviewer conf) |

**How the playbook / include works:**
1. Looks at the given `role` or `cluster_role` parameter
2. If `role` is given → uses the `aggregated-{role}` ClusterRole (e.g., role=developer → aggregated-developer)
3. If `cluster_role` is given → uses the ClusterRole **name as-is**; the source may be ours or a **built-in** one (`system:auth-delegator`, etc.)
4. Creates a ServiceAccount in the target namespace (create if missing, idempotent if present)
5. Creates a RoleBinding (or ClusterRoleBinding if cluster_wide=true) between the ClusterRole and the ServiceAccount
6. Retrieves the ServiceAccount's token (SA token Secret)
7. Writes the kubeconfig with the cluster CA certificate + API server URL (`outputs/k8s/{sa_name}.conf`, mode 0600)

**Usage:**

```bash
cd ansible

# 1. With an aggregated role — one of the 5 main roles
# role= options: admin, developer, deployer, monitoring, viewer
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=developer \
  -e namespace=redis

# 2. With an individual ClusterRole — one of the 9 core roles
# cluster_role= options: pod-reader, pod-log-reader, workload-viewer,
#   full-viewer, pod-operator, workload-operator, config-editor, deployer,
#   monitoring-reader
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=pod-reader \
  -e namespace=myapp

# 3. With a custom SA name — determines the output file name
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=deployer \
  -e namespace=backend \
  -e sa_name=github-actions
# Output: outputs/k8s/github-actions.conf

# 4. With cluster-wide access — mandatory for monitoring roles
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=monitoring \
  -e namespace=monitoring \
  -e cluster_wide=true
# Creates a ClusterRoleBinding, valid across the entire cluster

# 5. With full parameters
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=viewer \
  -e namespace=production \
  -e sa_name=auditor-john \
  -e cluster_wide=false

# 6. With a built-in ClusterRole — OpenBao TokenReview reviewer conf
# (system:auth-delegator ships with K8s; we generate the SA + binding + conf.
#  Since tokenreviews is cluster-scope, cluster_wide=true is mandatory.)
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=system:auth-delegator \
  -e namespace=kube-system \
  -e sa_name=openbao-auth-reviewer \
  -e cluster_wide=true
# Output: outputs/k8s/openbao-auth-reviewer.conf
```

**Parameter table:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `role` | No* | — | Aggregated role name: admin, developer, deployer, monitoring, viewer |
| `cluster_role` | No* | — | ClusterRole name: one of the 9 core roles **or built-in** (`system:auth-delegator`, `cluster-admin`, …) |
| `namespace` | **Yes** | — | Namespace of the SA and RoleBinding (reviewer: `kube-system`) |
| `sa_name` | No | `{role or cluster_role}-{namespace}` | ServiceAccount name; determines the output file name |
| `cluster_wide` | No | false | If true, ClusterRoleBinding (cluster-wide); if false, RoleBinding (namespace-scoped) |

*One of `role` or `cluster_role` is MANDATORY.

**Output file**: `ansible/outputs/k8s/{sa_name}.conf`

#### 8.2.1 OpenBao reviewer conf (automatic path)

`openbao-auth-reviewer.conf` is generated not via manual CLI, but as the **first task of the `k8s/openbao-ops` role** (`ansible/roles/k8s/openbao-ops/tasks/main.yml`):

1. `ensure_ready` (OpenBao reachable + unsealed)
2. `include_role: k8s/security, tasks_from: gen-kubeconfig.yml` with fixed parameters:
   - `gen_kc_cluster_role: system:auth-delegator` (built-in)
   - `gen_kc_namespace: kube-system`
   - `gen_kc_sa_name: openbao-auth-reviewer`
   - `gen_kc_cluster_wide: true`
   - `gen_kc_filename: {{ openbao_k8s_reviewer_conf }}` → `outputs/k8s/openbao-auth-reviewer.conf`
3. The JWT is read from the conf → written to `auth/kubernetes/config.token_reviewer_jwt` (`no_log`)

**Trigger:** `ansible-playbook playbooks/k8s.yml --tags=openbao-ops` (in the k8s.yml flow, `openbao-ops` is idempotent on every run).

If the conf is missing, openbao-ops fails loudly and prints the manual regen command (same CLI example #6). What/why and TokenReview details: [`k8s-design.md`](../architecture/k8s-design.md) §6.8 + [`openbao-architecture-guide.md`](../openbao/openbao-architecture-guide.md) §6.1.

### 8.3. Using a Kubeconfig

```bash
export KUBECONFIG=outputs/k8s/redis-developer.conf

# Specifying the namespace is not mandatory (the RoleBinding is already scoped to the namespace)
kubectl get pods -n redis
kubectl logs -n redis my-pod

# But you cannot access a namespace outside your permissions
kubectl get pods -n default
# → Error from server (Forbidden): pods is forbidden
```

---

## 9. Permission Boundaries and Security

### 9.1. Namespace Boundary

All kubeconfigs (except monitoring) are scoped to a namespace via **RoleBinding**. This means:

```bash
# developer kubeconfig for the redis namespace
export KUBECONFIG=outputs/k8s/redis-developer.conf

# Works in the redis namespace ✅
kubectl get pods -n redis

# Does not work in another namespace ❌
kubectl get pods -n default
# → Forbidden
```

Thanks to this isolation, different teams can work in different namespaces on the same cluster.

### 9.2. Secret Access

| Role | Can read Secrets? | Can write Secrets? | Can delete Secrets? |
|---|---|---|---|
| **admin** | ✅ Yes | ✅ Yes | ✅ Yes |
| **developer** | ❌ No | ❌ No | ❌ No |
| **deployer** | ✅ Yes (read) | ✅ Yes (create/update) | ❌ No (cannot delete) |
| **viewer** | ❌ No | ❌ No | ❌ No |
| **monitoring** | ❌ No | ❌ No | ❌ No |

**Why can't a developer read secrets?**
Because even though secrets are base64-encoded in K8s, they appear in plaintext when mounted into a pod. Anyone who can read a secret can extract it from a pod. This is why secret access for developers is **deliberately** restricted.

### 9.3. Pod exec/portforward

| Role | exec | portforward |
|---|---|---|
| **admin** | ✅ Yes | ✅ Yes |
| **developer** | ✅ Yes | ✅ Yes |
| **deployer** | ❌ No | ❌ No |
| **viewer** | ❌ No | ❌ No |
| **monitoring** | ❌ No | ❌ No |

### 9.4. Disabling a ClusterRole within an aggregated role

Labels control aggregation. To remove a ClusterRole from an aggregate:

```yaml
# Before: config-editor is included in deployer
metadata:
  labels:
    rbac.aggregate/deployer: "true"

# After: removed from deployer
metadata:
  labels:
    rbac.aggregate/deployer: "false"    # ← set the label to false
```
Or delete the label entirely. K8s's `aggregationRule` only selects labels with the value `"true"`.

### 9.5. Security Warnings

| Risk | Description | Mitigation |
|---|---|---|
| **Privilege Escalation** | If you give `config-editor` to a ServiceAccount, it can create and read secrets. This permission can be abused to steal another SA's token | Grant secret access only to roles that need it |
| **Token leakage** | A kubeconfig file contains a token. If the token is stolen, access up to its permissions is granted | `ansible/outputs/k8s/` SA confs are in `.gitignore` + `chmod 0600`; cluster-admin `admin.conf` is **0644** on the master (homelab) |
| **Namespace boundary crossing** | ClusterRoleBinding (monitoring) is cluster-wide | Prefer RoleBinding whenever possible |
| **Automatic aggregation expansion** | If you add a new ClusterRole and give it the wrong label, it automatically joins an aggregate | Choose labels carefully when adding new roles |

---

## 10. Common Usage Scenarios

### Scenario 1: A developer works in the Redis namespace

A developer is working on the Redis application. They need to see pods, read logs, and debug via exec. But they must not access production secrets and must not deploy.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=developer \
  -e namespace=redis
# Output: outputs/k8s/developer-redis.conf
```

```bash
export KUBECONFIG=outputs/k8s/developer-redis.conf

kubectl get pods -n redis                          # ✅
kubectl logs -f deployment/redis -n redis          # ✅
kubectl exec -it redis-pod -n redis -- /bin/sh     # ✅
kubectl get secrets -n redis                       # ❌ Forbidden
kubectl delete pod redis-pod -n redis              # ✅ (thanks to pod-operator)
kubectl get pods -n default                        # ❌ Forbidden
```

### Scenario 2: A CI/CD pipeline deploys to the backend namespace

GitHub Actions is deploying the backend application. It must create deployments, update services, manage configmaps and secrets. But it must not exec into pods.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=deployer \
  -e namespace=backend \
  -e sa_name=github-actions
# Output: outputs/k8s/github-actions.conf
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

### Scenario 3: The monitoring team watches the entire cluster

Prometheus needs to collect metrics from all nodes. Prometheus requires cluster-wide read access.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=monitoring \
  -e namespace=monitoring \
  -e cluster_wide=true
# Output: outputs/k8s/monitoring-monitoring.conf
```

```bash
export KUBECONFIG=outputs/k8s/monitoring-monitoring.conf

kubectl get nodes                                   # ✅
kubectl top nodes                                   # ✅
kubectl get pods --all-namespaces                   # ✅
kubectl create deployment test -n default           # ❌ Forbidden
kubectl get secrets -n kube-system                  # ❌ Forbidden
```

### Scenario 4: Pod list only for an external auditor

A security auditor should only see which pods are running in the production namespace. They must not access anything else.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e cluster_role=pod-reader \
  -e namespace=production \
  -e sa_name=auditor
# Output: outputs/k8s/auditor.conf
```

```bash
export KUBECONFIG=outputs/k8s/auditor.conf

kubectl get pods -n production                      # ✅
kubectl logs pod -n production                      # ❌ Forbidden
kubectl get services -n production                  # ❌ Forbidden
kubectl get pods -n default                         # ❌ Forbidden
```

### Scenario 5: An admin sets up a new namespace

A new `backend-v2` namespace has been opened. The admin must have full authority in this namespace.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=admin \
  -e namespace=backend-v2 \
  -e sa_name=devops-lead
# Output: outputs/k8s/devops-lead.conf
```

```bash
export KUBECONFIG=outputs/k8s/devops-lead.conf

kubectl get secrets -n backend-v2                   # ✅
kubectl delete pod -n backend-v2 --all              # ✅
kubectl create rolebinding extra -n backend-v2      # ✅
kubectl delete namespace backend-v2                 # ❌ Forbidden (cannot delete the namespace)
```

### Scenario 6: Log reading for a developer without exec permission

A developer should only read logs, not get inside a pod.

```bash
ansible-playbook playbooks/gen-kubeconfig.yml \
  -e role=viewer \
  -e namespace=staging \
  -e sa_name=dev-viewer
# Output: outputs/k8s/dev-viewer.conf
```

```bash
export KUBECONFIG=outputs/k8s/dev-viewer.conf

kubectl logs -f deployment/api -n staging           # ✅
kubectl exec -it pod -n staging -- /bin/sh           # ❌ Forbidden
kubectl get pods -n staging                          # ✅
```

---

> **Warning**: The `ansible/outputs/` directory is protected by `.gitignore` and is not committed to the repo. Every kubeconfig contains a ServiceAccount token. If a token is stolen, the operations defined in the token's authorized namespace can be performed. Store tokens in a secure environment.

---
