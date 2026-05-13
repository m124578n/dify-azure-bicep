# Dify Azure 服務架構圖

## 整體架構

```mermaid
graph TB
    User((外部使用者))

    User -->|HTTPS port 443| nginx

    subgraph sub["Azure Subscription"]
        subgraph rg["Resource Group: rg-dify-dev-japaneast"]

            subgraph vnet["VNet: 10.99.0.0/16"]

                subgraph acasubnet["ACASubnet: 10.99.2.0/23"]
                    subgraph acaenv["Azure Container Apps Environment"]
                        nginx["🌐 nginx\n(external ingress)\nport 80"]
                        api["api\n(internal)\nport 5001"]
                        web["web\n(internal)\nport 3000"]
                        worker["worker\n(no ingress)"]
                        sandbox["sandbox\n(internal)\nport 8194"]
                        ssrfproxy["ssrfproxy\n(internal)\nport 3128"]
                        plugin["plugin\n(internal)\nport 5002"]
                    end
                end

                subgraph plsubnet["PrivateLinkSubnet: 10.99.0.0/24"]
                    pe_blob["PE: blob"]
                    pe_file["PE: file"]
                    pe_redis["PE: redis"]
                end

                subgraph pgsubnet["PostgresSubnet: 10.99.4.0/24\n(delegated)"]
                    postgresql[("PostgreSQL\nFlexible Server\nport 5432")]
                end

            end

            storage[("Storage Account\nBlob ＋ File Share")]
            redis[("Redis Cache\nport 6379")]
            loga["Log Analytics\nWorkspace"]
        end

        subgraph inframrg["rg-dify-aca-infra (managed)"]
            infra["ACA Infrastructure\nLoad Balancer / NIC"]
        end
    end

    %% Nginx routing
    nginx -->|"/console/api /api /v1 /files"| api
    nginx -->|"/"| web

    %% API connections
    api -->|port 5432| postgresql
    api -->|port 6379| pe_redis
    api -->|blob| pe_blob
    api <-->|port 5002| plugin

    %% Worker connections
    worker -->|port 5432| postgresql
    worker -->|port 6379| pe_redis
    worker -->|blob| pe_blob

    %% Plugin connections
    plugin -->|port 5432| postgresql
    plugin -->|port 6379| pe_redis

    %% Sandbox SSRF proxy
    sandbox -->|port 3128| ssrfproxy
    ssrfproxy -->|HTTP/HTTPS| User

    %% Private endpoints to storage/redis
    pe_blob --- storage
    pe_file --- storage
    pe_redis --- redis

    %% File shares mount
    storage -.->|mount nginx config| nginx
    storage -.->|mount squid config| ssrfproxy
    storage -.->|mount python deps| sandbox
    storage -.->|mount plugin files| plugin

    %% Logging
    acaenv -.->|logs| loga

    %% ACA infra
    acaenv -.->|managed by| infra
```

---

## 網路流量說明

### 對外流量（Ingress）

| 路徑 | 說明 |
|------|------|
| 外部 → nginx:80 | 唯一對外入口，ACA External Ingress |
| nginx → api:5001 | `/console/api`、`/api`、`/v1`、`/files` |
| nginx → web:3000 | `/`（所有其他路徑） |

### 服務間通訊（內部）

| 來源 | 目標 | Port | 用途 |
|------|------|------|------|
| api | PostgreSQL | 5432 | 讀寫應用資料 / 向量資料 |
| api | Redis | 6379 | Session、Celery 任務佇列 |
| api | Storage Blob | 443 | 檔案上傳 / 下載 |
| api | plugin | 5002 | 插件呼叫 |
| worker | PostgreSQL | 5432 | 背景任務讀寫 |
| worker | Redis | 6379 | Celery broker |
| worker | Storage Blob | 443 | 檔案處理 |
| plugin | PostgreSQL | 5432 | 插件資料存取 |
| plugin | Redis | 6379 | 插件快取 |
| sandbox | ssrfproxy | 3128 | 程式碼執行時的對外 HTTP/HTTPS 請求 |

### 私有端點（Private Endpoints）

| Private Endpoint | 對應服務 | 子網路 |
|------------------|---------|--------|
| pe-blob | Storage Account（Blob） | PrivateLinkSubnet |
| pe-file | Storage Account（File） | PrivateLinkSubnet |
| pe-redis | Redis Cache | PrivateLinkSubnet |

> PostgreSQL 直接部署在 PostgresSubnet（VNet delegation），不走 Private Endpoint

### 掛載（File Share Mount）

| File Share | 掛載到 | 內容 |
|-----------|--------|------|
| nginx | nginx container | nginx.conf、default.conf、proxy.conf |
| ssrfproxy | ssrfproxy container | squid.conf |
| sandbox | sandbox container | python-requirements.txt |
| pluginstorage | plugin container | 插件檔案 |

---

## Resource Group 說明

| Resource Group | 內容 | 建立方式 |
|---------------|------|---------|
| `rg-dify-dev-japaneast` | 所有 Dify 服務資源 | Bicep 建立 |
| `rg-dify-aca-infra` | ACA 底層基礎設施（LB、NIC） | Azure 自動建立 |
| `NetworkWatcherRG` | Network Watcher | Azure 自動建立 |

---

## 子網路設計

```
VNet: 10.99.0.0/16
├── PrivateLinkSubnet  10.99.0.0/24  → Private Endpoints 專用
├── ACASubnet          10.99.2.0/23  → Container Apps（/23 = 512 IP）
└── PostgresSubnet     10.99.4.0/24  → PostgreSQL（VNet delegation）
```
