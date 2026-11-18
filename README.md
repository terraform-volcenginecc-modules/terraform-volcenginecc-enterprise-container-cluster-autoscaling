# Enterprise Container Cluster Automation and Autoscaling

Build a VKE foundation for enterprise applications that can serve public traffic, covering multi-AZ networking, internet egress, elastic node capacity, load balancing, and basic operations. After deployment, run the example application to verify public access, HPA autoscaling, and elastic node scaling.

## 1. Business Background

Container deployments need coordinated networking, egress, compute capacity, load balancing, and operational components. Manual provisioning can miss dependencies or mix environment settings.

- **Baseline and peak capacity differ**: persistent services need stable nodes, while traffic peaks need independently expandable capacity.
- **Network boundaries need clarity**: Node and Pod networks use separate address ranges and public EIPs so their egress can be managed independently.
- **Multi-AZ needs actual coverage**: listing multiple subnets does not prove that nodes span AZs; actual placement and service availability must be checked.
- **Pod and node scaling must cooperate**: HPA adjusts replicas using metrics; cluster-autoscaler adds nodes for unschedulable Pods.

This solution manages networking, egress, node capacity, load balancing, and operational components together through Terraform. It reduces missing dependencies and differences between environments caused by manual configuration, makes infrastructure reproducible, and enables elastic capacity while keeping cloud infrastructure and in-cluster application management separate.

## 2. Solution Overview

- **Network**: creates a VPC and one Node and one Pod subnet per AZ, using `VpcCniShared`. One public NAT applies SNAT by source subnet.
- **Egress**: two traffic-billed EIPs, dedicated to Nodes and Pods, with corresponding SNAT rules in each AZ.
- **Compute**: one non-autoscaling fixed pool per AZ, bound only to that AZ's Node subnet; one shared elastic pool defaults to initial 1, minimum 0, maximum 10.
- **Components**: installs Prometheus, logging, NPD, and optional autoscaler; reads platform ALB controller, CCM, and VPC-CNI; reconciles CoreDNS and metrics-server during Apply.
- **Ingress**: Terraform creates the public ALB. Users configure ALBInstance, Service, and Ingress; the Ingress controller owns listeners and backends.

```mermaid
flowchart LR
  User["Public users"] --> ALB["Public ALB"]
  subgraph VKE["VKE / Beijing A and C"]
    App["Manual application / Service / Ingress"]
    A["Fixed A / one A subnet"]
    C["Fixed C / one C subnet"]
    E["Shared elastic pool / A and C"]
  end
  ALB --> App
  App -.->|"Scheduling"| A & C & E
  A & C & E -->|"Node subnets"| NAT["Shared NAT / subnet SNAT"]
  App -->|"Pod subnets"| NAT
  NAT -->|"Node rules"| NE["Node egress EIP"]
  NAT -->|"Pod rules"| PE["Pod egress EIP"]
```

The diagram illustrates the current Beijing A/C example. Solid edges show request/network paths; dotted edges show Pod scheduling. Applications, Services, and Ingress are user-deployed cluster objects, not Terraform-created cloud resources.

After infrastructure creation, obtain a kubeconfig, bind an ALBInstance, deploy the example application, and access it publicly. CPU metrics drive HPA; capacity-related Pending Pods drive elastic node expansion. Fixed pools provide baseline capacity independently of automatic scale-down.

The bundled `terraform_data + local-exec + Python` reconciler creates CoreDNS and metrics-server, then reads their status. Existing matching versions and deployment modes are retained. It does not automatically upgrade or independently delete them; cluster deletion reclaims them. The template does not install scheduler-plugin; ordinary workloads use the default Kubernetes scheduler.

## 3. IaC Design

### 3.1 Resource Inventory

Using the current two-AZ `terraform.tfvars` example with template autoscaler management enabled creates **21 cloud resources and one Terraform helper, for 22 additions**. AZs, fixed capacity, and addon versions are required inputs, not variable defaults.

