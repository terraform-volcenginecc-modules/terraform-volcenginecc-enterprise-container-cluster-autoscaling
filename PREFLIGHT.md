# 部署参数预检 / Deployment preflight

Plan 通过 `hashicorp/external ~> 2.3` 调用 Python 3 预检。传入的是 Terraform 最终生效的参数，包含默认值、tfvars、TF_VAR 和平台参数，脚本没有独立的默认地域或规格。`FAIL`、`UNKNOWN` 都会触发数据源 postcondition 失败，阻止云资源创建。预检只有读取请求，不创建资源。

Terraform Plan invokes Python 3 through `hashicorp/external ~> 2.3`, passing resolved variables rather than an independent set of script defaults. FAIL and UNKNOWN both block planning before cloud creation. All availability requests are read-only.

## 地域 Kubernetes 创建版本确认

当前没有已验证、可直接使用的公开地域可创建版本查询接口。`ListSupportedResourceTypes` 只返回 ECS/AZ；Addon 兼容范围、已有集群和全局版本发布记录均不能证明当前地域允许创建某版本。

部署身份需在目标地域 VKE 创建集群页面中核对可选的 Kubernetes minor 版本及对应完整版本，再填写以下必填参数。不要填写未核实的完整版本或仅更新时间以延长过期记录。确认有效期为 24 小时，未来时间、无时区时间、地域或版本不匹配均不能通过。

Supply the required `kubernetes_version_confirmation` after checking the target region's cluster-creation page using the deployment identity. Record the full Kubernetes version and actual verification time. It expires after 24 hours; missing, future-dated or mismatched values block deployment.

以下是字段格式，尖括号是需要替换的占位值，并非可用证据：

```hcl
kubernetes_version_confirmation = {
  region           = "cn-beijing"
  version          = "1.32"
  resolved_version = "<verified full Kubernetes version, including patch>"
  verified_at_utc  = "<actual verification time in ISO 8601 with timezone>"
}
```

可将记录放在受控的 `local.tfvars` 中并执行 `terraform plan -var-file=local.tfvars`；InfraManager 将同一对象作为资源栈参数传入。更换地域或版本时必须重新确认，不能沿用北京的记录。

## 检查内容

- 查询全部 VKE 资源页，逐 AZ 确认可用区和所有所选规格支持情况。
- 使用 ECS `DescribeAvailableResource`，按实际 AZ、规格、按量计费和系统磁盘类型检查具体规格的 `SupportedResources[].Status`。顶层 AZ `Status` 不作为规格库存证据。
- 检查三项独立 Addon、启用时的 autoscaler，以及 CoreDNS/metrics-server 的明确版本。将所选完整 Kubernetes 版本与 `Compatibilities[].KubernetesVersion` 的数值版本范围比对，并检查网络模型、部署模式和节点类型。缺少版本、无法解析或缺失兼容元数据时不放行。服务明确返回空约束数组时按无版本限制处理。
- 平台 ALB controller、CCM、VPC-CNI 检查是否存在兼容候选，实际安装版本由平台服务决定，Apply 后继续检查 Running 状态。
- 指定镜像时检查它是否对所有规格可用；多规格必须指定共同支持的镜像。

All selected AZ/type pairs must pass. The default `ecs.g4il.4xlarge` is a candidate, not a stock guarantee. Explicit selected addon versions are checked against Kubernetes compatibility ranges; platform addon checks establish compatible candidates, not the version that the service will install.

## 执行方式

```bash
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -var-file=local.tfvars -out=deploy.tfplan
terraform show deploy.tfplan
# 审查保存计划后，重新查询可用性，再执行同一计划：
python3 scripts/apply-checked.py deploy.tfplan
```

`terraform plan` 自动预检。保存计划可能过期：直接 `terraform apply deploy.tfplan` 不会重新执行 Plan 阶段的数据源，因此使用上述复检入口。InfraManager 若分离 Plan/Apply，应在 Apply 前使用执行计划中同一组生效参数重新运行预检。库存检查不预留容量，查询和创建之间仍存在库存变化窗口。

Planning performs the check automatically. Applying a saved plan directly does not rerun its data sources; use `apply-checked.py` for a fresh read-only check against that plan's variables. A platform that separates Plan and Apply must recheck the same resolved inputs immediately before Apply. Inventory checks do not reserve capacity.

独立调用可以读取完整生效参数 JSON，或 Terraform 的计划 JSON：

```bash
python3 scripts/preflight.py --input-json /tmp/resolved-preflight-inputs.json
terraform show -json deploy.tfplan > /tmp/plan.json
python3 scripts/preflight.py --plan-json /tmp/plan.json
```

只复制部分参数不能通过校验；需要传入 `preflight.tf` 中的全部字段。独立 CLI 失败时返回退出码 1。`--external` 则按 Terraform 协议输出字符串映射，由 postcondition 阻断；不能单凭 external 进程退出码判断是否通过。

## 凭据、Plan 与删除

预检身份需要 VKE `ListSupportedResourceTypes`、`ListSupportedAddons`、`ListSupportedImages` 和 ECS `DescribeAvailableResource` 的读取权限。环境变量使用 `VOLCENGINE_ACCESS_KEY`、`VOLCENGINE_SECRET_KEY`，临时身份还需 `VOLCENGINE_SESSION_TOKEN`。不将凭据写入参数、报告或发布目录。

检查不会创建受管资源或写入时间戳触发器，正常配置的受管新增数仍为 22。连续 Plan 会重新检查；确认过期或当前资源不可用可导致 Plan 被阻断，这与资源 drift 不同。删除计划不依赖创建库存，复检入口对纯删除和无变更计划跳过创建预检；混合创建/修改/删除计划仍需通过。

Required read permissions are VKE `ListSupportedResourceTypes`, `ListSupportedAddons`, `ListSupportedImages`, and ECS `DescribeAvailableResource`. Credentials remain in environment variables. No timestamp trigger or extra managed resource is introduced. Expiring evidence or changing inventory can block a later Plan independently of state drift.

## 默认名称和标签

新环境默认资源前缀为 `vke`。ALBInstance 与示例 Ingress 统一引用 `vke-alb`。`tags = {}` 时模板不添加任何管理标签；需要 Owner/CostCenter 等标签时由用户在 `tags` 中显式定义。服务自身生成的系统标签不属于模板注入字段。

Existing deployments should retain their explicitly configured resource names unless a rename has been reviewed. Changing the new default does not constitute an automatic migration of existing ALBInstance/Ingress objects.
