# Dify on Azure — AKS 架構說明與費用估算

## 架構概覽

```
Internet
    │
    ▼
[nginx Ingress Controller]  ─── Public IP（AKS 自動建立 Standard LB）
    │  HTTP 80 / HTTPS 443
    │  （透過 Helm 部署於 AKS 內）
    │
    ▼
[AKS Cluster]  aks-dify-<hash>
    │  AKSSubnet: 10.99.2.0/23（Azure CNI，Pod 直接取得 VNet IP）
    │  Node pool: Standard_D4s_v3 × 2~10（CPU auto-scale）
    │
    │  Kubernetes Deployments：
    │    api        — Dify API server（port 5001）
    │    worker     — Celery worker
    │    web        — Next.js 前端（port 3000）
    │    sandbox    — 程式碼執行沙箱（port 8194）
    │    ssrf-proxy — Squid SSRF 防護（port 3128）
    │    plugin     — Plugin Daemon（port 5002）
    │
    │  Kubernetes Services：
    │    ClusterIP（內部）: api, worker, web, sandbox, ssrf-proxy, plugin
    │    Ingress（外部）: nginx Ingress → web / api 路由
    │
    ├── [Azure Files CSI Driver]（AKS 內建）
    │     PersistentVolume: nginx 設定、sandbox 依賴、ssrfproxy 設定、plugin 資料
    │
    ├── [PostgreSQL Flexible Server]  Standard_B1ms, 32 GB
    │     PostgresSubnet: 10.99.4.0/24（VNet delegation）
    │     databases: dify, vector（pgvector）
    │
    ├── [Azure Cache for Redis]  Standard C0（250 MB）
    │     Private Endpoint → PrivateLinkSubnet: 10.99.0.0/24
    │
    └── [Storage Account]  Standard LRS
          Azure Blob — Dify 上傳檔案
          Azure Files — 設定檔共享（透過 CSI Driver 掛載）
          Private Endpoint → PrivateLinkSubnet
```

---

## 網路拓撲

| Subnet | CIDR | 用途 |
|--------|------|------|
| PrivateLinkSubnet | 10.99.0.0/24 | Redis / Storage Private Endpoint |
| AKSSubnet | 10.99.2.0/23 | AKS 節點 + Pod IP（Azure CNI，/23 = 512 IP） |
| PostgresSubnet | 10.99.4.0/24 | PostgreSQL Flexible Server（VNet delegation） |

> **Azure CNI 說明**：每個 Pod 直接從 AKSSubnet 取得 VNet IP，可直接連線 Private Endpoint（Redis、Storage）及 PostgreSQL，無需額外路由設定。

---

## 資源清單

### Bicep 管理（基礎設施）

| 資源 | SKU / 規格 | 說明 |
|------|-----------|------|
| AKS Cluster `aks-dify-<hash>` | Standard_D4s_v3 × 2~10 nodes | Azure CNI，System-assigned identity，CPU auto-scale |
| PostgreSQL Flexible Server | Standard_B1ms, 32 GB | 主要 DB + pgvector，VNet 整合，SSL required |
| Azure Cache for Redis | Standard C0（250 MB） | Session cache / Celery broker，Private Endpoint |
| Storage Account | Standard LRS | Blob（Dify 儲存）+ Azure Files（設定共享） |

### Helm / kubectl 管理（應用程式）

| 元件 | 部署方式 | 說明 |
|------|---------|------|
| nginx Ingress Controller | `helm install ingress-nginx` | 建立 Public IP 及 LB 規則 |
| Dify api / worker / web | `kubectl apply` 或 Helm chart | Deployment + ClusterIP Service |
| sandbox / ssrf-proxy / plugin | `kubectl apply` 或 Helm chart | Deployment + ClusterIP Service |
| Kubernetes Secrets | `kubectl create secret` | DB 密碼、Redis key、Storage key |
| PersistentVolumeClaim | Azure Files CSI Driver | 設定檔掛載（nginx、sandbox、ssrfproxy、plugin） |

---

## Auto-Scale 規則

| 項目 | 設定 |
|------|------|
| 類型 | AKS Cluster Autoscaler（節點層級） |
| 最小節點數 | 2 |
| 最大節點數 | 10 |
| 觸發條件 | Pod 無法排程（資源不足）→ 新增節點 |
| 縮減條件 | 節點資源使用率低且 Pod 可遷移 |

> 應用層可另外設定 **Horizontal Pod Autoscaler（HPA）** 依 CPU/Memory 自動調整 Pod 數量，實現節點與 Pod 雙層擴展。

---

## 部署後步驟

```bash
# 1. 取得 kubeconfig
az aks get-credentials --resource-group <rg> --name <aksClusterName>

# 2. 安裝 nginx Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# 3. 建立 Kubernetes Secrets（DB、Redis、Storage 金鑰）
kubectl create secret generic dify-secrets \
  --from-literal=DB_PASSWORD=<pgsql-password> \
  --from-literal=REDIS_PASSWORD=<redis-key> \
  --from-literal=STORAGE_KEY=<storage-key>

# 4. 套用 Dify K8s manifests 或 Helm chart
kubectl apply -f dify-manifests/
# 或
helm install dify ./dify-chart

# 5. 確認 Ingress 取得 Public IP
kubectl get ingress -n dify
```