| Terraform Resource | Count | Purpose |
|---|---:|---|
| `volcenginecc_vpc_vpc` | 1 | Isolated VPC |
| `volcenginecc_vpc_subnet` | 4 | One Node and Pod subnet in each of A/C |
| `volcenginecc_natgateway_ngw` | 1 | Shared public NAT in the first Node subnet |
| `volcenginecc_vpc_eip` | 2 | Separate Node and Pod egress |
| `volcenginecc_natgateway_snatentry` | 4 | Per-AZ subnet associations with the correct EIP |
| `volcenginecc_vke_cluster` | 1 | Managed VKE cluster |
| `volcenginecc_vke_node_pool` | 3 | Two single-AZ fixed pools and one shared elastic pool |
| `volcenginecc_vke_addon` | 4 | Prometheus, logging, NPD, autoscaler |
| `volcenginecc_alb_load_balancer` | 1 | Public application entry |
| `terraform_data` | 1 | Reconcile cluster-owned CoreDNS and metrics-server |

The addon module's five Data Sources read three platform components and two reconciled components; the root has one additional `external` Data Source for read-only preflight. None count as created resources. Worker ECS instances, disks, NICs, implicit security groups, ALB embedded public EIPs, the control plane, and in-cluster components are not counted again as the 21 resources, but still require quota, billing, and cleanup checks.

Disabling `manage_cluster_autoscaler` gives 20 cloud resources plus one helper. Three AZs add two subnets, two SNATs, and one fixed pool: 26 cloud resources plus one helper. Callers provide node login credentials, State storage, and operational access. The template does not create IAM roles or monitoring/logging backends.

