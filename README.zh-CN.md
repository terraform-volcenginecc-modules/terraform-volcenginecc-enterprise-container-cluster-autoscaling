# 企业级容器集群自动化管理和弹性扩缩容

在火山引擎账号中创建多可用区 VKE 容器底座，包括独立 VPC、Node/Pod 子网、分用途公网出口、固定与弹性节点池、运维插件和公网 ALB。当前参数示例在北京 A/C 各配置一个固定节点，弹性容量由独立节点池提供。部署完成后，通过附带的 Kubernetes 示例配置 ALB Ingress 和应用，再验证公网访问、HPA 与节点扩缩容。

## 1. 业务背景

企业部署容器集群时，网络、出口、计算容量、负载均衡和运维组件需要配套配置，手工创建容易遗漏依赖或混用环境参数。

- **基线与峰值容量不同**：常态服务需要稳定节点，流量波峰需要独立扩展的临时容量。
- **网络边界需要明确**：Node 和 Pod 使用不同网段与公网 EIP，便于分别管理出口。
- **多可用区需要实际覆盖**：配置多个子网不等于节点已经跨区，需要检查实际落区和服务可用性。
- **Pod 与节点伸缩需要协作**：HPA 根据指标调整副本，cluster-autoscaler 根据不可调度 Pod 增加节点。

本方案将这些配置纳入 Terraform 管理，同时保留云基础设施与集群内应用的管理边界。

## 2. 方案概述

- **网络**：新建 VPC，每个 AZ 各一个 Node 子网和 Pod 子网，使用 `VpcCniShared`；一个公网 NAT 按来源子网配置 SNAT。
- **出口**：两枚独立的按流量计费 EIP，分别供 Node 和 Pod 使用；每个 AZ 各有对应 SNAT 规则。
- **计算**：每个 AZ 一个固定池，仅绑定本区 Node 子网并关闭自动伸缩；一个共享弹性池跨 AZ，默认初始 1、最小 0、最大 10。
- **组件**：安装 Prometheus、日志、NPD 和可选 autoscaler；只读核对平台预装 ALB controller、CCM、VPC-CNI；Apply 时幂等补齐 CoreDNS 和 metrics-server。
- **入站**：Terraform 创建公网 ALB；用户通过 ALBInstance、Service 和 Ingress 配置应用入口，监听器及后端由 Ingress controller 管理。

```mermaid
flowchart LR
  User["公网用户"] --> ALB["公网 ALB"]
  subgraph VKE["VKE / 北京 A、C"]
    App["手动部署的应用 / Service / Ingress"]
    A["固定池 A / 单个 A 区子网"]
    C["固定池 C / 单个 C 区子网"]
    E["共享弹性池 / A、C 子网"]
  end
  ALB --> App
  App -.->|"调度"| A & C & E
  A & C & E -->|"Node 子网"| NAT["共享 NAT / 按子网 SNAT"]
  App -->|"Pod 子网"| NAT
  NAT -->|"Node 规则"| NE["Node 出口 EIP"]
  NAT -->|"Pod 规则"| PE["Pod 出口 EIP"]
```

架构图以当前北京 A/C 示例为例。实线表示请求和网络路径，虚线表示 Pod 调度关系。应用、Service 和 Ingress 是使用者部署的集群内对象，不计入 Terraform 创建的云资源。

基础资源创建后，用户取得 Kubeconfig、绑定 ALBInstance、部署示例应用，并从公网访问应用。CPU 指标驱动 HPA 扩容；出现容量不足的 Pending Pod 时，autoscaler 扩展弹性节点池。固定池始终作为独立基线，不参与自动缩容。

CoreDNS 和 metrics-server 由模板内的 `terraform_data + local-exec + Python` 协调器创建，随后只读回查。组件已存在且版本、模式一致时保留；不自动升级，不单独删除，随集群回收。本模板不安装 scheduler-plugin，普通应用使用 Kubernetes 默认调度器。

## 3. IaC 设计

### 3.1 资源清单

按当前 `terraform.tfvars` 的两 AZ 配置，启用模板管理 autoscaler 时，创建 **21 个云资源和 1 个 Terraform 辅助对象，共 22 项新增**。可用区、固定容量及插件版本是必填输入，不是变量默认值。

| Terraform 资源 | 数量 | 用途 |
|---|---:|---|
| `volcenginecc_vpc_vpc` | 1 | 独立 VPC |
| `volcenginecc_vpc_subnet` | 4 | A/C 各一个 Node 子网和 Pod 子网 |
| `volcenginecc_natgateway_ngw` | 1 | 首个 Node 子网中的共享公网 NAT |
| `volcenginecc_vpc_eip` | 2 | Node 与 Pod 的独立出口 |
| `volcenginecc_natgateway_snatentry` | 4 | 每个 AZ 的两种子网分别关联对应 EIP |
| `volcenginecc_vke_cluster` | 1 | 托管 VKE 集群 |
| `volcenginecc_vke_node_pool` | 3 | 两个单 AZ 固定池与一个共享弹性池 |
| `volcenginecc_vke_addon` | 4 | Prometheus、日志、NPD、autoscaler |
| `volcenginecc_alb_load_balancer` | 1 | 公网应用入口 |
| `terraform_data` | 1 | 协调集群拥有的 CoreDNS 和 metrics-server |

组件模块的五个 Data Source 只读取三个平台组件和两个协调组件，根模块另有一个 `external` Data Source 执行只读预检，均不计入新建数量。Worker ECS、磁盘、网卡、隐式安全组、ALB 内嵌公网 EIP、控制面和集群内组件也不重复计入上述 21 个云资源，但仍有配额、费用和清理要求。

