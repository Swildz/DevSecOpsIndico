# Terraform & AWS IAM Mandatory Security Scenarios Analysis & Remediation
**Reference:** Task 3 Deliverables

---

## Scenario A: Overly Permissive IAM Policy

### Problematic Policy Proposal
A developer proposes the following policy for an application deployment role:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
```

### 1. Why This Policy Is Dangerous
- **Total Account Compromise (Privilege Escalation):** Granting `Action: "*"` and `Resource: "*"` effectively makes the role an AWS Account Administrator. Any compromised CI/CD token or malicious runner script can create administrative IAM users, exfiltrate private S3 data, delete production databases, or hijack billing.
- **Lateral Movement & Persistence:** An attacker can generate persistent IAM access keys, modify KMS key policies to lock administrators out (ransomware), or disable AWS CloudTrail and GuardDuty to hide their tracks.
- **Destructive Accidental Operations:** A minor syntax error in a Terraform script or Helm chart can delete critical shared infrastructure (e.g., VPC peering connections, DNS zones) because the deployment role lacks scoping guardrails.

### 2. Proposed Production-Grade Safer Approach

A secure deployment model enforces four core principles:

1. **Resource-Level ARNs:** Restrict actions to explicitly named target clusters, services, and repositories:
   ```hcl
   Resource = [
     "arn:aws:ecs:ap-southeast-2:858093958225:service/indico-api-production-cluster/indico-api-production-service",
     "arn:aws:ecr:ap-southeast-2:858093958225:repository/indico-api-production-api"
   ]
   ```
2. **Separation of Deployment vs. Application Runtime Roles:**
   - The **CI/CD Deployment Role** can only manage ECR images, register task definitions, and trigger ECS service updates. It is explicitly prohibited from querying databases, reading application secrets from Secrets Manager, or accessing application S3 buckets.
   - The **ECS Task Role** is assumed only by the running container process inside AWS Fargate and cannot perform deployment or IAM modifications.
3. **Short-Lived OIDC Credentials:**
   - Permanent IAM user access keys (`AKIA...`) are completely eliminated.
   - GitHub Actions / GitLab CI uses OpenID Connect (OIDC) identity federation to exchange an ephemeral OIDC token for short-lived AWS STS credentials with a maximum 15-minute validity (`DurationSeconds: 900`).
4. **Strict Trust Policy with Condition Keys:**
   - The role can only be assumed by the designated repository on the `main` branch:
     ```json
     "Condition": {
       "StringEquals": {
         "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
       },
       "StringLike": {
         "token.actions.githubusercontent.com:sub": "repo:Swildz/DevSecOpsIndico:ref:refs/heads/main"
       }
     }
     ```
5. **Restricted `iam:PassRole`:**
   - To prevent privilege escalation, `iam:PassRole` is strictly limited to passing only the vetted Task Execution Role and Task Role to the ECS service:
     ```json
     {
       "Effect": "Allow",
       "Action": "iam:PassRole",
       "Resource": [
         "arn:aws:iam::858093958225:role/app-ecs-execution-role",
         "arn:aws:iam::858093958225:role/app-ecs-task-role"
       ],
       "Condition": {
         "StringEquals": {
           "iam:PassedToService": "ecs-tasks.amazonaws.com"
         }
       }
     }
     ```

---

## Scenario B: Publicly Accessible Database (`0.0.0.0/0`)

### Problematic Terraform Configuration
A developer introduces an RDS instance or security group rule configured as follows:
```hcl
resource "aws_db_instance" "app_db" {
  allocated_storage   = 20
  engine              = "postgres"
  publicly_accessible = true # CRITICAL SECURITY RISK
  ...
}

resource "aws_security_group_rule" "insecure_ingress" {
  type        = "ingress"
  from_port   = 5432
  to_port     = 5432
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"] # CRITICAL SECURITY RISK
}
```

### How the DevSecOps Pipeline Detects and Blocks This Before Deployment

Our pipeline implements a **Multi-Layered Shift-Left Detection and Blocking Mechanism**:

```
[ Developer Branch ]
         │
         ▼
 1. Pre-Commit Hook (Local) ──> Detects 0.0.0.0/0 ingress; rejects git commit locally.
         │
         ▼
 2. CI Pipeline Checkov     ──> Fails on policy CKV_AWS_17 & CKV_AWS_260; exits with code 1.
         │
         ▼
 3. PR Branch Protection    ──> Blocks merge into 'main' until security checks pass.
         │
         ▼
 4. AWS Org SCP (Runtime)   ──> Prevents creation of public RDS instances at cloud level.
