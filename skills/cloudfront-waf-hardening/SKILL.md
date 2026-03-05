---
name: cloudfront-waf-hardening
description: Harden ALB-backed services (LiteLLM, generic APIs) behind CloudFront + WAF. Creates CloudFront distribution with secret origin header, WAF Web ACL with path whitelist, and locks down ALB Security Group to CloudFront-only. Use when deploying any internet-facing ALB service that should not be directly accessible.
---

# CloudFront + WAF Hardening

Lock down an ALB-backed service so it is **only reachable through CloudFront**, with WAF path-level access control.

## When to Activate

- Deploying LiteLLM (or any API proxy) on EKS/ECS behind an ALB
- User asks to "add CloudFront" or "lock down ALB" or "hide the ALB"
- Hardening an existing internet-facing ALB
- Restricting public access to API-only paths (no Admin UI)

## Architecture

```
Client (HTTPS)
  |
  v
CloudFront Distribution
  |  adds X-CloudFront-Secret header
  v
ALB (HTTP :80, SG = CloudFront prefix list only)
  |
WAF Web ACL (default: Block)
  |  Rule: Allow IF secret header matches AND path in whitelist
  v
Backend (EKS Pod / ECS Task / EC2)
```

Three layers of defense:
1. **ALB Security Group** — only allows CloudFront IP ranges (AWS managed prefix list)
2. **WAF header verification** — blocks requests without the correct `X-CloudFront-Secret`
3. **WAF path whitelist** — even valid CloudFront requests are blocked if the path is not allowed

## Prerequisites

- AWS CLI v2 with sufficient IAM permissions (wafv2, cloudfront, ec2, elasticloadbalancing)
- An existing ALB with a known ARN
- The ALB's Security Group ID
- (Optional) An existing K8s Ingress group if using EKS ALB Controller

## Step-by-Step Procedure

### Step 1: Generate a CloudFront Secret

```bash
CF_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
echo "CloudFront Secret: $CF_SECRET"
```

Store this value securely. It will be configured in both CloudFront (origin header) and WAF (match rule).

### Step 2: Create CloudFront Distribution

Generate the distribution config with a custom origin header:

```bash
ALB_DNS="<alb-dns-name>"  # e.g. k8s-myapp-abc123.region.elb.amazonaws.com

python3 -c "
import json

config = {
    'CallerReference': '$(date +%s)',
    'Comment': 'Hardened distribution for ALB',
    'Enabled': True,
    'Origins': {
        'Quantity': 1,
        'Items': [{
            'Id': 'alb-origin',
            'DomainName': '$ALB_DNS',
            'CustomOriginConfig': {
                'HTTPPort': 80,
                'HTTPSPort': 443,
                'OriginProtocolPolicy': 'http-only',
                'OriginReadTimeout': 60,
                'OriginKeepaliveTimeout': 5
            },
            'CustomHeaders': {
                'Quantity': 1,
                'Items': [{
                    'HeaderName': 'X-CloudFront-Secret',
                    'HeaderValue': '$CF_SECRET'
                }]
            }
        }]
    },
    'DefaultCacheBehavior': {
        'TargetOriginId': 'alb-origin',
        'ViewerProtocolPolicy': 'redirect-to-https',
        'AllowedMethods': {
            'Quantity': 7,
            'Items': ['GET','HEAD','OPTIONS','PUT','POST','PATCH','DELETE'],
            'CachedMethods': {'Quantity': 2, 'Items': ['GET','HEAD']}
        },
        'CachePolicyId': '4135ea2d-6df8-44a3-9df3-4b5a84be39ad',
        'OriginRequestPolicyId': '216adef6-5c7f-47e4-b989-5492eafa07d3',
        'Compress': True
    },
    'PriceClass': 'PriceClass_200'
}

with open('/tmp/cf-dist.json', 'w') as f:
    json.dump({'DistributionConfig': config}, f)
print('Config written to /tmp/cf-dist.json')
"

aws cloudfront create-distribution --cli-input-json file:///tmp/cf-dist.json
```

Key config notes:
- **CachePolicyId** `4135ea2d-...` = AWS managed `CachingDisabled` (pass everything through)
- **OriginRequestPolicyId** `216adef6-...` = AWS managed `AllViewer` (forward all headers/query strings)
- **OriginReadTimeout** = 60s (max default; request AWS Support increase for >60s non-streaming)
- Streaming responses (SSE) are NOT limited by OriginReadTimeout