### 3.2 Project Structure

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
├── scripts/
│   ├── preflight.py
│   ├── apply-checked.py
│   ├── reconcile-required-addons.py
│   └── prepare-destroy.py
├── examples/
│   ├── app.yaml
│   ├── hpa.yaml
│   └── node-scale-test.yaml
├── .gitignore
├── LICENSE
├── README.md
└── README.zh-CN.md
```

The tree lists template deliverables and excludes local editor configuration and internal acceptance records. Each module contains `main.tf`, `variables.tf`, `outputs.tf`, and `versions.tf`. The root configures the Provider; outputs establish network, cluster, pool, and addon dependencies. Resource tags come exclusively from `tags`, which defaults to `{}`. The template adds no Name, Environment, Project, Owner, or CostCenter tags. `project_name` remains the actual cloud project assignment.

### 3.3 Key Code Examples

The root `main.tf` passes the network module's per-AZ subnet map and fixed capacity into the node-pool module:

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

Within the module, fixed pools use AZ names from `fixed_replicas_by_zone` as `for_each` keys and each bind one corresponding Node subnet. AZ keys are known at Plan time and do not depend on uncreated subnet IDs. Fixed-count keys must exactly match the selected subnet AZs, with at least one node per AZ. The shared elastic pool uses all Node subnets and `ZoneBalance`. Only external changes to `auto_scaling.desired_replicas` are ignored; Terraform still owns the minimum and maximum.

Fresh creation follows network → cluster → fixed/elastic pools → deletable addons → Required addon reconciliation and readback. ALB is a separate network branch. The cluster owns CoreDNS and metrics-server; Terraform manages deletable addons. Section 4.2.5 describes teardown.

## 4. Usage

This project supports cloud deployment through InfraManager or local deployment using the downloaded template. Cloud deployment is recommended: you do not need to prepare a Terraform runtime, and you can create and manage resources by entering parameters in the platform.

Terraform creates infrastructure and components; Kubernetes operations configure and validate applications, Ingress, and HPA.

### 4.1 Cloud Deployment

InfraManager is Volcengine's managed Terraform workspace. For more information, see the [InfraManager product introduction](https://docs.volcengine.com/docs/infrastructure-management/product-introduction?lang=zh).

#### 4.1.1 Prepare Permissions

Before deployment, prepare the target account's services, deployment permissions, and node login credentials, and confirm how you will access the cluster afterwards. Check the following in order:

1. **Activate services and check quotas**

   Enable VKE, ECS, VPC, NAT, EIP, and ALB in the target account. Check the target project, account balance, and each AZ's instance inventory, disks, ENIs, Pod IP space, and node quotas. On first use, follow the service consoles to authorize service-linked roles for VKE, ALB, and NAT, including `ServiceRoleForNatGateway`.

2. **Grant cloud resource permissions to the deployment identity**

   The deployment identity needs InfraManager stack operations, CloudControl permissions, and create/read/update/delete, tag, and association permissions for the cloud resources above.

   The template also checks availability and installs required components. Grant VKE `ListSupportedResourceTypes`, `ListSupportedAddons`, `ListSupportedImages`, `ListClusters`, `ListAddons`, and `CreateAddon`, plus ECS `DescribeAvailableResource`. Only `CreateAddon` creates components; the other APIs read information for verification.

3. **Prepare node login credentials**

   For key login, prepare an existing ECS SSH key pair in the target region. Enter only its name in the template, not its private key. For password login, configure the node password as described in Section 4.2.1.

4. **Confirm that the platform can run the template**

   The platform execution environment needs `/bin/sh`, Python 3, and access to VKE/ECS HTTPS APIs. The platform deployment identity supplies credentials, which must also be available to subprocesses invoked by the template. Temporary credentials additionally require `VOLCENGINE_SESSION_TOKEN`. Do not store credentials in template variable files.

   During Plan, the template runs `scripts/preflight.py` through `hashicorp/external ~> 2.3`. During Apply, it runs `scripts/reconcile-required-addons.py`, which depends on `scripts/preflight.py` in the same directory. Retain these files when uploading the template. See Section 4.2.2 for regional version confirmation.

5. **Prepare cluster connectivity and image access**

   Public Kubernetes API access is disabled by default. Post-deployment kubectl operations need a private connection through a VPN or an operational host in the same VPC. Workers and Pods must reach image registries. The examples use public ECR images; confirm that the target network can pull them.

6. **Grant cluster permissions to the operational identity**

   Post-deployment verification also requires Kubernetes RBAC for the target cluster: viewing nodes, components, and metrics; managing applications, Pods, Services, Ingress, and HPA in the test namespace; and managing cluster-level ALBInstance and IngressClass objects. Cloud resource and cluster permissions are granted separately. Developer access limited to one namespace is insufficient for the complete verification.

#### 4.1.2 Select the Template

Open the [InfraManager console](https://console.volcengine.com/iac), go to **Template Management > Public Templates**, and search for “企业级容器集群自动化管理和弹性扩缩容”.

The platform must publish the template before it becomes searchable. For the local revision, import a complete custom template and create a stack from it.

Preserve relative paths for root Terraform files, `modules/`, `scripts/`, and `examples/`. Uploading only `.tf` files omits preflight and reconciliation scripts. Exclude internal acceptance records, editor configuration, `.env`, State, Plan, caches, kubeconfig, and local deployment outputs; retain only non-sensitive examples in `terraform.tfvars`. The project currently has no `.terraform.lock.hcl`; each execution environment generates and retains its own lock file after initialization. ZIP entries must use `/` separators.

#### 4.1.3 Create a Stack

Select the template and click **Create Stack**. Enter the stack information and template parameters for your requirements. Create and review the execution plan, then click **Deploy** after confirming the changes are as expected.

See Section 4.2.1 for parameters and Section 4.2.2 for a deployment example based on `terraform.tfvars`. Explicitly select `node_login_method`: key mode requires `ssh_key_pair_name` and `node_password=null`; password mode requires `ssh_key_pair_name=null` and a password supplied through the platform's sensitive input. The example's `REPLACE_ME` fails validation. Supply a unique `name_prefix`, check AZs, Node/Pod CIDRs, and matching fixed-capacity AZ keys, and provide `kubernetes_version` with a valid confirmation record.

Keep VKE deletion protection enabled and ALB protection disabled by default, using platform stack protection. A fresh environment using the current two-AZ example has 22 additions. If the platform separates Plan and Apply, recheck availability using the plan's same resolved inputs before Apply; inventory queries do not reserve capacity.

Inspect deployment events for reconciliation logs and confirm that CoreDNS and metrics-server are retained or created and reach Running/Ok. Continue with validation after Apply; static outputs and successful resource creation do not prove application readiness.

#### 4.1.4 Verify the Deployment

Confirm that the deployment status is successful on the stack details page, then review the template outputs:

| Output | Purpose |
|---|---|
| `vpc_id`, `subnets`, `nat_gateway_id` | VPC, per-AZ Node/Pod subnets, and NAT |
| `egress` | Node/Pod EIP addresses and per-AZ SNAT identifiers |
| `cluster_id`, `cluster_status` | Cluster identity and service status |
| `api_server_endpoints` | API addresses, without kubeconfig |
| `nodepools` | Fixed pools indexed by AZ and shared elastic pool ID/status |
| `addons` | Deletable, platform, and reconciled component status |
| `alb_id`, `alb_dns_name` | ALB identity and instance hostname; use the hostname as the business domain's CNAME target |
| `alb_instance_manifest` | ALB binding manifest for the Ingress controller |

No output is declared sensitive, but outputs contain real resource identities and network addresses and should be protected. They contain neither passwords nor kubeconfig. For the current two-AZ example, the stack resource tab should show the 21 cloud resources and one helper listed in Section 3.1.

**1. Check placement, networking, and components.** Locate resources using outputs in the VKE, ECS, VPC, NAT, and ALB consoles. Each fixed pool binds one local Node subnet. Cross-check actual `ZoneId`, primary NIC subnet, and Pod NIC subnet using VKE nodes and ECS NIC details. Compare the four subnets across both AZs with `subnets`, and check each Node/Pod SNAT's source subnet and designated EIP. Pool identifiers may use `cluster_id|node_pool_id`; use the node-pool ID portion in the VKE console.

In VKE component management, prometheus-agent, log-collector, node-problem-detector, and cluster-autoscaler when enabled should be Running/Ok. ALB controller, CCM, VPC-CNI, CoreDNS, and metrics-server should also be healthy. Obtain a short-lived kubeconfig from VKE and store it in a controlled directory. Download the complete template on an operational host that can reach the private API, enter its root directory, and prepare Python 3, kubectl, and curl before running:

```bash
export KUBECONFIG="/secure/path/to/kubeconfig"
kubectl get nodes -L workload-pool,topology.kubernetes.io/zone
kubectl -n kube-system get pods
kubectl -n kube-system get service kube-dns
kubectl -n kube-system get endpoints kube-dns
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl top nodes
```

The current example should have one fixed Ready node in each of A/C and one initial elastic node, Ready system Pods, nonempty DNS Endpoints, and node metrics from the metrics API. For unhealthy nodes or components, first inspect events, image pulls, address capacity, and service status. Check cluster RBAC for 403 responses and private connectivity for timeouts.

**2. Configure and verify public application ingress.** Save the YAML content of the stack's `alb_instance_manifest` output to `/tmp/vke-alb-instance.yaml` on the operational host. Confirm that `spec.instanceID` matches this stack's `alb_id`, `blockCascadeDeletion` is true, the name is `vke-alb`, and no business object already uses that name:

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

Wait for the controller to create the corresponding IngressClass; its parameters should reference `vke-alb`. If absent, inspect ALBInstance status, the controller, and permissions before continuing. The example should have two Ready replicas, and its Service Endpoints must match the Ready Pod IP set. Check the HTTP 80 listener, `/` forwarding rule, and actual backend group in the ALB console:

```bash
kubectl -n vke-demo get pods -l app=web -o wide
kubectl -n vke-demo get endpoints web -o yaml
kubectl -n vke-demo describe ingress web
```

Obtain the public ingress IP for each AZ from ALB instance details and access each from outside the cluster. Replace the placeholders with actual IPs. Every entry should return HTTP 200 and `Welcome to nginx!`; curl uses the IP itself as Host:

```bash
for ip in "<ALB-A-public-IP>" "<ALB-C-public-IP>"; do
  curl --noproxy '*' --fail --show-error --connect-timeout 5 --max-time 30 \
    -w '\nHTTP %{http_code}\n' "http://${ip}/"
