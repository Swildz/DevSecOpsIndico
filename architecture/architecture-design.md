# AWS Architecture and Security Design
**Target Workload:** Secure Containerized Backend API  
**Environment:** Production-grade AWS Multi-AZ Deployment  
**Standard:** AWS Well-Architected Framework (Security & Reliability Pillars)

---

## 1. Executive Summary

This architecture provides an enterprise-ready, defense-in-depth AWS deployment for a containerized backend REST API. It replaces insecure practices (hardcoded secrets, overly permissive IAM, public databases, unverified CI/CD credentials) with zero-trust network boundaries, fine-grained IAM roles, automated cryptographic secret management, end-to-end encryption, and isolated compute via AWS Fargate.

---

## 2. Architecture Overview & Visual Diagram

The architecture is divided into three distinct network tiers across two Availability Zones (AZs) inside a dedicated Amazon VPC:
1. **Public Edge Tier:** Amazon Route 53, AWS WAF, and Application Load Balancer (ALB).
2. **Private Application Tier:** Amazon ECS with AWS Fargate tasks running in private subnets with no public IP addresses.
3. **Isolated Data & Service Tier:** Amazon RDS (Multi-AZ) and AWS PrivateLink VPC Endpoints for private AWS service communication.
4. **CI/CD Automation Tier:** GitHub Actions / GitLab CI authenticated via OpenID Connect (OIDC) with short-lived STS tokens.