```

1. **Static IaC Scanning (Checkov in CI/CD):**
   - Checkov automatically evaluates the Terraform plan and HCL files during the `iac-scan` pipeline stage.
   - Two critical built-in policies specifically detect this misconfiguration:
     - **`CKV_AWS_17`**: *"Ensure all data stored in the RDS database is not publicly accessible"*.
     - **`CKV_AWS_260`**: *"Ensure no security groups allow ingress from 0.0.0.0/0 to port 5432"*.
   - Checkov reports a failure with exact file and line references and exits with code `1`, immediately halting the pipeline.
2. **Automated Pull Request Blocking:**
   - GitHub branch protection rules require the `Stage 5: IaC Security Scan (Checkov)` status check to report green before any PR can be merged into `main`.
3. **Compensating Cloud Control (AWS Service Control Policy - SCP):**
   - Even if an engineer attempts to bypass CI/CD, an AWS Organization Service Control Policy (SCP) enforces an account-wide guardrail denying `rds:CreateDBInstance` where `PubliclyAccessible == true`.

---

## Scenario C: Secret Exposure in Terraform Variables and State File

### Problematic Scenario
An application password is defined in Terraform variables:
```hcl
variable "db_password" {
  default = "SuperSecretP@ssword123!"
}
```
And consequently, the plaintext password is saved into `terraform.tfstate` or committed to Git.

### Comprehensive Containment, Remediation, and Prevention Strategy

Because Terraform state files store resource arguments in plaintext JSON, placing passwords in variables guarantees state exposure. The following protocol resolves immediate risks and establishes permanent prevention:

#### Phase 1: Immediate Containment (Triage within 15 Minutes)
1. **Treat Credential as Fully Compromised:**
   Assume any secret present in a state file or commit history has been exfiltrated.
2. **Immediate Rotation at Target Database:**
   Log into the database (via secure administrative session) and change the password immediately:
   ```sql
   ALTER USER app_prod_user WITH PASSWORD '<new-random-cryptographic-password>';
   ```
3. **Invalidate Running Sessions:**
   Terminate any existing connections matching the old credential.

#### Phase 2: Purging the Secret from Git History and Terraform State
1. **Purge Commit History:**
   If the variable file (`terraform.tfvars`) was committed to Git:
   - Use `git-filter-repo` or `BFG Repo-Cleaner` to purge the file across all historical commits:
     ```bash
     git filter-repo --invert-paths --path terraform/terraform.tfvars
     ```
   - Force-push updated branches and coordinate team cache invalidation.
2. **Sanitize Remote Terraform State:**
   - If the state file is hosted on Amazon S3, overwrite the state with a sanitized configuration.
   - Delete all previous unencrypted S3 object versions (`aws s3api delete-object-tagging / delete-objects`).
   - Rotate the AWS KMS key encrypting the S3 state bucket.

#### Phase 3: Permanent Prevention & Architectural Remediation
1. **Store Secrets Directly in AWS Secrets Manager (Not in Terraform HCL):**
   - Let AWS Secrets Manager generate and hold the credentials. Terraform only provisions the secret container and manages the ARN reference:
     ```hcl
     resource "aws_secretsmanager_secret" "db_credentials" {
       name        = "app/production/database"
       kms_key_id  = aws_kms_key.app_cmk.arn
     }
     ```
2. **Enforce `sensitive = true` and `ignore_changes`:**
   - If a random password must be bootstrapped via Terraform, use the `random_password` provider marked `sensitive = true` and set `lifecycle { ignore_changes = [secret_string] }` so future state runs never overwrite or expose rotated passwords.
3. **Ultimate Best Practice: Migrate to AWS IAM Database Authentication (Passwordless):**
   - Enable IAM Database Authentication on Amazon RDS PostgreSQL.
   - The ECS Fargate Task Role generates short-lived 15-minute authentication tokens via `rds-db:connect`.
   - **Result:** Static database passwords are completely eliminated from the architecture, Git repositories, and Terraform state files!