done
```

Add the third entry for three AZs. For timeouts, first check public listeners, access controls, and backend health; for 404, check IngressClass, Host, and path matching. `ScheduleAnyway` does not enforce application placement across AZs, so verify actual placement.

The `volcenginealb.com` instance hostname for ALBs created after August 1, 2025 cannot be used directly for business requests. See the [ALB domain change announcement](https://www.volcengine.com/docs/6406/1657696). For business traffic, prepare your own domain and create a CNAME pointing to `alb_dns_name` in your DNS console. Set that domain in the Ingress's `spec.rules[].host` as needed, then verify DNS and access. See [adding a CNAME record](https://www.volcengine.com/docs/6406/130777). This example configures HTTP only; HTTPS also requires a certificate and HTTPS listener.

**3. Verify both egress paths.** After the application example creates `vke-demo`, run the kubectl commands under "Egress check" in Section 4.2.4. Compare results with stack outputs: in every AZ, the ordinary Pod must return `egress.pod.address`, and the hostNetwork Pod must return `egress.node.address`. These commands do not require local Terraform State. The same section describes probe cleanup and troubleshooting.

**4. Verify elastic nodes.** Record fixed node names and cloud instance IDs in both AZs, and the elastic node count, before adding capacity load to the example namespace:

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

Each load Pod requests one CPU and can only use the elastic pool. Adjust replicas to exceed allocatable capacity. Verify Pending due to insufficient CPU, increased Ready elastic nodes, and eventual workload readiness, with both fixed node counts and identities unchanged. If expansion fails, first check Pod events, autoscaler status, maximum capacity, inventory, and quotas.

After removing load, watch elastic nodes decrease and press Ctrl+C to stop watching. Default idle and post-expansion delays are both 10 minutes; draining and deletion take additional time. PDBs, system Pods, and local storage can block further shrinking, so reaching the minimum of zero is not guaranteed. Verify reclaimed instances and NICs for removed nodes in VKE/ECS.

**5. Verify HPA when using it.** This is independent of node capacity verification and needs actual CPU metrics:

```bash
kubectl apply -f examples/hpa.yaml
kubectl -n vke-demo get hpa web
kubectl -n vke-demo top pods -l app=web
```

HPA uses a 60% CPU target, 2–30 replicas, and a 300-second scale-down stabilization window. In an independent test environment, create five load Pods with up to twenty concurrent request loops each:

```bash
kubectl -n vke-demo create deployment hpa-load \
  --image=public.ecr.aws/docker/library/busybox:1.37 --replicas=5 \
  -- sh -c 'for n in $(seq 1 20); do while true; do wget -q -T 2 -O- http://web/ >/dev/null || true; done & done; wait'