```
+---------------------------------------------------------------------------------------------------------+
|                                             THE INTERNET                                                |
+---------------------------------------------------------------------------------------------------------+
                                                     │ HTTPS (Port 443, TLS 1.3)
                                                     ▼
+---------------------------------------------------------------------------------------------------------+
| AWS EDGE SERVICES                                                                                       |
|   • Amazon Route 53 (DNS with DNSSEC)                                                                   |
|   • AWS WAF (Web Application Firewall - SQLi, XSS, IP Reputation, Rate Limiting)                       |
+---------------------------------------------------------------------------------------------------------+
                                                     │
                                                     ▼
+============================================= AWS REGION ================================================+
|                                                                                                         |
|  +------------------------------------ VPC (10.0.0.0/16) --------------------------------------------+ |
|  |                                                                                                    | |
|  |  +----------------- Public Subnet (AZ-A) ----------------+  +--- Public Subnet (AZ-B) -----------+ | |
|  |  |  [ Application Load Balancer (ALB) Node A ]            |  |  [ ALB Node B ]                    | | |
|  |  |  • Ingress: 0.0.0.0/0 on 443 (WAF inspected)           |  |  • Ingress: 0.0.0.0/0 on 443       | | |
|  |  |  • ACM Certificate (TLS 1.3 Termination)               |  |  • HTTP -> HTTPS Redirection       | | |
|  |  +-------------------------------------------------------+  +------------------------------------+ | |
|  |                                  │                                              │                  | |
|  |                                  ├──────────────────────┬───────────────────────┤                  | |
|  |                                  │ (Port 8080 Target)   │ (Port 8080 Target)    │                  | |
|  |                                  ▼                      ▼                       ▼                  | |
|  |  +---------------- Private App Subnet (AZ-A) -----------+  +-- Private App Subnet (AZ-B) --------+ | |
|  |  |  [ Amazon ECS Fargate Task 1 ]                       |  |  [ Amazon ECS Fargate Task 2 ]      | | |
|  |  |  • Read-only root filesystem                         |  |  • Read-only root filesystem        | | |
|  |  |  • Non-root user (UID 10001)                          |  |  • Non-root user (UID 10001)        | | |
|  |  |  • Security Group: Ingress ONLY from ALB SG on 8080   |  |  • SG: Ingress ONLY from ALB SG    | | |
|  |  |  • NO Public IP addresses                            |  |  • NO Public IP addresses           | | |
|  |  +------------------------------------------------------+  +-------------------------------------+ | |
|  |                                  │                                              │                  | |
|  |            ┌─────────────────────┴──────────────────────┬───────────────────────┘                  | |
|  |            │                                            │                                          | |
|  |            ▼                                            ▼                                          | |
|  |  +---------------- Isolated DB Subnet (AZ-A) -----------+  +-- Isolated DB Subnet (AZ-B) --------+ | |
|  |  |  [ Amazon RDS PostgreSQL (Primary) ]                  |  |  [ Amazon RDS (Standby Replica) ]   | | |
|  |  |  • Storage Encrypted via KMS CMK                     |  |  • Multi-AZ Failover                 | | |
|  |  |  • SG: Ingress ONLY from ECS Task SG on 5432         |  |  • SG: Ingress ONLY from ECS Task SG | | |
|  |  |  • NO Internet Gateway route                        |  |  • NO Internet Gateway route         | | |
|  |  +------------------------------------------------------+  +-------------------------------------+ | |
|  |                                                                                                    | |
|  |  +-- VPC Endpoints (AWS PrivateLink - Subnet Interface Endpoints) -------------------------------+ | |
|  |  |  • com.amazonaws.<region>.ecr.api       • com.amazonaws.<region>.secretsmanager                | |
|  |  |  • com.amazonaws.<region>.ecr.dkr       • com.amazonaws.<region>.kms                           | |
|  |  |  • com.amazonaws.<region>.logs          • com.amazonaws.<region>.s3 (Gateway Endpoint)         | |
|  |  +-----------------------------------------------------------------------------------------------+ | |
|  +----------------------------------------------------------------------------------------------------+ |
|                                                                                                         |
|  +-- Supporting AWS Native Security & Governance Services --------------------------------------------+ |
|  |  • AWS Secrets Manager: Dynamic encrypted credentials (rotation enabled)                            | |
|  |  • AWS KMS: Customer Managed Key (CMK) with strict key policies                                    | |
|  |  • Amazon ECR: Immutable image tags + continuous vulnerability scanning                            | |
|  |  • Amazon CloudWatch: Container logs (`awslogs`), security metrics, alarms                          | |
|  |  • AWS CloudTrail: Multi-region encrypted audit trail streamed to CloudWatch Logs                   | |
|  +----------------------------------------------------------------------------------------------------+ |
+=========================================================================================================+
                                                     ▲
                                                     │ STS AssumeRoleWithWebIdentity (OIDC)
                                                     │ Short-lived token, Repo & Branch constrained
+----------------------------------------------------+----------------------------------------------------+
| CI/CD PIPELINE (GitHub Actions / GitLab CI)                                                             |
|   • Gitleaks (Secrets) -> Semgrep (SAST) -> Trivy (SCA/Container) -> Checkov (IaC) -> ZAP (DAST)       |
+---------------------------------------------------------------------------------------------------------+
```

---

## 3. Step-by-Step Request Flow from Internet to Application

1. **DNS Lookup & Edge Inspection:**
   - The user client requests `https://api.example.com`.
   - Amazon Route 53 resolves the domain using DNSSEC to the Application Load Balancer's public endpoints.
2. **AWS WAF Layer 7 Inspection:**
   - Before traffic reaches the load balancer listeners, AWS WAF inspects every incoming HTTP request.
   - Requests are checked against AWS Managed Core Rule Sets, Known Bad Inputs, Amazon IP Reputation Lists, and custom Rate Limiting rules (e.g., maximum 500 requests per 5 minutes per IP).
   - Malicious requests (SQLi, Cross-Site Scripting, log4j patterns) are blocked at the edge with HTTP 403 Forbidden.
3. **TLS 1.3 Termination at ALB:**
   - Valid traffic arrives at the Application Load Balancer across Public Subnets in AZ-A and AZ-B.
   - The ALB terminates TLS using a trusted certificate provisioned by AWS Certificate Manager (ACM).
   - The ALB listener enforces HTTPS with a security policy restricting cipher suites to TLS 1.3 / TLS 1.2 modern secure ciphers (`ELBSecurityPolicy-TLS13-1-2-2021-06`). Any plaintext HTTP (port 80) request is redirected to HTTPS (port 443).