关闭 `manage_cluster_autoscaler` 后为 20 个云资源及 1 个辅助对象；三 AZ 配置增加两个子网、两条 SNAT 和一个固定池，为 26 个云资源及 1 个辅助对象。节点登录凭据、State 存储和运维连接由调用方提供；模板不创建 IAM Role、监控后端或日志后端。

### 3.2 工程结构

```text
.
├── modules/
│   ├── network/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── cluster/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── nodepools/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── addons/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── alb/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
├── main.tf
├── locals.tf
├── variables.tf
├── outputs.tf
├── providers.tf
├── versions.tf
├── preflight.tf
├── terraform.tfvars
├── PREFLIGHT.md
├── scripts/
│   ├── preflight.py
│   ├── apply-checked.py
│   ├── reconcile-required-addons.py
│   ├── bootstrap-dns.py
│   ├── prepare-destroy.py
│   └── 验证公网出口.py
├── examples/
│   ├── app.yaml
│   ├── hpa.yaml
│   └── node-scale-test.yaml
├── .gitignore
├── LICENSE
├── README.md
└── README.zh-CN.md
```

工程树展示模板交付文件，不包含本地编辑器配置和内部验收记录。每个子模块包含 `main.tf`、`variables.tf`、`outputs.tf`、`versions.tf`。Provider 在根模块配置；模块之间通过输出建立网络、集群、节点池和插件的依赖。资源标签完全来自 `tags`，默认为 `{}`，模板不会自动添加 Name、Environment、Project、Owner、CostCenter。`project_name` 仍用于实际云项目归属。

### 3.3 核心代码示例

根模块 `main.tf` 将网络模块的按 AZ 子网映射和固定容量传入节点池模块：

```hcl
module "nodepools" {
  source                   = "./modules/nodepools"
  cluster_id               = module.cluster.id
  name_prefix              = var.name_prefix
  project_name             = var.project_name
  node_subnet_ids_by_zone   = module.network.node_subnet_ids_by_zone
  fixed_replicas_by_zone    = var.fixed_replicas_by_zone
  instance_types           = var.instance_types
  image_id                 = var.image_id
  node_login_method        = var.node_login_method
  ssh_key_pair_name         = var.ssh_key_pair_name
  node_password            = var.node_password
  system_volume_size       = var.system_volume_size
  system_volume_type       = var.system_volume_type
  elastic_initial_replicas = var.elastic_initial_replicas
  elastic_min_replicas     = var.elastic_min_replicas
  elastic_max_replicas     = var.elastic_max_replicas
  tags                     = local.common_tags
}
```

模块内固定池使用 `fixed_replicas_by_zone` 的 AZ 名称执行 `for_each`，每池只绑定对应的一个 Node 子网。AZ 键在 Plan 时已知，不依赖尚未创建的子网 ID；固定容量的 AZ 键必须与选定子网完全一致，每区至少一个节点。共享弹性池使用所有 Node 子网和 `ZoneBalance`，仅忽略 `auto_scaling.desired_replicas` 的外部变化，最小与最大容量仍由 Terraform 管理。

新环境的创建顺序为网络 → 集群 → 固定池与弹性池 → 可卸载插件 → Required 组件协调与回查；ALB 为独立网络分支。CoreDNS、metrics-server 由集群拥有，可卸载插件由 Terraform 管理；存量固定池迁移与退出步骤见第 4.2.4、4.2.5 节。

## 4. 使用说明

本工程支持通过 InfraManager 在云上一键部署或下载模板在本地运行。推荐使用云上部署方式，无需自行准备 Terraform 运行环境，只需在平台填写参数即可完成资源创建和托管。

Terraform 创建基础设施及组件，应用、Ingress 和 HPA 则通过 Kubernetes 操作配置和验证。

### 4.1 云上部署