kubectl -n vke-demo rollout status deployment/hpa-load --timeout=180s
kubectl -n vke-demo get hpa web -w
# Stop watching with Ctrl+C, then remove load:
kubectl -n vke-demo delete deployment/hpa-load --ignore-not-found --wait=true
kubectl -n vke-demo get deployment web
```

Record CPU metrics and increased Ready replicas, stop load, then verify actual/Ready replicas return to two. Bound load by quota and cost. Small Nginx loads may not exceed the threshold; installing Prometheus does not replace metrics API validation.

After verification, remove the load, HPA, and application. Follow Section 4.2.5 to delete Ingress before ALBInstance and allow the controller to reclaim associated objects. Remove these test objects even when retaining the infrastructure. Placement, egress, component health, elastic node, and public-IP procedures draw on business verification of a remote deployment, but its version was not fully matched to the current source. This does not certify the complete stack lifecycle. HPA, custom domains, HTTPS, and actual node login require separate validation in the target environment.

### 4.2 Local Deployment

You can also download and run the template locally by following the steps below.

Run Terraform from the template root. The same private Kubernetes connectivity requirements apply after deployment.

#### 4.2.1 Prepare the Environment

**Base environment**: Terraform `>= 1.5.7, < 2.0.0`, Python 3, and `/bin/sh`. Provider constraints are `volcengine/volcenginecc ~> 0.0.74` (`>= 0.0.74, < 0.1.0`) and `hashicorp/external ~> 2.3` (`>= 2.3.0, < 3.0.0`). There is currently no `.terraform.lock.hcl`. The first `terraform init` selects compatible versions and generates a lock file; retain it to fix subsequent selections. The executor needs access to Provider downloads and VKE/ECS HTTPS APIs. Business verification additionally needs kubectl, curl, and connectivity to the cluster API.

**Services and quotas**: Follow Section 4.1.1 to activate services and prepare project permissions, service-linked roles, and a key pair when using key login. Check inventory, disks, ENIs, address capacity, and node quotas in the console. Local deployment also needs preflight and reconciliation permissions; the operational identity separately needs cluster RBAC.

**Credential injection** (environment variables are recommended; do not store credentials in code or `tfvars`):

```bash
export VOLCENGINE_ACCESS_KEY="your_access_key"
export VOLCENGINE_SECRET_KEY="your_secret_key"
export VOLCENGINE_REGION="cn-beijing"
```

Temporary credentials also require `VOLCENGINE_SESSION_TOKEN`. The Provider uses explicitly configured `var.region`; `VOLCENGINE_REGION` does not override the variable file's region. Preflight also uses Terraform's resolved region. The template does not generate kubeconfig.

**Sensitive business variables**: `node_password` is sensitive and is used for Worker system login in Password mode. The raw password must have 8–30 characters and contain at least three of uppercase letters, lowercase letters, digits, and special characters. Only `()~!@#$%^&*_+-=` are supported special characters. Inject it through an environment variable instead of storing it in `terraform.tfvars`:

```bash
export TF_VAR_node_password="<your-strong-node-password>"
```