4. **Target Routing to Private Subnets:**
   - The ALB matches the request path and forwards the traffic to an ECS Target Group.
   - The target group performs active health checks (`GET /healthz`) against the private IP addresses of the ECS Fargate tasks on container port 8080.
5. **Security Group Filtering:**
   - Traffic travels over internal VPC routing from the Public Subnets into the Private Application Subnets.
   - The ECS Task Security Group explicitly allows ingress **only** from the ALB Security Group on port 8080. Direct internet ingress is physically impossible because private subnets lack route table entries to the Internet Gateway.
6. **Task Execution & Application Logic:**
   - The ECS Fargate task executes inside a microVM with a read-only root filesystem as an unprivileged user (`UID 10001`).
   - If the request requires database access, the application queries Amazon RDS PostgreSQL in the Isolated Database Subnets via port 5432.
   - The database Security Group permits inbound traffic **only** from the ECS Task Security Group.
7. **Private AWS Service Communication:**
   - The application accesses AWS Secrets Manager, KMS, and CloudWatch Logs strictly through AWS PrivateLink VPC Endpoints without traversing the public internet.

---

## 4. Resource Classification: Public vs. Private Boundaries

| Resource Component | Placement | Ingress / Access | Egress / Destination | Rationale |
| :--- | :--- | :--- | :--- | :--- |
| **Application Load Balancer (ALB)** | Public Subnets (AZ-A, AZ-B) | Internet (0.0.0.0/0) on Port 443 (HTTPS) only | ECS Task SG on Port 8080 | Needs public internet accessibility to accept client traffic; acts as reverse proxy shielding internal workloads. |
| **ECS Fargate Tasks** | Private App Subnets (AZ-A, AZ-B) | ALB Security Group on Port 8080 only | VPC Endpoints (443), RDS SG (5432) | **Zero public exposure.** Tasks do not receive public IP addresses. Even outbound internet is prevented or routed via restricted NAT Gateway. |
| **Amazon RDS (PostgreSQL)** | Isolated Database Subnets (AZ-A, AZ-B) | ECS Task Security Group on Port 5432 only | None (No outbound routes) | Database must never be accessible from the internet. Isolated subnets have no route to IGW or NAT. |
| **AWS VPC Endpoints (PrivateLink)** | Private App Subnets | ECS Task Security Group on Port 443 (HTTPS) | AWS Internal Private Backbone | Keeps API calls to ECR, Secrets Manager, KMS, and CloudWatch within AWS private network; eliminates data exfiltration over public internet. |
| **AWS Secrets Manager & KMS** | Managed AWS Service Plane | VPC Endpoints / IAM Authorized Principals | N/A | Centralized encrypted vault for application credentials and CMK keys. |
| **Amazon ECR** | Managed AWS Service Plane | VPC Endpoint (com.amazonaws.ecr.api/dkr) & CI/CD OIDC | N/A | Container image registry with tag immutability and vulnerability scanning enabled. |
| **AWS CloudTrail & CloudWatch** | Managed AWS Service Plane | Internal AWS audit log bus | Encrypted S3 Bucket / Log Groups | Audit trails and centralized log retention with tamper-proofing. |

---

## 5. Secret Retrieval Without Hardcoding

Hardcoding secrets in source code, Dockerfiles, or environment files causes catastrophic credential leaks. Our architecture enforces a **two-level secret retrieval mechanism**:

### Mechanism A: Native ECS Task Definition Secret Injection (Preferred for Container Startup)
1. **Creation:** Secrets (such as database credentials, API keys) are stored in AWS Secrets Manager and encrypted with a Customer Managed Key (CMK) in AWS KMS.
2. **Task Definition Mapping:** The ECS Task Definition references the secret ARN directly using the `secrets` attribute rather than plain `environment` strings:
   ```json
   "secrets": [
     {
       "name": "DB_PASSWORD",
       "valueFrom": "arn:aws:secretsmanager:ap-southeast-2:858093958225:secret:app/production/db-password-AbCdEf"
     }
   ]
   ```