InfraManager 是火山引擎提供的 Terraform 托管工作台，更多产品介绍参见 [InfraManager 产品介绍](https://docs.volcengine.com/docs/infrastructure-management/product-introduction?lang=zh)。

#### 4.1.1 准备权限

在目标账号开通 VKE、ECS、VPC、NAT、EIP 和 ALB，确认项目、余额、各 AZ 的实例库存、磁盘、ENI、Pod IP 和节点配额。首次使用时，按服务控制台提示准备 VKE、ALB 及 NAT 的服务关联角色，包括 `ServiceRoleForNatGateway`。

执行身份需要 InfraManager 资源栈操作权限、CloudControl 权限，以及这些云资源的创建、读取、更新、删除、标签和关联权限。预检需要 VKE `ListSupportedResourceTypes`、`ListSupportedAddons`、`ListSupportedImages` 和 ECS `DescribeAvailableResource` 读取权限；组件协调器另需 VKE `ListClusters`、`ListAddons`、`CreateAddon`。密钥登录时准备目标地域已有的 ECS SSH 密钥对，只输入名称，不提供私钥；密码登录时按第 4.2.1 节配置节点密码。

**平台执行器需要 `/bin/sh`、Python 3、VKE/ECS HTTPS API 访问及可被子进程继承的部署凭据**。`hashicorp/external ~> 2.3` Provider 在 Plan 阶段运行 `scripts/preflight.py`，组件协调器在 Apply 阶段运行 `scripts/reconcile-required-addons.py`，后者依赖同目录的 `scripts/preflight.py`。临时身份还需传递 `VOLCENGINE_SESSION_TOKEN`。凭据由平台部署身份提供，不写入模板参数文件。地域版本确认的完整步骤见第 4.2.2 节。

默认关闭 Kubernetes API 公网访问，后续 kubectl 需通过 VPN、同 VPC 运维主机等私网路径连接。Worker 和 Pod 需要访问镜像仓库；示例采用公开 ECR 镜像，部署前确认目标网络可拉取。

部署后的运维身份还需取得目标集群的 Kubernetes RBAC 权限：只读查看节点、组件和指标，以及在测试命名空间管理应用、Pod、Service、Ingress、HPA，并管理集群级 ALBInstance 和 IngressClass。云资源管理权限不自动授予这些权限；仅有某个命名空间的开发权限不足以完成全部验证。

#### 4.1.2 选择模板

打开 [InfraManager 控制台](https://console.volcengine.com/iac)，进入 **模板管理 > 公开模板**，搜索“企业级容器集群自动化管理和弹性扩缩容”。

公开模板需由平台发布后才能搜索到。使用本地修订版本时，通过自定义导入上传完整模板包，再选择导入的模板创建资源栈。

保留根 Terraform 文件、`modules/`、`scripts/` 和 `examples/` 的相对目录结构。仅上传 `.tf` 文件会缺少预检和组件协调脚本。发布包不包含内部验收记录、编辑器配置、`.env`、State、Plan、缓存、Kubeconfig 和本地部署输出；`terraform.tfvars` 只保留非敏感示例。当前工程没有 `.terraform.lock.hcl`，执行环境初始化后生成并保留自己的锁文件；ZIP 内使用 `/` 路径分隔符。

#### 4.1.3 创建资源栈

选择模板并点击 **创建资源栈**，根据实际需求填写资源栈信息和模板参数。创建并检查执行计划，确认变更符合预期后，点击 **执行部署**。

参数说明见第 4.2.1 节，完整配置示例见第 4.2.2 节。`node_login_method` 必须显式选择：密钥模式提供 `ssh_key_pair_name` 并设置 `node_password=null`；密码模式设置 `ssh_key_pair_name=null` 并通过平台敏感输入提供密码。当前示例的 `REPLACE_ME` 不能通过校验。为独立环境设置唯一 `name_prefix`，核对可用区、Node/Pod 网段与固定容量的 AZ 键一致，并填写 `kubernetes_version` 及有效确认记录。

默认保持 VKE 删除保护开启、ALB 删除保护关闭，并使用平台资源栈删除保护。当前两 AZ 示例的新环境预期为 22 项新增。若平台将 Plan 和 Apply 分开执行，应在 Apply 前以计划中的同一组生效参数复查可用性；库存查询不会预留容量。

查看部署事件中的组件协调日志，确认 CoreDNS 和 metrics-server 已保留或创建并达到 Running/Ok。Apply 成功后继续执行下面的验证，不能仅凭静态输出或资源创建成功判定应用可用。

#### 4.1.4 部署验证

在资源栈详情页查看部署状态为“成功”，再查看模板输出：

| 输出 | 用途 |
|---|---|
| `vpc_id`、`subnets`、`nat_gateway_id` | 核对 VPC、各 AZ 的 Node/Pod 子网与 NAT |
| `egress` | Node/Pod EIP 地址及按 AZ 的 SNAT 标识 |
| `cluster_id`、`cluster_status` | 集群标识和服务状态 |
| `api_server_endpoints` | API 地址，不含 Kubeconfig |
| `nodepools` | 按 AZ 索引的固定池及共享弹性池 ID/status |
| `addons` | 可卸载插件、平台组件和协调组件状态 |
| `alb_id`、`alb_dns_name` | ALB 标识和实例域名；实例域名用作业务域名 CNAME 目标 |
| `alb_instance_manifest` | 将 ALB 绑定到 Ingress controller 的清单 |

所有输出均未声明为敏感，但包含实际资源标识和网络地址，应妥善保存；输出不包含密码或 Kubeconfig。资源栈资源页中，当前两 AZ 示例应有第 3.1 节的 21 个云资源及 1 个辅助对象。

**1. 核对落区、网络和组件。** 在 VKE、ECS、VPC、NAT 和 ALB 控制台按输出定位资源。每个固定池只绑定一个本区 Node 子网；用 VKE 节点及 ECS 网卡详情核对实际 `ZoneId`、主网卡子网和 Pod 网卡子网。按 `subnets` 核对两区四个子网，并检查每条 Node/Pod SNAT 的来源子网及对应 EIP。节点池标识可能为 `cluster_id|node_pool_id`，在 VKE 控制台使用节点池 ID 部分定位。

VKE 的组件管理页应显示 prometheus-agent、log-collector、node-problem-detector，以及启用时的 cluster-autoscaler 为 Running/Ok；ALB controller、CCM、VPC-CNI、CoreDNS、metrics-server 也应健康。从 VKE 控制台取得短期 Kubeconfig，保存于受控目录。在能访问私网 API 的运维环境下载完整模板，进入模板根目录，准备 Python 3、kubectl 和 curl 后执行：

```bash
export KUBECONFIG="/secure/path/to/kubeconfig"
kubectl get nodes -L workload-pool,topology.kubernetes.io/zone
kubectl -n kube-system get pods
kubectl -n kube-system get service kube-dns
kubectl -n kube-system get endpoints kube-dns
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl top nodes
```

当前示例应有 A/C 各一个固定 Ready 节点及一个初始弹性节点，系统 Pod Ready，DNS Endpoints 非空，metrics API 返回节点指标。组件或节点异常时先查对应事件、镜像拉取、地址容量和服务状态；403 先检查集群 RBAC，连接超时先检查私网路径。

**2. 配置并验证公网应用入口。** 将资源栈输出 `alb_instance_manifest` 的 YAML 正文保存为运维环境中的 `/tmp/vke-alb-instance.yaml`。确认 `spec.instanceID` 是本栈 `alb_id`，`blockCascadeDeletion` 为 true，名称为 `vke-alb`，且集群内没有同名业务对象，然后执行：

```bash
kubectl apply --dry-run=server -f /tmp/vke-alb-instance.yaml
kubectl apply -f /tmp/vke-alb-instance.yaml
kubectl get albinstance vke-alb -o yaml
kubectl get ingressclass vke-alb -o yaml
kubectl apply -f examples/app.yaml
kubectl -n vke-demo rollout status deployment/web --timeout=300s
kubectl -n vke-demo get ingress,service,pods -o wide
kubectl -n vke-demo exec deployment/web -- nslookup kubernetes.default.svc.cluster.local
```

等待 controller 建立对应的 IngressClass；其参数应引用 `vke-alb`。若对象尚未出现，检查 ALBInstance 状态、控制器和权限，再继续。示例应用应有两个 Ready 副本，Service Endpoints 与 Ready Pod IP 集合一致。在 ALB 控制台核对 HTTP 80 监听器、路径 `/` 规则和实际后端组：

```bash
kubectl -n vke-demo get pods -l app=web -o wide
kubectl -n vke-demo get endpoints web -o yaml
kubectl -n vke-demo describe ingress web
```

在 ALB 实例详情取得各区入站公网 IP，在集群外逐一访问。将占位值替换为实际 IP，每个入口均应返回 HTTP 200 和 `Welcome to nginx!`，curl 使用 IP 自身作为 Host：

```bash
for ip in "<ALB-A-public-IP>" "<ALB-C-public-IP>"; do
  curl --noproxy '*' --fail --show-error --connect-timeout 5 --max-time 30 \
    -w '\nHTTP %{http_code}\n' "http://${ip}/"
done
```

三 AZ 时增加第三个入口。超时先查公网监听器、访问控制和后端健康；404 先查 IngressClass、Host 和路径匹配。`ScheduleAnyway` 不强制应用跨区，需核对 Pod 实际分布。

2025 年 8 月 1 日后新建 ALB 的 `volcenginealb.com` 实例域名禁止直接用于业务访问，参见 [ALB 域名变更公告](https://www.volcengine.com/docs/6406/1657696)。正式业务需准备自有域名，在 DNS 控制台添加指向 `alb_dns_name` 的 CNAME，按需将该域名填写到 Ingress 的 `spec.rules[].host`，再验证解析和访问；操作参见 [添加 CNAME 记录](https://www.volcengine.com/docs/6406/130777)。本示例仅配置 HTTP，HTTPS 还需证书及 HTTPS 监听器。

**3. 验证两种出口。** 应用示例创建 `vke-demo` 后，在上述运维环境运行 `scripts/验证公网出口.py`。从栈输出填写 Node/Pod EIP，并按实际可用区修改列表：

```bash
python3 scripts/验证公网出口.py \
  --namespace vke-demo --zones cn-beijing-a cn-beijing-c \
  --node-egress-ip "<egress.node.address>" \
  --pod-egress-ip "<egress.pod.address>"
```

脚本只依赖 Python 3 标准库和已配置的 kubectl，不使用 Terraform State 或云 AK/SK。每区在固定节点上顺序创建一个 hostNetwork Pod 和一个普通 Pod，分别请求 `https://checkip.amazonaws.com` 与 `https://api.ipify.org`。两个回显都应匹配对应 EIP，脚本同时打印节点、hostIP 和 podIP；再对照本区 Node/Pod CIDR 与网卡归属。hostNetwork Pod 共享 Node 地址，普通 Pod 使用 Pod 地址。

每个 Pod 默认等待 300 秒，两次 curl 各最多 30 秒。成功后删除该 Pod；重复运行生成新名称，不覆盖已有应用。全部匹配返回 0，运行或核对失败返回 1，参数错误返回 2。失败和 Ctrl+C 会保留当前 Pod 并打印名称，使用 `kubectl -n vke-demo describe pod <name>`、`kubectl -n vke-demo logs <name>` 排查后，用 `kubectl -n vke-demo delete pod <name>` 清理。超时先检查 DNS、TLS、回显站点和 Pod 事件，再查 SNAT；单个外部站点故障不能直接证明出口配置错误。

**4. 验证弹性节点。** 先记录两区固定节点名称、云实例 ID 和弹性池节点数，再对附带测试命名空间施加容量负载：

```bash
kubectl -n vke-demo apply -f examples/node-scale-test.yaml
kubectl -n vke-demo scale deployment/node-scale-test --replicas=40
kubectl -n vke-demo get pods -l app=node-scale-test -o wide
kubectl -n vke-demo get events --sort-by=.lastTimestamp
kubectl get nodes -L workload-pool,topology.kubernetes.io/zone
kubectl -n vke-demo rollout status deployment/node-scale-test --timeout=1200s
kubectl -n vke-demo delete deployment/node-scale-test --wait=true
kubectl get nodes -l workload-pool=elastic -w
```

每个负载 Pod 请求 1 CPU 且只能进入弹性池。按可分配容量调整副本数，确认 Pending 原因为 CPU 不足、弹性节点增加且 Ready、负载最终就绪，同时两区固定节点的数量与身份保持不变。若不扩容，先查 Pod 事件、autoscaler 状态、最大容量、规格库存及配额。

移除负载后观察弹性节点减少，按 Ctrl+C 结束观察。默认空闲与扩容后冷却均为 10 分钟，节点排水和删除还需时间；PDB、系统 Pod 和本地存储可能阻止继续缩容，不能保证回到最小值 0。回落后在 VKE/ECS 中核对被移除节点及其实例、网卡已回收。

**5. 验证 HPA（使用 HPA 时执行）。** 此项与节点容量验证独立，需要实际 CPU 指标：

```bash
kubectl apply -f examples/hpa.yaml
kubectl -n vke-demo get hpa web
kubectl -n vke-demo top pods -l app=web
```

HPA 使用 CPU 目标 60%、副本范围 2–30、缩容稳定窗口 300 秒。在独立测试环境，可创建 5 个负载 Pod，每个最多 20 个并发请求循环：

```bash
kubectl -n vke-demo create deployment hpa-load \
  --image=public.ecr.aws/docker/library/busybox:1.37 --replicas=5 \
  -- sh -c 'for n in $(seq 1 20); do while true; do wget -q -T 2 -O- http://web/ >/dev/null || true; done & done; wait'
kubectl -n vke-demo rollout status deployment/hpa-load --timeout=180s
kubectl -n vke-demo get hpa web -w
# 按 Ctrl+C 结束观察后停止负载：
kubectl -n vke-demo delete deployment/hpa-load --ignore-not-found --wait=true
kubectl -n vke-demo get deployment web
```

记录 CPU 指标与 Ready 副本增加，停止负载后确认实际副本及就绪数回到 2。按配额和成本控制压测规模；小规模 Nginx 请求不一定超过阈值。Prometheus 安装完成不能替代 metrics API 验证。

核对完成后删除负载、HPA 和本次应用，按第 4.2.5 节先清理 Ingress，再清理 ALBInstance，让 controller 回收关联对象；保留基础设施时也应清理这些测试对象。本节的落区、双出口、组件健康、弹性节点及公网 IP 步骤参考了远程部署的业务验证，但部署版本未与当前源码完整核对，不能作为整栈生命周期的验收结论。HPA、自定义域名、HTTPS 和实际节点登录需在目标环境另行验证。

### 4.2 本地部署

您也可以下载本工程模板在本地运行，需要按照下述步骤操作。

在模板根目录执行 Terraform；部署后 kubectl 的私网连接要求与云上相同。

#### 4.2.1 环境准备

**基础环境**：Terraform `>= 1.5.7, < 2.0.0`，Python 3 和 `/bin/sh`。Provider 约束为 `volcengine/volcenginecc ~> 0.0.74`（`>= 0.0.74, < 0.1.0`）和 `hashicorp/external ~> 2.3`（`>= 2.3.0, < 3.0.0`）。当前没有 `.terraform.lock.hcl`，首次 `terraform init` 会选择满足约束的版本并生成锁文件；保留该环境的锁文件以固定后续版本。执行机需访问 Provider 下载地址及 VKE/ECS HTTPS API。业务验证另需 kubectl、curl 和可访问集群 API 的网络。

**服务与配额**：按第 4.1.1 节，在控制台完成服务开通、项目权限、服务关联角色、密钥登录时的密钥对准备，以及实例库存、磁盘、ENI、地址容量和节点配额核对。本地身份同样需预检与组件协调权限；运维身份另需集群 RBAC。

**凭证注入**（推荐环境变量，不要写入代码或 `tfvars`）：

```bash
export VOLCENGINE_ACCESS_KEY="your_access_key"
export VOLCENGINE_SECRET_KEY="your_secret_key"
export VOLCENGINE_REGION="cn-beijing"
```

临时凭据另设置 `VOLCENGINE_SESSION_TOKEN`。Provider 使用显式配置的 `var.region`，`VOLCENGINE_REGION` 不会覆盖参数文件中的地域；预检也使用 Terraform 生效的地域。模板不生成 Kubeconfig。

**敏感业务变量**：`node_password` 为敏感字段，用于 Password 模式的 Worker 系统登录，建议通过环境变量注入，不要写入 `terraform.tfvars`：

```bash
export TF_VAR_node_password="<your-strong-node-password>"
```

先移除参数文件中的 `node_password` 赋值，再注入环境变量；`terraform.tfvars` 或 `-var-file` 的同名赋值优先于 `TF_VAR_*`。Password 模式同时设置 `node_login_method="Password"`、`ssh_key_pair_name=null`。SshKeyPair 模式清除密码环境变量、设置 `node_password=null`，并提供已有密钥对名称，不传私钥。密码使用原文，模板自动 Base64 编码；Base64 不是加密，密码及编码值可能保存在 State、Plan 和 JSON 展示中，须保护这些文件和后端访问权限。

**重点参数**：默认值来自 `variables.tf`。当前 `terraform.tfvars` 是北京 A/C、每区一个固定节点、初始一个弹性节点、`ecs.g4i.4xlarge`、Kubernetes 1.32 确认记录及指定插件版本的示例，并选择 Password 模式。这些均不代表目标账号当前可用；文件还需显式补上必填 `kubernetes_version`，更新确认记录并移除密码占位赋值。第 4.2.2 节给出完整必填参数示例。

| 参数 | 默认值 / 入口 | 说明 |
|---|---|---|
| `region` | **必填，无默认值** | 目标地域，必须与可用区和版本确认对象一致 |
| `project_name` | `default` | 已有项目 |
| `name_prefix` | **必填，无默认值** | 2–36 位，小写字母开头，允许数字和连字符，同环境内唯一 |
| `tags` | `{}` | 仅添加用户明确配置的标签 |
| `vpc_cidr` | `10.0.0.0/16` | 新建私网 VPC |
| `zones` | **必填，无默认值** | 2–3 个不同 AZ；Node/Pod 网段需位于 VPC 内且互不重叠 |
| `service_cidr` | `172.22.0.0/22` | 与 VPC 及已有连接网络不重叠 |
| `kubernetes_version` | **必填，无默认值** | 使用 `1.xx` 格式，必须与版本确认对象一致 |
| `kubernetes_version_confirmation` | **必填，无默认值** | 包含 `region`、`version`、`resolved_version`、`verified_at_utc`，须与创建页一致，有效期 24 小时 |
| `instance_types` | **必填，无默认值** | 1–10 个不同的 VKE 规格，预检逐 AZ 确认当前库存 |
| `image_id` | `null` | **条件必填**：单规格使用 VKE 默认镜像；多规格需填写公共兼容镜像 |
| `node_login_method` | **必填，无默认值** | 固定池和弹性池统一使用 `SshKeyPair` 或 `Password` |
| `ssh_key_pair_name` | `null` | **条件必填**：密钥模式填写目标地域已有密钥对名称；密码模式须为 `null` |
| `node_password` | `null`（敏感） | **条件必填**：密码模式填写原始密码；密钥模式须为 `null` |
| `system_volume_size` / `system_volume_type` | `80` / `ESSD_PL0` | GiB，40–2048 整数；也支持 `ESSD_FlexPL` |
| `fixed_replicas_by_zone` | **必填，无默认值** | AZ 键必须与 `zones` 一致，每区 1–2000 整数 |
| `elastic_initial_replicas` / `elastic_min_replicas` / `elastic_max_replicas` | `1` / `0` / `10` | 整数且满足 `0 <= min <= initial <= max <= 2000` |
| `nat_spec` | `Small` | 也支持 Medium、Large、Extra_Large_1/2，需确认地域可用性 |
| `egress_bandwidth` | `10` | 两枚出口 EIP 各自的 Mbps 上限，1–200 整数 |
| `alb_bandwidth` | `10` | 入站 EIP 的创建期带宽，1–200 Mbps；变更可能替换 ALB |
| `vke_delete_protection_enabled` | `true` | 销毁前通过审查后的更新关闭 |
| `alb_delete_protection_enabled` | `false` | 默认配合平台栈保护；已开启保护的环境按迁移指南退出 |
| `api_server_public_access_enabled` | `false` | 默认私网 API；开启公网时另行安排管理访问控制 |
| `addon_versions` | **必填，无默认值** | Prometheus、日志、NPD、autoscaler 的版本映射 |
| `required_addons` | **必填，无默认值** | CoreDNS、metrics-server 的版本与部署方式；仅允许这两个组件 |
| `required_addons_reconcile_nonce` | `run-1` | 修复外部漂移后修改，触发重新协调 |
| `required_addons_timeout_seconds` | `1200` | 300–3600 秒整数，协调器总体上限 |
| `manage_cluster_autoscaler` | `true` | 是否创建并管理 autoscaler；对已受管环境改为 false 会计划删除该组件 |
| `scale_down_unneeded_minutes` | `10` | 空闲缩容等待，1–60 分钟整数 |

Node/Pod 子网均需满足地址容量要求。Service 网段与外部连接网络的重叠需要调用方核对。四个插件已有安装时先处理所有权，不能重复创建；若已有 autoscaler，应在受控迁移中导入其对应资源，或关闭模板管理并核对既有配置。

`required_addons` 必须恰好包含 `core-dns` 和 `metrics-server`：Managed 模式的 `deploy_node_type` 应省略或为 `null`，Unmanaged 模式必须填写 `Node` 或 `VirtualNode`，且通过目标地域兼容性预检。新环境关闭 autoscaler 管理时，需由调用方提供控制器才能自动扩容；不要把关闭开关当作保留已受管组件的方式。

#### 4.2.2 场景化部署示例

初始化与校验：

```bash
terraform init
terraform fmt -check -recursive
terraform validate
```

节点登录配置示例（固定池和弹性池共用，任选一种）：

```hcl
# 密钥模式：替换当前参数文件中的 Password 模式。
node_login_method = "SshKeyPair"
ssh_key_pair_name = "<existing-regional-key-pair>"
node_password     = null
```

```hcl
# 密码模式：移除参数文件的 node_password 赋值，使用第 4.2.1 节的环境变量。
node_login_method = "Password"
ssh_key_pair_name = null
```

`node_password` 默认是 `null`，但 Password 模式必须提供有效密码。原始密码长度 8–30，至少包含大写字母、小写字母、数字、特殊字符中的三类；特殊字符仅支持 `()~!@#$%^&*_+-=`，不能以 `/` 或 `$6$` 开头。两种凭据互斥，配置不符会阻止 Plan。`terraform.tfvars` 中的 `REPLACE_ME` 无法通过校验，使用环境变量时须先删除该赋值。

切换登录模式会修改节点池配置，不代表存量节点已完成凭据切换；按 VKE 节点更新流程验证存量节点及新扩容节点的实际登录结果。

**场景一：双 AZ 底座。** 在目标地域 VKE 控制台进入创建集群页面，核对可选的 Kubernetes 次版本及对应完整版本，记录实际带时区核对时间。确认记录只能使用真实核对结果，有效期 24 小时；缺失、未来时间、无时区或地域/版本不匹配会阻断预检。更换地域或版本须重新核对，不能仅更新时间延长旧记录。

在参数文件中填写下列必填配置，前缀改为本次环境的唯一值，版本、规格及插件替换为目标地域已确认的值。完整版本和核对时间为占位值，替换后才能部署；登录参数按前面的二选一示例补充，密码只通过环境变量或平台敏感参数提供：

```hcl
region      = "cn-beijing"
name_prefix = "vke-demo"
kubernetes_version = "1.32"
kubernetes_version_confirmation = {
  region           = "cn-beijing"
  version          = "1.32"
  resolved_version = "<verified-full-Kubernetes-version>"
  verified_at_utc  = "<actual-ISO8601-verification-time-with-timezone>"
}
zones = [
  { zone_id = "cn-beijing-a", node_cidr = "10.0.0.0/24", pod_cidr = "10.0.16.0/20" },
  { zone_id = "cn-beijing-c", node_cidr = "10.0.1.0/24", pod_cidr = "10.0.32.0/20" },
]
fixed_replicas_by_zone = {
  cn-beijing-a = 1
  cn-beijing-c = 1
}
instance_types = ["ecs.g4i.4xlarge"]
addon_versions = {
  prometheus-agent      = "v3.10.0-vke.1.30"
  log-collector         = "v2.3.3"
  node-problem-detector = "v1.36.4-vke.1"
  cluster-autoscaler    = "v1.30.3-vke.15"
}
required_addons = {
  core-dns = {
    version          = "1.12.4"
    deploy_mode      = "Unmanaged"
    deploy_node_type = "Node"
  }
  metrics-server = {
    version          = "v0.7.1-vke.6"
    deploy_mode      = "Unmanaged"
    deploy_node_type = "Node"
  }
}
elastic_initial_replicas = 1
elastic_min_replicas     = 0
elastic_max_replicas     = 10
# 按前面的登录示例补充 node_login_method 及对应凭据。
```

初始化后，Plan 自动预检；审查计划后，通过 `scripts/apply-checked.py` 复检部署。该脚本依赖同目录的 `scripts/preflight.py` 和 PATH 中的 Terraform，重新查询保存计划的生效参数后执行该计划，复检失败返回 1 且不启动 Apply。重复运行仍受 Terraform 计划有效性检查约束：

```bash
terraform plan -input=false -out=deploy.tfplan
terraform show deploy.tfplan
# 审查计划后执行：
python3 scripts/apply-checked.py deploy.tfplan
```

Terraform 将最终生效的参数传入预检，逐 AZ 检查 VKE 规格支持、ECS 实时库存、所选 Addon 版本及镜像兼容性。FAIL 或 UNKNOWN 会在创建云资源前阻断 Plan。地域 Kubernetes 可创建版本尚无已验证的公开查询接口，必须提供明确确认记录，不能用 Addon 兼容性推断。平台组件检查是否存在兼容候选，实际安装版本仍由服务管理。库存只是查询时的快照，不是容量预留；复检入口会在 Apply 前按保存计划的参数重新查询。首次 Plan 仍应为 22 项受管资源新增；Apply 补齐两项协调组件，无需另行运行 `scripts/bootstrap-dns.py`。

**场景二：验证仅固定基线。** 在另一个空 State 的独立测试环境中，使用场景一的网络和两区固定容量，仅替换前缀及初始弹性容量：

```hcl
name_prefix             = "vke-baseline-demo"
elastic_initial_replicas = 0
elastic_min_replicas     = 0
elastic_max_replicas     = 10
```

将前缀改为唯一值后，完成本节初始化，执行以下命令；其余必填参数和凭证仍按场景一准备：

```bash
terraform plan -input=false -out=deploy.tfplan
terraform show deploy.tfplan
python3 scripts/apply-checked.py deploy.tfplan
```

新建数量仍为 22，但初始 Worker 只有两个固定节点。核对两区 Ready、DNS 和出口；该场景只验证初始固定基线，启用的 autoscaler 仍可在后续负载下增加弹性节点。

两种场景均面向独立新环境。已有弹性池忽略 live desired count 的变化，修改 `elastic_initial_replicas` 不会把运行中的节点数自动重置为 0，也不能用于替代缩容操作或存量迁移。

三 AZ 扩展需同步增加 `zones` 条目、独立 Node/Pod CIDR 和 `fixed_replicas_by_zone` 条目，每区至少一个节点。管理 autoscaler 时为 27 项新增；第三个 AZ 必须先确认服务和规格可用。

#### 4.2.3 部署预期结果

```bash
terraform output
terraform output -raw cluster_id
terraform output -json nodepools
terraform output -json egress
terraform output -raw alb_instance_manifest > /tmp/vke-alb-instance.yaml
```

当前两 AZ 示例应创建三个节点池，固定池输出按 AZ 索引，例如 `nodepools.fixed["cn-beijing-a"].id`。两种初始容量场景均为 21 个云资源及 1 个辅助对象；关闭模板管理 autoscaler 时少 1 个云资源。ALB 实例创建成功不等于已有监听器或可用应用；其他输出的含义及预期状态见第 4.1.4 节。

Worker ECS、系统盘、VKE 控制面、NAT、EIP、ALB 和公网流量产生对应费用；运行中的弹性节点也会计费。资源数量不等于账单项目数量，费用以规格、使用时长和实际用量为准。保护 State、Plan 和输出中的真实资源标识，不提交凭据或运行产物。

#### 4.2.4 部署后验证

用第 4.2.3 节的本地输出获得资源标识和 ALBInstance 清单，再取得目标集群 Kubeconfig，执行第 4.1.4 节的控制台关系、组件、DNS、公网 IP、双出口及弹性节点检查。场景一初始为三个 Worker；场景二初始为两个固定 Worker、零弹性 Worker，容量负载应能触发从零扩容。HPA 使用时单独验证 CPU 指标与副本变化；三 AZ 要覆盖第三个区的子网、出口、固定节点和 ALB 入站。云上验证通过资源栈输出定位，本地通过 Terraform 输出定位，其余操作相同。

**更新后核对。** 使用相同 State 和有效参数，在资源稳定后连续两次检查 Plan：

```bash
for n in 1 2; do
  rc=0
  terraform plan -input=false -detailed-exitcode || rc=$?
  printf '%s %s\n' "$n" "$rc"
  if [ "$rc" -ne 0 ]; then break; fi
done
```

两次均应为 0；2 表示存在计划变更，1 表示错误，先检查原因。参数更新后也要使用同一环境和最新参数执行检查。

计划会重新执行可用性预检；确认记录过期或库存变化导致的失败，应先重新核对创建条件，不直接当作资源漂移。本次远程业务验证未覆盖零变更 Plan、参数更新、从零扩容和平台完整生命周期，这些步骤为目标环境的预期核对方法。

可在测试环境将 `egress_bandwidth` 从 10 改为 11，审查只原地更新两枚出口 EIP，Apply 后回读相同 ID 和实际带宽，再执行两次 Plan；随后回滚 10 并重复核对。云上使用资源栈参数更新，本地修改受控参数文件后重新生成计划。

固定池从旧单对象变成按 AZ 的多个实例，旧 `fixed_replicas` 参数需改为映射，旧 `.fixed.id` 输出读取方式也需调整。存量池不能直接套用新配置：先设计过渡配置，创建新池、确认 Ready、排水迁移，再删除旧池。仅改变 nonce 可重复协调同版本缺失组件，不代表支持自动升级现有组件。

#### 4.2.5 销毁资源

先备份需要保留的业务数据并清理自建应用、Ingress、ALBInstance，让 controller 回收监听器、后端组和规则。下面的 Kubernetes 删除命令仅适用于附带示例的测试环境：

```bash
kubectl delete -f examples/hpa.yaml --ignore-not-found
kubectl -n vke-demo delete -f examples/node-scale-test.yaml --ignore-not-found
kubectl -n vke-demo delete deployment/hpa-load --ignore-not-found
kubectl -n vke-demo delete ingress web --ignore-not-found --wait=true
kubectl delete albinstance vke-alb --ignore-not-found --wait=true
kubectl delete -f examples/app.yaml --ignore-not-found
```

`app.yaml` 包含测试命名空间；如果其中已有其他业务，应改为逐项清理本次创建的对象。另按脚本打印的名称删除失败时保留的出口探针。检查 `kubectl get ingressclass vke-alb` 已不再返回该对象，并在 ALB 控制台确认测试监听器、规则和后端组已回收、ALB 实例仍保留，再处理基础设施。

对创建时 ALB 保护为 false 的新环境：

```bash
terraform plan -var='vke_delete_protection_enabled=false' -out=exit.tfplan
terraform show exit.tfplan
# 确认只有预期原地更新、没有非预期替换后：
terraform apply exit.tfplan
terraform plan -destroy -var='vke_delete_protection_enabled=false'
terraform destroy -var='vke_delete_protection_enabled=false'
```

保持原地域、Workspace、State 和其他输入不变。InfraManager 用户先更新 VKE 保护参数为 false，再关闭平台栈删除保护并选择删除云资源，无需下载本地 State。

已有 ALB 云端保护为 true 的环境，应保持原有输入，不要直接应用新的默认值。本地先使用 `scripts/prepare-destroy.py`，该脚本依赖同目录的 `scripts/preflight.py`、Python 3、Terraform 和继承的云凭据；需读取目标集群/ALB，并有 VKE `UpdateClusterConfig`、ALB `ModifyLoadBalancerAttributes` 权限。在同一部署目录运行，将地域替换为实际值：

```bash
python3 scripts/prepare-destroy.py --root . --region cn-beijing
# 核对同一 VPC 内的集群和 ALB，以及关闭保护动作后：
python3 scripts/prepare-destroy.py --root . --region cn-beijing --apply
terraform plan -destroy
terraform destroy
```

脚本默认只读，`--apply` 只关闭已有对象的保护，不删除资源、不修改 State；默认超时 600 秒，成功返回 0，失败返回 1。重复运行先读取当前状态；失败后已完成的保护变更仍有效，须先回查再重试。准备完成后直接执行 Destroy，中间不要再普通 Apply。云上可在相应服务控制台确认保护已关闭后删除目标资源栈。任何非预期替换都先停止；失败时保留 State 并核对云端任务和残留，不先移除 State。

CoreDNS、metrics-server 及平台组件随集群回收，不单独调用 DeleteAddon。完成后按原资源标识和 VPC 核对集群、节点池、Worker ECS、网卡、子网、NAT、SNAT、两枚出口 EIP、各区 ALB 入站 EIP 及 ALB 子资源；两 AZ 共四枚 EIP，三 AZ 共五枚。已有 SSH 密钥对和 State 后端不在模板删除范围；短期 Kubeconfig 和临时测试文件另行撤销或清理。销毁会删除 Terraform 管理的资源，须先审核删除清单，并保留原地域、Workspace、State 和其他参数；本次远程业务验证未执行基础资源 Destroy。

## 5. 总结

本模板提供按 AZ 隔离固定基线、独立弹性节点池、Node/Pod 双出口和 ALB 应用入口，并安装和核对所需运维组件。它交付容器基础设施，应用、Ingress、HPA、日志接入和业务数据管理仍由使用者配置；NPD 检测节点问题，不等于自动修复。

一个共享 NAT 位于首个 Node 子网，不提供跨 AZ NAT 故障切换；示例入口使用 HTTP，应用副本分布也需要实际核对。生产环境应按业务需求补充 TLS、备份、容量规划、网络策略和监控告警。Prometheus、日志采集器安装成功不代表数据已进入 VMP/TLS，本模板不创建这些后端。

服务规格、版本、计费和权限以目标地域控制台及官方文档为准。
