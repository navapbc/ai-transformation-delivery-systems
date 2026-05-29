---
applyTo: "**/*.tf,**/*.tfvars,**/*.tf.json,**/*.bicep,**/*.bicepparam,**/*.hcl,**/*.template.json,**/*.template.yaml,**/*.template.yml,**/Pulumi.yaml,**/Chart.yaml,**/values.yaml,**/cdk.json,**/kustomization.yaml"
---

# IaC Path Instructions

When reviewing changes to infrastructure-as-code files, apply the
`compliance` perspective from `.github/copilot-instructions.md` with
heightened attention to the following CMS ARS 5.1 / NIST SP 800-53 Rev 5
control families. The full check list is in `.skills/iac-compliance/SKILL.md`;
read that file before reviewing changes to any file matched by this path
pattern.

## High-yield checks for IaC

These are the findings that most frequently appear in IaC reviews; prioritize
them and emit `compliance` comments using the template in the global
instructions.

### Critical-severity flags (request human review attention immediately)

- Inbound security group / NACL rules allowing `0.0.0.0/0` or `::/0` on
  TCP 22 (SSH), TCP 3389 (RDP), or protocol `-1` / `all`. **NIST AC-4.**
- IAM policy with `"Action": "*"` AND `"Resource": "*"` AND no scoping
  `Condition` block. **NIST AC-3.**
- `aws_db_instance` with `publicly_accessible = true`. **NIST AC-22.**
- `aws_s3_bucket_public_access_block` missing or with any of the four
  settings (`block_public_acls`, `block_public_policy`, `ignore_public_acls`,
  `restrict_public_buckets`) set to `false`. **NIST AC-22.**
- Hardcoded password literals on RDS / ElastiCache / MSK / database
  resources. **NIST IA-5.**

### High-severity flags

- `storage_encrypted = false` (or omitted) on RDS, EBS, EFS. **NIST SC-12/SC-28.**
- `aws_cloudtrail` with `is_multi_region_trail = false` or
  `enable_log_file_validation = false`. **NIST AU-2.**
- IAM users / roles attached to `AdministratorAccess` or equivalent. **NIST AC-3.**
- `deletion_protection = false` on RDS / Aurora / DynamoDB **in production**
  (infer from `Environment` tag, workspace name, or absence of a `dev`
  indicator). **NIST CM-6.**
- Lambda runtimes on the deprecation list: `nodejs14.x`, `nodejs12.x`,
  `python3.7`, `python3.8`, `java8`, `java8.al2`, `go1.x`, `dotnetcore3.1`,
  `dotnet5.0`, `dotnet6`, `ruby2.7`. **NIST SI-2.**
- Kubernetes containers with `runAsNonRoot: false`, `runAsUser: 0`,
  `privileged: true`, or `allowPrivilegeEscalation: true` (or absent).
  **NIST CM-6.**

### Medium-severity flags

- Public-facing ALB / API Gateway without an associated
  `aws_wafv2_web_acl_association`. **NIST SC-5.**
- Two or more required tags missing (the required set is `Environment`,
  `Owner` or `Team`, `Project`, `CostCenter`). **NIST CM-2.**
- `aws_cloudwatch_log_group` without `retention_in_days` set. **NIST AU-9.**
- KMS-encrypted resources (`storage_encrypted = true`) without an explicit
  `kms_key_id` — uses default AWS-managed key rather than CMK. **NIST SC-13.**

### Low-severity flags

- One required tag missing. **NIST CM-2.**
- Container images tagged `latest` rather than a pinned digest or version.
  **NIST CM-6.**
- Terraform module sources without a pinned `version =` constraint.
  **NIST CM-8.**
- Lambda functions without `tracing_config { mode = "Active" }`. **NIST RA-5.**

## Environment-aware relaxations

Apply production-strictness by default. Relax to LOW only when context is
unambiguous (clear `Environment = "dev"` tag, workspace named `dev`, etc.):

- `deletion_protection = false` → LOW in dev environments
- `skip_final_snapshot = true` → LOW in dev environments
- `force_destroy = true` on S3 → LOW in dev environments
- Missing WAF on ALB → LOW for documented internal-only endpoints

## Comment formatting reminders

All comments on IaC files must:

1. Use the `compliance(<severity>):` Conventional Comments label.
2. Cite the NIST 800-53 Rev 5 control ID (mandatory) and the CMS ARS 5.1
   tailoring (when it differs from NIST).
3. Provide a `` ```suggestion `` block when the fix replaces lines at the
   comment's location, OR a `` ```hcl `` / `` ```yaml `` block when the fix
   requires adding a new resource. Never put non-applicable code into a
   `` ```suggestion `` fence.
4. Reference the specific resource (`resource_type.resource_name`) being
   discussed where it isn't already obvious from the file/line context.