3. **Execution Time Injection:**
   - When ECS Fargate provisions the task, the **ECS Task Execution Role** invokes `secretsmanager:GetSecretValue` and `kms:Decrypt`.
   - The AWS Fargate agent retrieves the plaintext value into container memory and injects it as an environment variable into the running process.
   - The secret is **never stored on disk**, never written to Git, never logged by ECS, and cannot be viewed in task definition JSON.

### Mechanism B: Dynamic Runtime Retrieval via AWS SDK (Preferred for Rotating Credentials)
1. The container application uses the AWS SDK (`boto3`, `@aws-sdk/client-secrets-manager`, etc.).
2. The application assumes the **ECS Task Role** automatically via container credentials metadata (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`).
3. The application requests secrets on demand in memory, caches them for a short TTL (e.g., 5 minutes), and gracefully refreshes when AWS Secrets Manager rotates credentials automatically.

---

## 6. IAM Role Architecture: CI/CD Pipeline vs. Application Runtime

Principle of Least Privilege (PoLP) requires strict separation of responsibilities across three dedicated roles:

```
+----------------------------------------------------------------------------------------------------+
|                                    IAM ROLE SEPARATION MATRIX                                      |
+------------------------------------+--------------------------------+------------------------------+
| 1. CI/CD Pipeline Role             | 2. ECS Task Execution Role     | 3. ECS Task Role             |
| (Provisioning & Image Push)        | (Infrastructure / Agent Level) | (Application Runtime Level)  |
+------------------------------------+--------------------------------+------------------------------+
| • Assumed via: GitHub/GitLab OIDC  | • Assumed by: ecs-tasks.       | • Assumed by: ecs-tasks.     |
|   (AssumeRoleWithWebIdentity)      |   amazonaws.com (Fargate agent)|   amazonaws.com (App process)|
| • Credentials: STS Short-lived     | • Credentials: ECS Agent       | • Credentials: Task Metadata |
| • Permissions:                     | • Permissions:                 | • Permissions:               |
|   - ecr:GetAuthorizationToken      |   - ecr:BatchGetImage          |   - s3:GetObject / PutObject |
|   - ecr:BatchCheckLayerAvailability|   - ecr:GetDownloadUrlForLayer |     (Only specific app bucket|
|   - ecr:PutImage (Specific repo)   |   - logs:CreateLogStream       |   - dynamodb:Query / PutItem |
|   - ecs:UpdateService (Specific)   |   - logs:PutLogEvents          |   - rds-db:connect (IAM DB)  |
|   - ecs:RegisterTaskDefinition     |   - secretsmanager:GetSecret   | • CANNOT pull ECR images     |
| • CANNOT access database or S3     |   - kms:Decrypt (CMK key ARN)  | • CANNOT read execution logs |
| • CANNOT assume Task Role directly | • CANNOT access application S3 | • CANNOT read root secrets   |
+------------------------------------+--------------------------------+------------------------------+
```

---

## 7. Prevention of Unauthorized Access to Production Resources

1. **Elimination of Static Credentials:**
   - Zero long-lived IAM access keys (`AKIA...`) are issued to human developers or stored in CI/CD pipeline variables.
   - CI/CD uses OpenID Connect (OIDC) identity federation with repository-bound trust policies (`token.actions.githubusercontent.com:sub` matching `repo:org/repo:ref:refs/heads/main`).
2. **Zero Inbound SSH / Bastionless Architecture:**
   - Ports 22 (SSH) and 3389 (RDP) are permanently blocked in all security groups.
   - If emergency container debugging is authorized, engineers authenticate via **AWS Systems Manager (SSM) Session Manager** with IAM MFA policies, session logging to S3/CloudWatch, and full command audit logs.
3. **AWS Organization Service Control Policies (SCPs):**
   - SCPs prevent root user logins, prohibit deleting CloudTrail or disabling GuardDuty, and restrict allowed AWS deployment regions to approved geographical zones.
4. **IAM Permission Boundaries & Least Privilege:**
   - All roles have strict permission boundaries preventing privilege escalation.
   - Resource-level ARNs (e.g., `arn:aws:s3:::my-app-prod-*`) are enforced on all policies.

---

## 8. Threat Modeling & Risk Mitigation Matrix

| # | Threat / Security Risk | Potential Impact | Layer | Engineered Mitigation in Architecture |
| :- | :--- | :--- | :--- | :--- |
| **1** | **Container Escape / Host Compromise** | Attacker breaches container runtime and accesses host or other containers. | Compute (Fargate) | • AWS Fargate microVM kernel isolation (dedicated virtualization boundary).<br>• Docker image runs as unprivileged non-root user (`UID 10001`).<br>• Read-only root filesystem (`readonlyRootFilesystem: true`).<br>• Linux capabilities dropped (`cap_drop: ALL`). |
| **2** | **Secret Leakage in Git or CI/CD Logs** | Database passwords or API keys exposed publicly. | Code & Pipeline | • Gitleaks automated secret scanning in pre-commit and CI/CD.<br>• AWS Secrets Manager integration (secrets never committed to Git).<br>• CI/CD variables masked.<br>• Automated Git history scanning and branch protection. |
| **3** | **Supply Chain Vulnerability (Base Image / Packages)** | Backdoored dependencies or known CVEs deployed to production. | Image & Build | • Minimal trusted base image (`python:3.11-slim` pinned to exact SHA256 digest).<br>• Multi-stage Docker build excluding compilers and package managers from final image.<br>• Trivy & ECR continuous vulnerability scanning blocking releases on Critical CVEs. |
| **4** | **Over-Permissive IAM & Lateral Movement** | Compromised pipeline or app allows attacker to modify infrastructure or exfiltrate data. | Identity (IAM) | • Dedicated role separation (CI/CD Deployer vs ECS Task Execution vs ECS Task Role).<br>• Resource-level ARNs and condition blocks.<br>• OIDC short-lived credentials.<br>• AWS GuardDuty anomaly detection enabled. |
| **5** | **Layer 7 DDoS, SQLi, and OWASP Exploits** | Application downtime, database breach via web exploits. | Network Edge | • AWS WAF attached to ALB with AWS Managed Rules (Core Rule Set, SQLi, Known Bad Inputs).<br>• Rate-based IP throttling.<br>• HTTP to HTTPS redirect with TLS 1.3 only.<br>• Private subnets prevent bypassing the ALB. |
| **6** | **Unencrypted Data & Unauthorized Internal Interception** | Sensitive customer data or state intercepted in transit or at rest. | Data & Storage | • End-to-end encryption in transit (HTTPS/TLS 1.3).<br>• Encryption at rest across all data stores (RDS, Secrets Manager, CloudWatch Logs, ECR) using dedicated AWS KMS Customer Managed Keys (CMKs). |

---

## 9. Critical Security Control: Example Terraform Configuration

Below is the production-grade Terraform configuration for the **ECS Task Execution Role and Customer Managed Key (CMK) Policy**, demonstrating strict least-privilege permissions:

```hcl
# Dedicated KMS Key for Secrets Manager & Container Logs
resource "aws_kms_key" "app_cmk" {
  description             = "KMS CMK for Containerized App Secrets and Logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowTaskExecutionRoleToDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ecs_execution_role.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ECS Task Execution Role (Least-Privilege)
resource "aws_iam_role" "ecs_execution_role" {
  name = "app-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Grant ECR Pull and CloudWatch Logging
resource "aws_iam_role_policy_attachment" "ecs_execution_standard" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Strictly Scoped Secrets Manager Access
resource "aws_iam_policy" "ecs_secrets_access" {
  name        = "app-ecs-secrets-policy"
  description = "Allows ECS execution role to fetch only application database secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetApplicationSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.db_credentials.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_secrets_attach" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.ecs_secrets_access.arn
}
```