Remove the `node_password` assignment from variable files before injection; same-name assignments in `terraform.tfvars` or `-var-file` take precedence over `TF_VAR_*`. Password mode also requires `node_login_method="Password"` and `ssh_key_pair_name=null`. For SshKeyPair mode, clear the password environment variable, set `node_password=null`, and supply an existing key-pair name, not its private key. Supply a raw password; the template Base64-encodes it automatically. Base64 is not encryption, and passwords and encoded values can remain in State, Plan, and JSON output. Protect these files and backend access.

**Key parameters**: defaults come from `variables.tf`. The current `terraform.tfvars` illustrates Beijing A/C, one fixed node per AZ, one initial elastic node, `ecs.g4i.4xlarge`, a Kubernetes 1.32 confirmation record, and specified addon versions, using Password mode. These do not establish current availability in your account. Explicitly add the required `kubernetes_version`, refresh the confirmation, and remove the password placeholder assignment. Section 4.2.2 provides a deployment example based on this file.

| Parameter | Default / input | Description |
|---|---|---|
| `region` | **Required, no default** | Target region; must match AZs and the version confirmation |
| `project_name` | `default` | Existing project |
| `name_prefix` | **Required, no default** | Unique 2–36 character resource prefix; starts with a lowercase letter and allows digits and hyphens |
| `tags` | `{}` | Only explicitly supplied user tags are attached |
| `vpc_cidr` | `10.0.0.0/16` | New private VPC |
| `zones` | **Required, no default** | 2–3 distinct AZs; Node/Pod CIDRs inside the VPC, without overlap |
| `service_cidr` | `172.22.0.0/22` | Must not overlap the VPC or connected networks |
| `kubernetes_version` | **Required, no default** | `1.xx` format; must match the version confirmation object |
| `kubernetes_version_confirmation` | **Required, no default** | Contains `region`, `version`, `resolved_version`, `verified_at_utc`; matches the creation page and is valid for 24 hours |
| `instance_types` | **Required, no default** | 1–10 distinct VKE-compatible types; preflight checks current stock in every AZ |
| `image_id` | `null` | **Conditionally required**: VKE default for one type; multiple types need a common compatible image |
| `node_login_method` | **Required, no default** | `SshKeyPair` or `Password`, shared by fixed and elastic pools |
| `ssh_key_pair_name` | `null` | **Conditionally required**: existing regional key-pair name in key mode; `null` in password mode |
| `node_password` | `null` (sensitive) | **Conditionally required**: raw password in password mode; `null` in key mode |
| `system_volume_size` / `system_volume_type` | `80` / `ESSD_PL0` | GiB, integer 40–2048; also supports `ESSD_FlexPL` |
| `fixed_replicas_by_zone` | **Required, no default** | Keys exactly match `zones`; integer 1–2000 per AZ |
| `elastic_initial_replicas` / `elastic_min_replicas` / `elastic_max_replicas` | `1` / `0` / `10` | Integers with `0 <= min <= initial <= max <= 2000` |
| `nat_spec` | `Small` | Also Medium, Large, Extra_Large_1/2; check regional availability |
| `egress_bandwidth` | `10` | Mbps cap for each outbound EIP, integer 1–200 |
| `alb_bandwidth` | `10` | Create-time inbound EIP cap, integer 1–200 Mbps; changes may replace ALB |
| `vke_delete_protection_enabled` | `true` | Disable through a reviewed update before deletion |
| `alb_delete_protection_enabled` | `false` | Use platform stack protection; follow Section 4.2.5 for existing protected ALBs |
| `api_server_public_access_enabled` | `false` | Private API by default; arrange management controls if exposing it |
| `addon_versions` | **Required, no default** | Prometheus, logging, NPD, and autoscaler version map |
| `required_addons` | **Required, no default** | CoreDNS and metrics-server versions and deployment settings; only these two components are allowed |
| `required_addons_reconcile_nonce` | `run-1` | Change after repairing external drift to rerun reconciliation |
| `required_addons_timeout_seconds` | `1200` | Overall reconciliation limit, integer 300–3600 seconds |
| `manage_cluster_autoscaler` | `true` | Create and manage autoscaler; setting false in an already managed environment plans deletion of that component |
| `scale_down_unneeded_minutes` | `10` | Idle scale-down wait, integer 1–60 minutes |

Size Node/Pod subnets for address capacity. Callers must check overlap with connected external networks. Resolve ownership of already installed addons rather than recreating them. Existing autoscaler can be imported during a controlled migration, or left externally managed with its configuration verified.

