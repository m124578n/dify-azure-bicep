# 容量分析：各服務 min 1 / max 3–5，extra-worker max 20

## 前提條件

| 項目 | 值 |
|------|-----|
| 各服務 min replicas | 1 |
| 各服務 max replicas | 3 或 5（分兩個情境計算） |
| extra-worker | min 0 / max 20（Consumption profile） |
| D8 節點 | maximumCount: 3（24 vCPU / 96 GB） |
| PostgreSQL | D2s v3，max_connections ≈ 393 |
| PgBouncer | 無 |

---

## 情境 A：各服務 max 3 replicas

### D8 vCPU 需求

| 服務 | 單體 vCPU | ×3 |
|------|----------|----|
| nginx | 0.5 | 1.5 |
| api | 2 | 6 |
| worker | 2 | 6 |
| web | 1 | 3 |
| plugin | 2 | 6 |
| sandbox | 0.5 | 1.5 |
| ssrfproxy | 0.5 | 1.5 |
| **合計** | | **25.5** |

D8 可用 24 vCPU，**超出 1.5 vCPU**。不是所有服務能同時跑到 3 replica，排程器會有 replica 等不到節點。

### 同步請求上限

| 層 | 公式 | 上限 |
|----|------|------|
| nginx（HTTP, threshold 50） | 3 × 50 | 150 concurrent |
| api（TCP, threshold 25） | 3 × 25 | **75 concurrent**（瓶頸） |

**同步請求實際上限：約 75 concurrent**

換算成吞吐量（依請求時間）：

| 請求類型 | 平均時間 | 吞吐量 |
|---------|---------|--------|
| 短 API（查詢、設定） | 0.5s | ~150 req/s |
| 一般 LLM 呼叫 | 5s | ~15 req/s |
| LLM streaming | 20s | ~4 req/s |

### PostgreSQL 連線數（max 3，無 PgBouncer）

| 服務 | replicas | pool/replica | 連線數 |
|------|---------|-------------|--------|
| api | 3 | 15 | 45 |
| worker | 3 | 15 | 45 |
| plugin | 3 | 15 | 45 |
| extra-worker | ? | 15 | ? |

api + worker + plugin 已用 135 條，剩餘 393 - 135 = **258 條給 extra-worker**。  
extra-worker 每台 15 條 → 最多 **17 個 replica**（不是 20）就觸頂。

### 非同步任務上限（max 3，無 PgBouncer）

- extra-worker 有效上限：17 replicas × 2 Celery 進程 = **34 concurrent async tasks**

---

## 情境 B：各服務 max 5 replicas

### D8 vCPU 需求

| 服務 | 單體 vCPU | ×5 |
|------|----------|----|
| nginx | 0.5 | 2.5 |
| api | 2 | 10 |
| worker | 2 | 10 |
| web | 1 | 5 |
| plugin | 2 | 10 |
| sandbox | 0.5 | 2.5 |
| ssrfproxy | 0.5 | 2.5 |
| **合計** | | **42.5** |

D8 可用 24 vCPU，**嚴重不足**。實際上 api + worker + plugin 三服務各跑 5 replica 就需要 30 vCPU，節點根本排不下。

**結論：max 5 在目前 D8 maximumCount: 3 下無法實現。**

### 若要支援 max 5，需要 D8 maximumCount: 6（48 vCPU）

在 D8 maximumCount 升到 6 的前提下：

| 層 | 公式 | 上限 |
|----|------|------|
| api（TCP, threshold 25） | 5 × 25 | **125 concurrent**（瓶頸） |

### PostgreSQL 連線數（max 5，無 PgBouncer）

| 服務 | replicas | 連線數 |
|------|---------|--------|
| api | 5 | 75 |
| worker | 5 | 75 |
| plugin | 5 | 75 |
| extra-worker | ? | ? |

三服務已用 225 條，剩餘 393 - 225 = 168 條 → extra-worker 最多 **11 個 replica**（不是 20）。

### 非同步任務上限（max 5，D8×6，無 PgBouncer）

- extra-worker 有效上限：11 replicas × 2 Celery 進程 = **22 concurrent async tasks**

---

## 情境 C：加入 PgBouncer 後（max 5，D8×6）

PgBouncer 把真實 DB 連線壓到 50 條，client 連線不再受限：

| 層 | 上限 |
|----|------|
| 同步 concurrent | **125**（api 5 replica × 25） |
| 非同步 concurrent | **40**（extra-worker 20 replica × 2 Celery） |
| PostgreSQL 連線 | 50 條（PgBouncer 控制） |

---

## 三情境總覽

| 情境 | 同步 concurrent | 非同步 concurrent | 備注 |
|------|----------------|-----------------|------|
| A：max 3，D8×3，無 PgBouncer | **75** | **34** | D8 稍微超載，extra-worker 上限 17 |
| B：max 5，D8×6，無 PgBouncer | **125** | **22** | PostgreSQL 限制 extra-worker 到 11 |
| C：max 5，D8×6，有 PgBouncer | **125** | **40** | 最理想，extra-worker 達到設計的 20 |

---

## 4000 同時 Request 的結論

| 情境 | 能承受嗎 | 說明 |
|------|---------|------|
| A | 否 | 最多 75 concurrent，4000 req 需排隊 53 輪 |
| B | 否 | 最多 125 concurrent，排隊 32 輪；PostgreSQL 更早爆 |
| C | 否 | 最多 125 concurrent，4000 req 需排隊 32 輪 |

**4000 concurrent 需要的 api replicas = ceil(4000 ÷ 25) = 160 個**，對應約需 320 vCPU，目前架構規格無法負荷。

若只是「4000 req 在短時間內全部完成，允許排隊等待」，情境 C 可以處理，只是需時：

| 請求類型 | 4000 req 完成時間（情境 C） |
|---------|--------------------------|
| 短 API（0.5s） | 4000 ÷ 250 req/s ≈ **16 秒** |
| LLM 呼叫（5s） | 4000 ÷ 25 req/s ≈ **160 秒** |
| LLM streaming（20s） | 4000 ÷ 6 req/s ≈ **667 秒** |

---

## 需調整的 bicep 設定

| 項目 | 現值 | 建議值 | 說明 |
|------|------|-------|------|
| D8 maximumCount | 3 | **6** | 支援 max 5 replicas |
| acaAppMinCount | 0 | **1** | 消除冷啟動 |
| PgBouncer | 無 | **加入** | 解除 PostgreSQL 連線上限 |
