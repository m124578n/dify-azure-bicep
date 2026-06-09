# 高併發分析：4000 同時 Request

## 環境規格

| 元件 | 規格 |
|------|------|
| ACA 算力 | 7 vCPU / 14 GB（D8 workload profile） |
| PostgreSQL | D2s v3（2 vCPU / 8 GB）+ 128 GB SSD |
| Redis | Standard C3（6 GB，雙節點） |
| Storage | LRS Blob + 3 Private Endpoints |

---

## 瓶頸分析

### P0｜PostgreSQL 連線爆炸（必炸）

D2s v3 的 `max_connections` 上限約 300–400。

4000 request 進來後 ACA scale out，各服務滿載時同時持有的連線數：

| 服務 | 最大 replica | SQLAlchemy pool（5 + overflow 10） | 連線數 |
|------|-------------|-----------------------------------|--------|
| api | 10 | 15 | 150 |
| worker | 10 | 15 | 150 |
| extra-worker | 5 | 15 | 75 |
| plugin | 10 | 15 | 150 |
| **合計** | | | **525** |

超過上限後 PostgreSQL 回傳 `FATAL: remaining connection slots are reserved`，API 層全面 500。

**優化方案：**
- 短期：升級到 D4s v3（max_connections ~800）
- 長期：在 ACA 和 PostgreSQL 之間加 **PgBouncer**（transaction mode），把真實連線壓到 30–50 條

```
api / worker / plugin → PgBouncer（ACA 內部服務）→ PostgreSQL
設定：max_client_conn=1000, default_pool_size=30, pool_mode=transaction
```

---

### P0｜ACA D8 節點硬上限

D8 workload profile `maximumCount: 3`，最多 **24 vCPU / 96 GB**。

各服務滿載 vCPU 需求：

| 服務 | 單體 vCPU | × maxReplicas | 小計 |
|------|----------|--------------|------|
| nginx | 0.5 | × 10 | 5 |
| api | 2 | × 10 | 20 |
| worker | 2 | × 10 | 20 |
| web | 1 | × 10 | 10 |
| plugin | 2 | × 10 | 20 |
| sandbox | 0.5 | × 10 | 5 |
| extra-worker | 2 | × 5 | 10 |
| **合計** | | | **90 vCPU** |

節點只有 24 vCPU，多數服務搶不到資源，scale out 指令發出但排程器無法建立新 container。

**優化方案：**
- D8 `maximumCount` 從 3 改為 **5–6**（48 vCPU / 192 GB）
- 輕量服務（nginx、sandbox、ssrfproxy）移到 **Consumption profile**，不佔用 D8 節點配額

---

### P1｜ACA 冷啟動延遲

`acaAppMinCount: 0` 代表平時所有服務都是 0 個 replica。

4000 request 瞬間湧入 → 觸發 scale out → D8 節點需要 **1–3 分鐘啟動**，期間所有 request 逾時或 queue 爆炸。

**優化方案：**
- `acaAppMinCount` 改為 **1**，所有服務保持熱機
- nginx 單獨設定 `minReplicas: 2`（唯一對外入口，不能有冷啟動）

---

### P1｜Worker Scale Rule 失效（已修正）

原本 worker 的 scale rule 是 TCP `concurrentRequests`，但 worker 沒有 ingress，TCP 連線數永遠為 0，**worker 永遠不會 scale out**。

所有非同步任務只靠 extra-worker 的 5 個 replica 在跑。

**已修正為：** Redis queue length（listLength: 20），與 extra-worker 相同邏輯。

---

### P2｜Nginx 資源不足（LLM Streaming 場景）

nginx 每個 replica 只有 0.5 vCPU / 1 Gi，scale 上限 10 個。

LLM streaming 是長連線（數十秒到數分鐘），10 個 replica 的 file descriptor 和記憶體在高流量下會撐爆。

**優化方案：**
- memory 從 `1Gi` 改為 `2Gi`
- `concurrentRequests` 從 10 改為 **50**（已修正）
- 若 streaming 比例高，考慮把 nginx 移到 Consumption profile 讓它彈性更大

---

### P3｜Celery 死亡螺旋

worker 處理速度跟不上（受 PostgreSQL 拖累）→ Redis queue 深度快速增長 → extra-worker 瘋狂 scale out → 更多 replica 搶 PostgreSQL 連線 → PostgreSQL 更慢 → 惡性循環。

**優化方案：**
- 先解 PostgreSQL 瓶頸（加 PgBouncer）
- extra-worker `listLength` 從 5 改為 **20**（已修正），避免小積壓就大量起 replica
- extra-worker `maxReplicas` 從 5 降到 **3**，限制最大併發避免把 PostgreSQL 打爆

---

### P4｜Storage 走公網（潛在問題）

目前 storage.bicep 設定：
```bicep
publicNetworkAccess: 'Enabled'
defaultAction: 'Allow'   // 標注為「暫時」
```

Private Endpoint 已建好但實際流量還是走公網，高流量下可能受到公網頻寬限制影響。

**優化方案：**
- 確認 Private Endpoint 連線正常後，將 `defaultAction` 改回 `Deny`，強制所有流量走 PE

---

## 優化優先順序

| 優先 | 問題 | 方案 | 難度 |
|------|------|------|------|
| P0 | PostgreSQL 連線爆炸 | 加 PgBouncer 或升 D4s v3 | 中 |
| P0 | D8 節點硬上限 | `maximumCount: 5` | 低 |
| P1 | 冷啟動 | `acaAppMinCount: 1` | 低 |
| P1 | Worker scale rule 失效 | 改 Redis queue（已修正） | 已完成 |
| P2 | Nginx 資源不足 | memory `2Gi`，threshold 50（已修正） | 已完成 |
| P3 | Celery 死亡螺旋 | listLength 20（已修正）+ extra-worker maxReplicas 3 | 部分完成 |
| P4 | Storage 走公網 | `defaultAction: Deny` | 低 |

---

## 已在 bicep 中修正的項目

| 項目 | 修正內容 |
|------|---------|
| worker scale rule | TCP concurrentRequests → Redis queue length: 20 |
| extra-worker listLength | 5 → 20 |
| nginx concurrentRequests | 10 → 50 |
| api concurrentRequests | 10 → 25 |
| web concurrentRequests | 10 → 50 |
| plugin concurrentRequests | 10 → 20 |
| ssrfproxy concurrentRequests | 10 → 20 |
| sandbox concurrentRequests | 10 → 5 |