`required_addons` must contain exactly `core-dns` and `metrics-server`. In Managed mode, omit `deploy_node_type` or set it to `null`; Unmanaged mode requires `Node` or `VirtualNode`, with target-region compatibility confirmed by preflight. When disabling autoscaler management for a new environment, the caller must provide a controller for automatic expansion. Disabling the switch does not retain an already managed component.

#### 4.2.2 Scenario-based Deployment Examples

This example creates a new cluster in Beijing A/C with one fixed node per AZ and one initial elastic node.

1. **Prepare parameters**

   Use the network, node capacity, and addon configuration in `terraform.tfvars`. Check instance types, versions, and login credentials as described in Section 4.2.1. Set a unique `name_prefix` for this environment and add or update:

   ```hcl
   kubernetes_version = "1.32"
   kubernetes_version_confirmation = {
     region           = "cn-beijing"
     version          = "1.32"
     resolved_version = "<verified-full-Kubernetes-version>"
     verified_at_utc  = "<actual-ISO8601-verification-time-with-timezone>"
   }
   ```

   Verify the full version on the target region's VKE cluster-creation page. Replace placeholders with the actual version and verification time including timezone; confirmation is valid for 24 hours. The current example uses Password mode. Remove the `node_password` placeholder assignment (`REPLACE_ME`), then inject the password as described in Section 4.2.1.

2. **Initialize and validate**

   Run from the template root:

   ```bash
   terraform init
   terraform fmt -check -recursive
   terraform validate
   ```

3. **Review the plan and deploy**

   ```bash
   terraform plan -input=false -out=deploy.tfplan
   terraform show deploy.tfplan
   # Run after confirming the resources and parameters are as expected:
   python3 scripts/apply-checked.py deploy.tfplan
   ```

   Plan checks instance inventory, addon compatibility, and image compatibility. The checked-apply script depends on `scripts/preflight.py` in the same directory and rechecks availability before Apply, stopping deployment on failure. Inventory checks do not reserve capacity.

For three AZs, add matching entries to `zones` and `fixed_replicas_by_zone` with separate Node/Pod CIDRs, and first confirm the additional AZ's service and instance availability.

#### 4.2.3 Expected Deployment Results

The two-AZ example creates **21 cloud resources and one Terraform helper**, initially with three Ready Workers: two fixed nodes and one elastic node. See Section 3.1 for the resource inventory.

View outputs and save the manifest needed to bind the ALB:

```bash
terraform output
terraform output -raw alb_instance_manifest > /tmp/vke-alb-instance.yaml
```

Section 4.1.4 explains the outputs. After creating the ALB, deploy the application and Ingress to enable business access. Resources and traffic are billed according to specifications, duration, and usage.

#### 4.2.4 Post-deployment Verification

Obtain the target cluster's kubeconfig from VKE. Enter the template root on an operational host with private API connectivity. These commands use the dedicated test namespace `vke-demo`; confirm there are no existing business objects with the same names.

Inspect the cluster and deploy the example application:

```bash
export KUBECONFIG="/secure/path/to/kubeconfig"
kubectl get nodes -L workload-pool,topology.kubernetes.io/zone
kubectl -n kube-system get pods
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl apply -f /tmp/vke-alb-instance.yaml
kubectl apply -f examples/app.yaml
kubectl -n vke-demo rollout status deployment/web --timeout=300s
kubectl -n vke-demo get endpoints web
kubectl -n vke-demo exec deployment/web -- nslookup kubernetes.default.svc.cluster.local
```

| Check | Expected result | Check first on failure |
|---|---|---|
| Nodes and components | Three Ready Workers, with fixed nodes in A/C; four specified addons and supporting components healthy in VKE component management; metrics API available | Pod events, image pulls, component status |
| Application and DNS | Two Ready application replicas, Service Endpoints matching Ready Pods, and successful cluster-domain resolution | Application events, CoreDNS |
| Node/Pod egress | Probes below return `egress.node.address` and `egress.pod.address` respectively in both AZs | DNS, echo service, SNAT source subnets and EIPs |
| Public ALB ingress | Both AZs' public IPs return HTTP 200 and the Nginx page; HTTP 80 backends match Ready Pods | ALBInstance, IngressClass, listeners, backend health |

**Egress check**: create an ordinary Pod and a hostNetwork Pod in each AZ. The output labelled `pod` must match the Pod EIP, and `node` must match the Node EIP. Probes are removed when they finish normally:

