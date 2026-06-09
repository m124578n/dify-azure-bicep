# 維運經驗紀錄

## ACA 以 Blob Queue 驅動擴展

### 架構設定

| 項目 | 值 |
|------|-----|
| Scale trigger | Azure Blob Storage Queue |
| Scale out 條件 | Queue 深度 > 5 |
| Scale in 冷卻時間 | 1 分鐘 |

Queue 深度超過 5 時 ACA 觸發新增 replica，Queue 清空後等待 1 分鐘確認穩定才縮減。

---

## 問題排查流程

### 症狀：任務卡住或無進度

```
1. 先看 AP Log
      │
      ├─ 流程停在「等待 ACA 處理」
      │       → 任務已進 Queue 但尚未被取走
      │       → 確認 Queue 深度、replica 數量是否有 scale out
      │
      └─ 任務已被取走、正在執行中但卡住
              → 直接去 ACA Log 查原因
              → 找對應 replica 的 stderr / exception
```

### 第一步：AP Log 判斷卡在哪個階段

確認任務是「還在 Queue 等」還是「已被 ACA 拿走但跑不完」。  
這兩種狀況根本原因不同，不要跳過這步直接看 ACA Log。

### 第二步：Queue 深度確認（若卡在 Queue）

```powershell
az storage message peek `
  --queue-name <queue-name> `
  --account-name <storage-account> `
  --num-messages 32 `
  --output table
```

同時確認 ACA replica 數量有沒有跟著 scale out：

```powershell
az containerapp revision list `
  --name <app-name> `
  --resource-group <rg> `
  --query "[].{replicas:properties.replicas, active:properties.active}" `
  -o table
```

### 第三步：ACA Log 查根本原因（若任務已在跑但卡住）

```kql
// 查特定 app 的 console log（stderr/stdout）
ContainerAppConsoleLogs
| where TimeGenerated > ago(30m)
| where ContainerAppName == "<app-name>"
| where Stream == "stderr"
| project TimeGenerated, ContainerInstanceName, Log
| order by TimeGenerated desc
```

```kql
// 查 system 層級事件（OOM、crash、restart）
ContainerAppSystemLogs
| where TimeGenerated > ago(30m)
| where ContainerAppName == "<app-name>"
| project TimeGenerated, Reason, Log
| order by TimeGenerated desc
```

---

## 經驗備注

- Scale in 冷卻 1 分鐘：短暫的 Queue 清空（例如批次任務間的空檔）不會立刻縮減，避免反覆 scale out/in 造成啟動開銷。
- AP Log 是第一現場，ACA Log 是第二現場，不要直接跳到 ACA Log，否則容易找錯方向。

---

## Scale In 行為：Queue 有值不代表不會縮

### 常見誤解

「Queue 還有訊息，所以 ACA 不會 scale in」— 這是錯的。

### 實際計算邏輯

KEDA 用的是比例計算，不是「有值就保持」：

```
目標 replica 數 = ceil( 目前 queue 深度 ÷ listLength )
```

| Queue 深度 | 計算 | 目標 replica 數 |
|-----------|------|----------------|
| 6 | ceil(6÷5) = 2 | 2（scale out） |
| 3 | ceil(3÷5) = 1 | 1 |
| 1 | ceil(1÷5) = 1 | 1 |

Queue 從 6 降到 3，目標從 2 變成 1，KEDA 發出 scale in 指令，冷卻 1 分鐘後多餘的 replica 終止。

### 要讓 replica 不被縮掉，只有兩種情況

1. Queue 深度持續 > threshold（維持多台的需求）
2. 把 `minReplicas` 設為對應數量（強制保留）