### Step 3: Lock Down ALB Security Group

Remove any `0.0.0.0/0` or specific IP rules, replace with CloudFront managed prefix list:

```bash
SG_ID="<alb-security-group-id>"
REGION="<aws-region>"

# Find CloudFront prefix list for your region
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists --region $REGION \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --query 'PrefixLists[0].PrefixListId' --output text)

echo "CloudFront prefix list: $CF_PREFIX_LIST"

# Add CloudFront prefix list to SG
aws ec2 authorize-security-group-ingress --region $REGION \
  --group-id $SG_ID \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$CF_PREFIX_LIST,Description=CloudFront-origin-facing}]"

# Remove old 0.0.0.0/0 or specific IP rules (list first, then revoke)
aws ec2 describe-security-group-rules --region $REGION \
  --filters "Name=group-id,Values=$SG_ID" --output table

# aws ec2 revoke-security-group-ingress --region $REGION \
#   --group-id $SG_ID --security-group-rule-ids <rule-id-to-remove>
```

> **IMPORTANT**: Review existing SG rules before revoking. Only remove rules that allowed direct public access. Keep internal/VPC rules intact.

### Step 4: Create WAF Web ACL with Path Whitelist

```bash
CF_SECRET="<your-cloudfront-secret>"

python3 -c "
import json, base64

secret_b64 = base64.b64encode('$CF_SECRET'.encode()).decode()

# Define allowed paths — customize per service
ALLOWED_PATHS = ['/v1/', '/chat/completions', '/health']

path_statements = []
for path in ALLOWED_PATHS:
    path_statements.append({
        'ByteMatchStatement': {
            'SearchString': base64.b64encode(path.encode()).decode(),
            'FieldToMatch': {'UriPath': {}},
            'TextTransformations': [{'Priority': 0, 'Type': 'LOWERCASE'}],
            'PositionalConstraint': 'STARTS_WITH'
        }
    })

acl = {
    'Name': 'alb-cloudfront-hardening',
    'Scope': 'REGIONAL',
    'DefaultAction': {'Block': {}},
    'Description': 'Allow only CloudFront requests to whitelisted API paths',
    'Rules': [{
        'Name': 'AllowCloudFrontAPIOnly',
        'Priority': 0,
        'Statement': {
            'AndStatement': {
                'Statements': [
                    {
                        'ByteMatchStatement': {
                            'SearchString': secret_b64,
                            'FieldToMatch': {'SingleHeader': {'Name': 'x-cloudfront-secret'}},
                            'TextTransformations': [{'Priority': 0, 'Type': 'NONE'}],
                            'PositionalConstraint': 'EXACTLY'
                        }
                    },
                    {
                        'OrStatement': {'Statements': path_statements}
                    }
                ]
            }
        },
        'Action': {'Allow': {}},
        'VisibilityConfig': {
            'SampledRequestsEnabled': True,
            'CloudWatchMetricsEnabled': True,
            'MetricName': 'AllowCloudFrontAPIOnly'
        }
    }],
    'VisibilityConfig': {
        'SampledRequestsEnabled': True,
        'CloudWatchMetricsEnabled': True,
        'MetricName': 'alb-cloudfront-hardening'
    }
}

with open('/tmp/waf-acl.json', 'w') as f:
    json.dump(acl, f)
print('WAF config written to /tmp/waf-acl.json')
"

aws wafv2 create-web-acl --region $REGION --cli-input-json file:///tmp/waf-acl.json
```

### Step 5: Associate WAF with ALB

```bash
WAF_ACL_ARN="<waf-web-acl-arn-from-step-4>"
ALB_ARN="<alb-arn>"

aws wafv2 associate-web-acl --region $REGION \
  --web-acl-arn "$WAF_ACL_ARN" \
  --resource-arn "$ALB_ARN"

# Verify association
aws wafv2 get-web-acl-for-resource --region $REGION \
  --resource-arn "$ALB_ARN" \
  --query 'WebACL.Name' --output text
```

### Step 6: Verify

Run these tests to confirm the hardening is complete:

