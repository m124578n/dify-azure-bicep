# Dify 版本更新流程

## 方法一：In-place 更新（建議）

停機時間最短（約 1-2 分鐘），適合 minor/patch 版本升級。

### Step 1 — 更新 image tag

修改 `main.bicep` 的預設版本：

```bicep
param difyApiImage string = 'langgenius/dify-api:x.x.x'
param difyWebImage string = 'langgenius/dify-web:x.x.x'
param difySandboxImage string = 'langgenius/dify-sandbox:x.x.x'
param difyPluginDaemonImage string = 'langgenius/dify-plugin-daemon:x.x.x'
```

### Step 2 — 重新部署

更新 VMSS model，確保日後 scale-out 的新 instance 也使用新版本：

```powershell
.\deploy.ps1
```

### Step 3 — 在 running instance 做 in-place 更新

```powershell
az vmss run-command invoke `
  --resource-group <resource-group> `
  --name vmss-dify `
  --command-id RunShellScript `
  --instance-id 0 `
  --scripts "cd /opt/dify && docker compose pull && docker compose up -d"
```

`MIGRATION_ENABLED=true` 已設定，API container 啟動時會自動執行 DB migration。

---

## 方法二：Reimage（完整重建）

停機約 10-15 分鐘，適合 major 版本升級或 cloud-init 有結構性變更時。

完成 Step 1、Step 2 後執行：

```powershell
az vmss reimage `
  --resource-group <resource-group> `
  --name vmss-dify `
  --instance-id 0
```

---

## 多台 instance 滾動更新

`vmssInstanceCount` > 1 時，逐台更新以避免完全停機：

```powershell
$rg = "<resource-group>"

# 取得所有 instance ID
$ids = az vmss list-instances --resource-group $rg --name vmss-dify --query "[].instanceId" -o tsv

foreach ($id in $ids) {
    Write-Host "Updating instance $id..."
    az vmss run-command invoke `
      --resource-group $rg `
      --name vmss-dify `
      --command-id RunShellScript `
      --instance-id $id `
      --scripts "cd /opt/dify && docker compose pull && docker compose up -d"
    Write-Host "Instance $id updated. Waiting 30s before next..."
    Start-Sleep -Seconds 30
}
```

---

## 確認更新結果

```powershell
# 查看各 container 版本與狀態
az vmss run-command invoke `
  --resource-group <resource-group> `
  --name vmss-dify `
  --command-id RunShellScript `
  --instance-id 0 `
  --scripts "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
```

---

## 版本歷史

| 日期 | 版本 | 備註 |
|------|------|------|
| 2026-05-28 | 1.10.1-fix.1 | 初始部署 |
