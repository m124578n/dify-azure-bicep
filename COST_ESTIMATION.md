# Dify Azure 部署成本估算

> 地區：Japan East｜幣別：USD｜試算基準：2026年5月

---

## 環境對照

| 項目 | Dev | Prod (200–400 RPS) |
|------|-----|--------------------|
| 目的 | 開發測試 | 正式上線 |
| Parameters 檔 | `parameters.json` | `parameters.prod.json` |
| 部署指令 | `.\deploy.ps1` | `.\deploy.ps1 -Environment prod` |

---

## Dev 環境月費

### Azure Container Apps（acaAppMinCount = 0，縮到零）

| Container | CPU | Memory | 說明 |
|-----------|-----|--------|------|
| nginx | 0.5 | 1Gi | 反向代理 |
| api | 2 | 4Gi | Flask API |
| web | 1 | 2Gi | Next.js 前端 |
| worker | 2 | 4Gi | Celery 背景任務 |
| sandbox | 0.5 | 1Gi | 程式執行沙盒 |
| ssrfproxy | 0.5 | 1Gi | SSRF 防護 |
| plugin | 2 | 4Gi | 插件管理 |

> Min Replicas = 0，無流量時縮到零，僅依實際使用量計費

| 資源 | SKU | 月費估算 |
|------|-----|---------|
| ACA（依使用量） | Consumption | ~$20–50 |
| PostgreSQL | Standard_B1ms / 32GB | ~$31 |
| Redis | Standard_C0（250MB） | ~$55 |
| Storage | Standard_LRS | ~$5 |
| Private Endpoints（3個） | - | ~$22 |
| Log Analytics | 30天保留 | ~$5 |
| **合計** | | **~$138–168/月** |

### 短時間測試（2小時）

| 資源 | 費用 |
|------|------|
| ACA | $0（免費額度內） |
| PostgreSQL | ~$0.08 |
| Redis | ~$0.15 |
| Private Endpoints | ~$0.06 |
| **合計** | **~$0.30** |

> ACA 每月免費額度：180,000 vCPU-秒 / 360,000 GiB-秒
> 2小時 7 個 App 合計用量遠低於免費額度

---

## Prod 環境月費（200–400 RPS）

### 規格選擇依據

| Container | CPU | Memory | Min Replicas | 選擇理由 |
|-----------|-----|--------|--------------|---------|
| api | 4 | 8Gi | 3 | Flask/Gunicorn 每副本約 100–150 RPS，3 副本覆蓋 300–450 RPS |
| worker | 4 | 8Gi | 3 | Celery 任務 CPU 密集，與 API 對齊避免瓶頸 |
| web | 2 | 4Gi | 3 | Next.js SSR，比 API 輕但需同等副本數確保不成單點 |
| nginx | 0.5 | 1Gi | 3 | 純代理，不需大規格 |
| sandbox | 0.5 | 1Gi | 3 | 隔離執行，輕量 |
| ssrfproxy | 0.5 | 1Gi | 3 | Squid Proxy，輕量 |
| plugin | 2 | 4Gi | 3 | 插件管理 |

### PostgreSQL 規格依據

| 決策 | 原因 |
|------|------|
| B1ms → D2s_v3 | B1ms 是 Burstable，高流量下 CPU Credit 耗盡會降速 |
| GeneralPurpose tier | Burstable 不支援 HA |
| HA 開啟（ZoneRedundant） | DB 掛掉影響全部服務，需自動切換 |
| 32GB → 128GB | pgvector 儲存 Embedding 向量耗空間，100 萬筆文件約 50–100GB |

### Redis 規格依據

| SKU | 容量 | 選擇原因 |
|-----|------|---------|
| C0 | 250MB | Dev 夠用 |
| C2 | 6GB | 200–400 RPS 下 Session + Celery Queue 需足夠緩衝，且 Standard 有 Replica |

### Min Replicas = 3 的理由

- 容器冷啟動需 10–30 秒，生產環境不可接受
- Min 1 是單點故障風險
- Min 3 是最低「有容錯能力」的數量

### Prod 費用明細

| 資源 | SKU | 月費估算 |
|------|-----|---------|
| ACA（10 vCPU × 3副本，24/7） | Consumption | ~$2,350 |
| PostgreSQL | Standard_D2s_v3 / 128GB / HA | ~$280 |
| Redis | Standard_C2（6GB） | ~$220 |
| Storage | Standard_LRS | ~$5 |
| Private Endpoints（3個） | - | ~$22 |
| Log Analytics | 30天保留 | ~$5 |
| **合計** | | **~$2,882/月** |

---

## 費用比較總覽

| 情境 | 月費 |
|------|------|
| Dev（閒置為主） | ~$138–168 |
| Dev（2小時測試後刪除） | ~$0.30 |
| Prod（200–400 RPS） | ~$2,882 |

---

## 節省費用的建議

### Dev 環境
- 測試完立即刪除 RG：`az group delete --name rg-dify-dev-japaneast --yes`
- `acaAppMinCount: 0` 確保無流量時 ACA 縮到零

### Prod 環境
- 初期從 Min Replicas = 2 開始，用 Azure Monitor 觀察 CPU 使用率再調整
- 可考慮 Reserved Instance（PostgreSQL 預購 1–3 年）節省約 30–60%
- Redis 若流量穩定可改 Premium P1（支援持久化與更細緻的調整）

---

## 注意事項

- 以上為估算值，實際費用依流量、查詢複雜度、LLM API 回應時間而異
- LLM 本身費用（OpenAI、Groq 等）不包含在此估算內
- Japan East 定價，其他 Region 可能略有差異
- ACA Consumption 計費以實際使用秒數為單位，免費額度每月重設
