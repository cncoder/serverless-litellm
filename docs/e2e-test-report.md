# serverless-litellm E2E Test Report

**Date:** 2026-03-04
**ALB Endpoint:** `your-alb.us-west-2.elb.amazonaws.com`
**Region:** us-west-2
**EKS Cluster:** litellm-eks-demo

---

## Summary

| Status | Count |
|--------|-------|
| PASS   | 12    |
| FAIL   | 0     |
| SKIP   | 1     |
| **Total** | **13** |

---

## Infrastructure Tests

| ID | Test Case | Status | Details |
|----|-----------|--------|---------|
| TC-04 | EKS Cluster exists | **PASS** | `litellm-eks-demo` ACTIVE, K8s v1.31 |
| TC-05 | RDS Instance running | **PASS** | `litellm-postgres-demo` available, db.t4g.micro, PostgreSQL |
| TC-06 | Pods healthy | **PASS** | 2/2 pods Running on Fargate, service endpoints: `10.x.x.x:4000, 10.x.x.x:4000` |

## API Tests

| ID | Test Case | Status | Details |
|----|-----------|--------|---------|
| TC-07 | Health check | **PASS** | `GET /health/liveliness` -> 200, body: `"I'm alive!"` |
| TC-08 | Auth enforcement | **PASS** | `GET /v1/models` without key -> 401, body: `Authentication Error, No api key passed in.` |
| TC-09 | Model listing | **PASS** | `GET /v1/models` with key -> 200, **237 models** listed including all Claude aliases |
| TC-10a | Chat - Haiku | **PASS** | `claude-haiku-4-5`: 17*3 = **51** (correct) |
| TC-10b | Chat - Sonnet | **PASS** | `claude-sonnet-4-6`: 25+37 = **62** (correct) |
| TC-10c | Chat - Opus | **PASS** | `claude-opus-4-6`: 99-42 = **57** (correct) |

## Multi-Model Routing (TC-13)

| Model Alias | Response Model | Status |
|-------------|---------------|--------|
| `claude-opus-4-6` | `claude-opus-4-6` | **PASS** |
| `claude-sonnet-4-6` | `claude-sonnet-4-6` | **PASS** |
| `claude-haiku-4-5` | `claude-haiku-4-5` | **PASS** |
| `claude-sonnet-4-5` | `claude-sonnet-4-5` | **PASS** |

All 4 model aliases correctly route to their respective Bedrock models.

## Idempotency (TC-14)

| Request | HTTP Code | Status |
|---------|-----------|--------|
| 1 | 200 | **PASS** |
| 2 | 200 | **PASS** |
| 3 | 200 | **PASS** |

3/3 identical requests succeeded consistently.

## Claude Code Integration

| ID | Test Case | Status | Details |
|----|-----------|--------|---------|
| TC-11 | Claude Code installed | **PASS** | v2.1.66 on reviewer EC2 (x.x.x.x) |
| TC-12 | Claude Code via LiteLLM | **PASS** | `claude -p "What is 2+2?"` -> `4` (correct) |

**Configuration:**
```bash
export ANTHROPIC_BASE_URL="http://your-alb.us-west-2.elb.amazonaws.com"
export ANTHROPIC_API_KEY="sk-..."
```

> **Note:** `ANTHROPIC_BASE_URL` must NOT include `/v1` suffix. Claude Code appends `/v1/messages` automatically.

## OpenClaw Integration (TC-17)

| ID | Test Case | Status | Details |
|----|-----------|--------|---------|
| TC-17 | OpenClaw via LiteLLM | **SKIP** | OpenClaw not installed on reviewer EC2. Requires device pairing, config files, and complex setup beyond automated testing scope. npm available (v10.8.2). |

**OpenClaw integration requirements:**
1. `npm install -g openclaw`
2. Configure device pairing (`~/.openclaw/devices/paired.json`)
3. Set provider to `amazon-bedrock` with LiteLLM ALB as baseUrl
4. Manual testing recommended

## Cleanup Readiness

### TC-15: Terraform Destroy Command

```bash
cd /home/ec2-user/serverless-litellm/terraform && terraform destroy -auto-approve
```

### TC-16: AWS Resources Created

| Resource Type | Name/ID | ARN/Details |
|---------------|---------|-------------|
| EKS Cluster | `litellm-eks-demo` | K8s v1.31, ACTIVE |
| RDS Instance | `litellm-postgres-demo` | db.t4g.micro, PostgreSQL |
| ALB | `k8s-litellm-litellmi-97043b6e08` | Active (current) |
| ALB (stale) | `k8s-litellmshared-d708c540e0` | From previous deployment |
| ALB (stale) | `k8s-litellmshared-ebe1713dad` | From previous deployment |
| ECR | `litellm-demo` | Custom LiteLLM image |
| ECR | `litellm-prod-litellm-proxy` | Production proxy image |
| Secret | `litellm-master-key-demo` | Master API key |
| Secret | `litellm-rds-password-demo` | RDS password |
| IAM Role | `litellm-demo-alb-controller-role` | ALB Ingress Controller |
| IAM Role | `litellm-demo-ec2` | EC2 deploy instance |
| IAM Role | `litellm-demo-eks-cluster-role` | EKS cluster |
| IAM Role | `litellm-demo-fargate-execution-role` | Fargate pods |
| IAM Role | `litellm-demo-litellm-pod-role` | LiteLLM pod IRSA |

---

## Bugs Found

1. **Stale ALBs** - 2 previous ALBs (`k8s-litellmshared-*`) still exist from earlier deployments. These should be cleaned up to avoid cost.

## Recommendations

1. **Clean up stale ALBs** - Delete the 2 old ALBs that are no longer in use
2. **HTTPS setup** - Current deployment is HTTP-only. For production, configure ACM certificate + HTTPS ingress
3. **ANTHROPIC_BASE_URL documentation** - Document that Claude Code requires the base URL WITHOUT `/v1` suffix
4. **OpenClaw integration** - Requires manual setup and testing due to device pairing requirements
