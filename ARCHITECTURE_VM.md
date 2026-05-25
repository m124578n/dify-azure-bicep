# Dify on Azure — VM 架構說明與費用估算

## 架構概覽

```
Internet
    │
    ▼
[Public Standard LB]  ─── Public IP (Static, FQDN)
    │  TCP 80 / 443
    ▼
[nginx VM]  Standard_B2s, Ubuntu 22.04
    │  NginxSubnet: 10.99.1.0/24
    │  Reverse proxy → Internal LB
    │
    ▼
[Internal Standard LB]  10.99.2.4 (static private IP)
    │  TCP 80
    ▼
[VMSS vmss-dify]  Standard_D4s_v3 × 2~10 (CPU auto-scale)
    │  AppSubnet: 10.99.2.0/23
    │  每台執行完整 Docker Compose stack：
    │    nginx:stable  →  web(3000) / api(5001)
    │    api / worker / web / sandbox / ssrf_proxy / plugin
    │
    ├── [Azure Files CIFS mount]
    │     /mnt/nginx        — nginx 設定
    │     /mnt/sandbox      — sandbox 依賴套件
    │     /mnt/ssrfproxy    — squid 設定
    │     /mnt/pluginstorage — plugin 資料
    │
    ├── [PostgreSQL Flexible Server]  Standard_B1ms, 32 GB
    │     PostgresSubnet: 10.99.4.0/24 (VNet delegation)
    │     databases: dify, vector (pgvector)
    │
    ├── [Azure Cache for Redis]  Standard C0 (250 MB)
    │     Private Endpoint → PrivateLinkSubnet: 10.99.0.0/24
    │
    └── [Storage Account]  Standard LRS
          Azure Blob — Dify 上傳檔案
          Azure Files — 設定檔共享
          Private Endpoint → PrivateLinkSubnet
```

---

## 網路拓撲

| Subnet | CIDR | 用途 |
|--------|------|------|
| PrivateLinkSubnet | 10.99.0.0/24 | Redis / Storage Private Endpoint |
| NginxSubnet | 10.99.1.0/24 | nginx 反向代理 VM |
| AppSubnet | 10.99.2.0/23 | VMSS 應用層（/23 預留擴展空間） |
| PostgresSubnet | 10.99.4.0/24 | PostgreSQL Flexible Server (delegated) |

---

## 資源清單

| 資源 | SKU / 規格 | 說明 |
|------|-----------|------|
| nginx VM `vm-nginx` | Standard_B2s (2 vCPU / 4 GB) | 外部流量入口，Cloud-init 安裝 nginx，proxying 至 Internal LB |
| VMSS `vmss-dify` | Standard_D4s_v3 (4 vCPU / 16 GB) × 2~10 | Dify 完整應用層，CPU-based 自動擴展 |
| Public Standard LB `lb-dify-public` | Standard | 公開入口，Health probe: `GET /nginx-health` |
| Internal Standard LB `lb-dify-internal` | Standard | 內部流量分發至 VMSS backend pool |
| Public IP `pip-dify-lb` | Standard Static | FQDN: `dify-<uniqueHash>.japaneast.cloudapp.azure.com` |
| PostgreSQL Flexible Server | Standard_B1ms, 32 GB | 主要 DB + pgvector，VNet 整合，SSL required |
| Azure Cache for Redis | Standard C0 (250 MB) | Session cache / Celery broker，Private Endpoint |
| Storage Account | Standard LRS | Blob (Dify 儲存) + Azure Files (設定共享) |

---

## Auto-Scale 規則

| 觸發條件 | 動作 | Cooldown |
|---------|------|---------|
| CPU 平均 > 70%，持續 5 分鐘 | +1 instance | 5 分鐘 |
| CPU 平均 < 30%，持續 10 分鐘 | −1 instance | 10 分鐘 |
| 最小 / 最大 / 預設 | 2 / 10 / 2 | — |

---

## 費用估算（Japan East，隨用隨付）

### 最小規模（2 VMSS instances）

| 資源 | 規格 | 月費 (USD) |
|------|------|-----------|
| nginx VM Standard_B2s × 1 | ~$0.055/hr × 730hr | ~$40 |
| nginx VM OS Disk Standard_LRS | 30 GB | ~$1.5 |
| VMSS Standard_D4s_v3 × 2 | ~$0.248/hr × 2 × 730hr | ~$362 |
| VMSS OS Disk Standard_LRS × 2 | 30 GB × 2 | ~$3 |
| Public Standard LB | 固定費 | ~$18 |
| Internal Standard LB | 固定費 | ~$18 |
| Public IP Static Standard | | ~$4 |
| PostgreSQL Standard_B1ms + 32 GB | compute + storage | ~$30 |
| Redis Standard C0 | ~$0.032/hr × 730hr | ~$23 |
| Storage Account | Blob + Azure Files (少量) | ~$5 |
| **合計** | | **~$505 / 月** |

### Auto-Scale 情境比較

| 情境 | VMSS 台數 | 估算月費 |
|------|----------|---------|
| 最小（off-peak） | 2 台 | ~$505 |
| 中度負載 | 4 台 | ~$870 |
| 高峰 | 10 台 | ~$1,960 |

> VMSS 每增加 1 台 Standard_D4s_v3 約增加 $181/月（PAYG）。

---

## 節費建議

### 1. Reserved Instances（最有效）

| 資源 | PAYG | 1年 RI | 節省 |
|------|------|--------|------|
| D4s_v3（每台） | $0.248/hr | ~$0.161/hr | ~35% |
| B2s（nginx VM） | $0.055/hr | ~$0.036/hr | ~35% |

2 台 VMSS + 1 台 nginx VM 採 1 年 RI，每月可省約 **$130~$150**，整體降至 **~$355~$375/月**。

### 2. 縮小規格選項

| 調整 | 節省 |
|------|------|
| nginx VM → Standard_B1s（1 vCPU / 2 GB） | −$31/月 |
| PostgreSQL Storage 縮至 16 GB（初期） | −$2/月 |
| VMSS minimum 縮至 1 台（非 24hr 服務） | −$181/月 |

### 3. Scheduled Auto-Scale（辦公時間制）

若服務主要在辦公時間使用，可加設 Scheduled Profile：
- 平日 08:00~20:00 JST：minimum = 2
- 其餘時段：minimum = 1

預估可再省 **$60~$90/月**。

---

## 與 ACA 架構比較

| 項目 | ACA 架構 | VM 架構 |
|------|---------|---------|
| 水平擴展 | Container App revision auto-scale | VMSS CPU-based auto-scale |
| 啟動時間（新 instance） | 秒級 | 分鐘級（VM 開機 + cloud-init） |
| 維運複雜度 | 低（全托管） | 中（OS / Docker 自管） |
| 客製化彈性 | 受限（container 環境） | 高（完整 Linux 環境） |
| Plugin Daemon local 模式 | 受限（Sidecar 限制） | 完整支援 |
| 固定月費（最小規模） | ~$200~$300 | ~$505 |
| 適合場景 | 輕量、快速部署 | 需要 Plugin 完整支援或細粒度控制 |

> 詳細 ACA 架構請參閱 [ARCHITECTURE.md](./ARCHITECTURE.md)