```bash
CF_DOMAIN="<cloudfront-domain>.cloudfront.net"
API_KEY="<your-api-key>"

# Should PASS (200) — allowed API paths via CloudFront
curl -s -o /dev/null -w "%{http_code}" https://$CF_DOMAIN/health/liveliness
curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" https://$CF_DOMAIN/v1/models
curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
  https://$CF_DOMAIN/v1/chat/completions

# Should FAIL (403) — blocked paths
curl -s -o /dev/null -w "%{http_code}" https://$CF_DOMAIN/ui
curl -s -o /dev/null -w "%{http_code}" https://$CF_DOMAIN/
curl -s -o /dev/null -w "%{http_code}" https://$CF_DOMAIN/key/info
curl -s -o /dev/null -w "%{http_code}" https://$CF_DOMAIN/sso/login

# Should FAIL (403) — direct ALB access (no CloudFront header)
ALB_DNS="<alb-dns>"
curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS/v1/models
```

## Path Whitelist Templates

### LiteLLM (API proxy only, no Admin UI)

```python
ALLOWED_PATHS = ['/v1/', '/chat/completions', '/health']
```

### LiteLLM (API + key management)

```python
ALLOWED_PATHS = ['/v1/', '/chat/completions', '/health', '/key/', '/model/']
```

### LiteLLM (full access including Admin UI)

```python
ALLOWED_PATHS = ['/']  # Or remove path restriction, keep header-only check
```

### Generic API service

```python
ALLOWED_PATHS = ['/api/', '/health', '/.well-known/']
```

## Modifying Path Whitelist

To update allowed paths after initial setup:

```bash
# 1. Get current WAF config and lock token
aws wafv2 get-web-acl --name <acl-name> --scope REGIONAL --id <acl-id> --region <region>

# 2. Regenerate the WAF JSON with new ALLOWED_PATHS (same Python script as Step 4)
#    Add the LockToken to the JSON

# 3. Update
aws wafv2 update-web-acl --region <region> --cli-input-json file:///tmp/waf-update.json
```

## Timeout Considerations

| Component | Default | Recommended for LLM | Notes |
|-----------|---------|---------------------|-------|
| CloudFront OriginReadTimeout | 30s | 60s (max default) | Request AWS Support for >60s |
| ALB Idle Timeout | 60s | 600s | `aws elbv2 modify-load-balancer-attributes` |
| LiteLLM request_timeout | 600s | 600s | In proxy config YAML |
| K8s Ingress idle timeout | 60s | 600s | `alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.seconds=600` |

> **Streaming (SSE)**: CloudFront OriginReadTimeout does NOT apply to streaming responses. Once the first byte arrives within the timeout window, the stream continues indefinitely.

## Rollback

If something breaks:

```bash
# 1. Disassociate WAF from ALB
aws wafv2 disassociate-web-acl --region $REGION --resource-arn "$ALB_ARN"

# 2. Re-add public access to SG (if needed)
aws ec2 authorize-security-group-ingress --region $REGION \
  --group-id $SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# 3. Delete WAF Web ACL
aws wafv2 delete-web-acl --name <name> --scope REGIONAL --id <id> --lock-token <token> --region $REGION

# 4. Disable/delete CloudFront distribution
aws cloudfront get-distribution-config --id <dist-id>
# Set Enabled=false, update, wait, then delete
```

## Gotchas & Lessons Learned

1. **WAF SearchString is base64-encoded** in `--cli-input-json` — use `base64.b64encode()` in Python
2. **CloudFront `ForwardedValues` conflicts with CachePolicyId** — never set both; remove ForwardedValues entirely when using cache policies
3. **CloudFront OriginReadTimeout max is 60s by default** — need AWS Support ticket for higher values. Does NOT affect streaming.
4. **WAF association may silently fail** — always verify with `get-web-acl-for-resource` after associating
5. **SG prefix list vs CIDR** — use the AWS managed prefix list `com.amazonaws.global.cloudfront.origin-facing` (auto-updated), not hardcoded CloudFront IP ranges
6. **Test WAF from a clean network** — local proxy/VPN may interfere with WAF testing (Stash proxy, corporate VPN, etc.)

## Cost Impact

| Resource | Monthly Cost |
|----------|-------------|
| CloudFront | ~$0-5 (low traffic API) |
| WAF Web ACL | ~$5 + $0.60/M requests |
| No additional ALB cost | $0 (same ALB) |

Total additional cost: **~$5-10/month** for production-grade security hardening.