```bash
for zone in cn-beijing-a cn-beijing-c; do
  for role in pod node; do
    host_network=false
    [ "$role" != node ] || host_network=true
    printf '%s %s\n' "$zone" "$role"
    kubectl -n vke-demo run "egress-${role}-${zone##*-}" \
      --image=public.ecr.aws/docker/library/nginx:1.28-alpine \
      --restart=Never --rm -i --pod-running-timeout=180s \
      --overrides="{\"spec\":{\"hostNetwork\":${host_network},\"dnsPolicy\":\"ClusterFirstWithHostNet\",\"nodeSelector\":{\"workload-pool\":\"fixed\",\"topology.kubernetes.io/zone\":\"${zone}\"}}}" \
      --command -- curl -fsS --connect-timeout 5 --max-time 30 https://checkip.amazonaws.com
  done
done
```

On failure, inspect probe events and logs, then delete any remaining Pods by name. Include the third AZ in the loop when using three AZs.

**Public access check**: obtain each AZ's public IP in the ALB console and run the command below from outside the cluster, replacing the placeholder for each IP. The default instance hostname cannot be used directly for business access; see Section 4.1.4 for custom-domain configuration.

```bash
curl --noproxy '*' -fsS --connect-timeout 5 --max-time 30 \
  -w '\nHTTP %{http_code}\n' "http://<ALB-public-IP>/"
```

Autoscaling and HPA verification are optional; see items 4 and 5 in Section 4.1.4. After basic checks, follow Section 4.2.5 to remove test objects. You can retain the infrastructure for continued use.

#### 4.2.5 Destroy Resources

Back up required application data and use the original deployment directory, region, Workspace, State, and parameters.

1. **Remove application ingress**

   These commands apply only to this README's dedicated test environment:

   ```bash
   kubectl -n vke-demo delete ingress web --ignore-not-found --wait=true
   kubectl delete albinstance vke-alb --ignore-not-found --wait=true
   kubectl delete -f examples/app.yaml --ignore-not-found
   ```

   `app.yaml` deletes the entire test namespace. If it contains other workloads, remove objects individually. Confirm that the controller has reclaimed IngressClass, listeners, rules, and backend groups before destroying infrastructure.

2. **Disable deletion protection and destroy**

   Use the existing script to inspect and disable protection on the target VKE/ALB, then review the deletion plan. Replace the region with your actual region:

   ```bash
   python3 scripts/prepare-destroy.py --root . --region cn-beijing
   # Run after reviewing target resources and protection changes:
   python3 scripts/prepare-destroy.py --root . --region cn-beijing --apply
   terraform plan -destroy
   terraform destroy
   ```

   `scripts/prepare-destroy.py` depends on `scripts/preflight.py` in the same directory, Python 3, Terraform, and cloud credentials, with target VKE/ALB read and protection-update permissions. It is read-only by default; `--apply` only disables protection. The timeout is 600 seconds; success returns 0 and failure returns 1. **Use this procedure for existing protected ALBs as well, instead of disabling protection through an ordinary Apply.** Proceed directly to destruction afterwards to avoid re-enabling protection.

   InfraManager users disable VKE, ALB, and stack deletion protection in the consoles, then delete the stack and select deletion of cloud resources.

3. **Confirm cleanup**

   In the consoles, confirm reclamation of the cluster, Workers, NICs, network, NAT/SNAT, EIPs, and ALB resources. Cluster components are reclaimed with the cluster. Existing SSH keys and the State backend are outside deletion scope. On destruction failure, retain State and inspect cloud tasks and remaining resources.

## 5. Summary and Long-term Development

This template delivers a reproducible multi-AZ VKE foundation. Terraform manages networking and egress, fixed and elastic nodes, the ALB entry point, and basic operational components. Users configure applications, Ingress, HPA, and logging backends. The shared NAT does not provide cross-AZ failover, and the example uses HTTP. Check service specifications, versions, and billing in the target region's console.

Recommendations for long-term development:

- **Availability**: deploy a separate NAT per AZ, enable TLS for ingress, and add capacity planning and cross-AZ disaster recovery drills.
- **Observability**: connect Prometheus and log collection to VMP/TLS to integrate metrics, logs, and alerts.
- **Security governance**: add network policies, image and key management, and include fmt/validate and script unit tests in CI.
- **Operational efficiency**: incorporate preflight, deployment, and deletion-protection steps into pipelines to reduce manual operations and state drift.