---

## 費用估算（Japan East，隨用隨付）

### 最小規模（2 AKS nodes）

| 資源 | 規格 | 月費（USD） |
|------|------|-----------|
| AKS Node Standard_D4s_v3 × 2 | ~$0.248/hr × 2 × 730hr | ~$362 |
| AKS Node OS Disk Standard_LRS × 2 | 30 GB × 2 | ~$3 |
| AKS 管理費用 | Standard tier | ~$73 |
| nginx Ingress Public IP | Standard Static | ~$4 |
| nginx Ingress LB（AKS 自動建立） | Standard | ~$18 |
| PostgreSQL Standard_B1ms + 32 GB | compute + storage | ~$30 |
| Redis Standard C0 | ~$0.032/hr × 730hr | ~$23 |
| Storage Account | Blob + Azure Files | ~$5 |
| **合計** | | **~$518 / 月** |

> AKS Standard tier 管理費 $0.10/hr/cluster = ~$73/月。若使用 Free tier 則無管理費，但 SLA 保障較低。

### Auto-Scale 情境比較

| 情境 | AKS 節點數 | 估算月費 |
|------|-----------|---------|
| 最小（off-peak） | 2 台 | ~$518 |
| 中度負載 | 4 台 | ~$880 |
| 高峰 | 10 台 | ~$1,970 |

> AKS 每增加 1 個 Standard_D4s_v3 節點約增加 $181/月（PAYG）。

---

## 節費建議

### 1. Reserved Instances

| 資源 | PAYG | 1年 RI | 節省 |
|------|------|--------|------|
| D4s_v3（每節點） | $0.248/hr | ~$0.161/hr | ~35% |

2 節點採 RI：~$235/月（vs $362 PAYG），整體省約 **$125/月**，降至 **~$393/月**。

### 2. Free Tier AKS

將 AKS 從 Standard 改為 Free tier 可省 **$73/月**（無 SLA 保障，適合非正式環境）。

### 3. Spot Instance Node Pool

為 worker / sandbox 等容錯性高的服務加設 Spot node pool：
- Spot 價格約為 On-demand 的 **20~40%**
- 需處理 Spot 中斷（eviction）

---

## 三種架構完整比較

| 比較項目 | ACA 架構 | VM（VMSS）架構 | AKS 架構 |
|---------|---------|--------------|---------|
| **Branch** | `main` | `vm_test` | `aks_test` |
| **應用執行環境** | Azure Container Apps | Docker Compose on VMSS | Kubernetes on AKS |
| **水平擴展** | Container App auto-scale（秒級） | VMSS CPU auto-scale（分鐘級） | Cluster Autoscaler + HPA（分鐘級） |
| **新增 instance 時間** | 秒級 | 3~5 分鐘（VM 開機 + cloud-init） | 1~3 分鐘（節點 + Pod 排程） |
| **Ingress** | ACA External Ingress（全托管） | Public LB → nginx VM | nginx Ingress Controller（Helm） |
| **設定檔管理** | Azure Files + ACA Volume Mount | Azure Files CIFS Mount（cloud-init） | Azure Files CSI Driver（PVC） |
| **Plugin Daemon 支援** | 受限（Sidecar 限制） | 完整支援 | 完整支援 |
| **維運複雜度** | 低（全托管，無 K8s 知識需求） | 中（需管理 OS / Docker） | 高（需 K8s 知識） |
| **觀測性** | Log Analytics 整合（開箱即用） | 需自行設定 | Azure Monitor + Container Insights |
| **資源隔離** | Container App 層級 | VM 層級（各節點獨立） | Pod / Namespace 層級 |
| **滾動更新** | Revision 機制（zero downtime） | Manual upgrade policy | RollingUpdate 策略 |
| **固定月費（最小）** | ~$200~$300 | ~$505 | ~$518 |
| **最大節點 RI 後月費** | — | ~$380 | ~$393 |
| **適合場景** | 快速部署、輕量維運 | Plugin 完整支援、細粒度 OS 控制 | 長期正式環境、多服務管理、GitOps |

### 選擇建議

| 情境 | 建議架構 |
|------|---------|
| POC / 快速驗證 | **ACA** — 最低維運成本，快速上線 |
| 需要 Plugin 功能，團隊熟悉 Linux / Docker | **VM（VMSS）** — 最直覺，與本機開發環境一致 |
| 長期正式環境，團隊有 K8s 經驗 | **AKS** — 最佳擴展性與可觀測性，支援 GitOps |

---

> 詳細 ACA 架構請參閱 [ARCHITECTURE.md](./ARCHITECTURE.md)
> 詳細 VM 架構請參閱 [ARCHITECTURE_VM.md](./ARCHITECTURE_VM.md)
