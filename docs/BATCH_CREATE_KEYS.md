# LiteLLM 批量创建 API Key 指南

## 配置信息

| 配置项 | 值 |
|-------|------|
| DynamoDB 表名 | `litellm-api-keys` |
| AWS 区域 | `us-west-2` |

---

## 使用 manage-keys.sh 脚本（推荐）

### 创建单个 Key

```bash
./scripts/manage-keys.sh create \
  --user-id user_001 \
  --models claude-haiku-4-5,claude-sonnet-4-5 \
  --budget 10.0
```

**输出示例**：
```
✓ Created API Key: sk-a1b2c3d4e5f6...
  User ID: user_001
  Models: claude-haiku-4-5, claude-sonnet-4-5
  Budget: $10.00
```

### 批量创建 Key

```bash
# 创建 10 条 Key
for i in {1..10}; do
  ./scripts/manage-keys.sh create \
    --user-id "user_$(printf '%03d' $i)" \
    --models claude-haiku-4-5,claude-sonnet-3-5 \
    --budget 5.0
done
```

### 列出所有 Key

```bash
./scripts/manage-keys.sh list
```

### 删除 Key

```bash
./scripts/manage-keys.sh delete --key sk-xxx
```

### 更新 Key

```bash
./scripts/manage-keys.sh update \
  --key sk-xxx \
  --budget 20.0 \
  --models claude-opus-4-6-us,claude-sonnet-4-5
```

---

## 使用 AWS CLI 批量创建

### Python 脚本批量创建

```python
import boto3
import secrets
import time
from datetime import datetime

dynamodb = boto3.client('dynamodb', region_name='us-west-2')
TABLE_NAME = 'litellm-api-keys'

def create_api_key(user_id, models=None, budget=None, expires_days=None):
    """创建单个 API Key"""
    token = f"sk-{secrets.token_hex(32)}"
    created_at = int(time.time())

    item = {
        'token': {'S': token},
        'user_id': {'S': user_id},
        'created_at': {'N': str(created_at)}
    }

    if models:
        item['models'] = {'L': [{'S': m} for m in models]}

    if budget:
        item['max_budget'] = {'N': str(budget)}

    if expires_days:
        expires_at = created_at + (expires_days * 86400)
        item['expires_at'] = {'N': str(expires_at)}

    dynamodb.put_item(TableName=TABLE_NAME, Item=item)
    return token

# 批量创建 100 条 Key
timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
keys = []

for i in range(1, 101):
    user_id = f"batch_user_{timestamp}_{i:03d}"
    models = ["claude-haiku-4-5", "claude-sonnet-3-5"]
    budget = 1.0

    token = create_api_key(user_id, models, budget)
    keys.append({"user_id": user_id, "key": token})
    print(f"[{i}] {user_id}: {token}")

# 保存到文件
import json
with open(f"keys_{timestamp}.json", "w") as f:
    json.dump(keys, f, indent=2)

print(f"\n已创建 {len(keys)} 条 Key，保存到 keys_{timestamp}.json")
```

### Bash 脚本批量创建

```bash
#!/bin/bash
set -e

TABLE_NAME="litellm-api-keys"
REGION="us-west-2"
COUNT=50
PREFIX="test_user"

for i in $(seq 1 $COUNT); do
  TOKEN="sk-$(openssl rand -hex 32)"
  USER_ID="${PREFIX}_$(printf '%03d' $i)"
  CREATED_AT=$(date +%s)

  aws dynamodb put-item \
    --table-name $TABLE_NAME \
    --region $REGION \
    --item "{
      \"token\": {\"S\": \"$TOKEN\"},
      \"user_id\": {\"S\": \"$USER_ID\"},
      \"created_at\": {\"N\": \"$CREATED_AT\"},
      \"models\": {\"L\": [
        {\"S\": \"claude-haiku-4-5\"},
        {\"S\": \"claude-sonnet-3-5\"}
      ]},
      \"max_budget\": {\"N\": \"5.0\"}
    }"

  echo "[$i/$COUNT] Created: $USER_ID -> $TOKEN"
done

echo "✓ Batch creation completed"
```

---

## 使用 AWS DynamoDB Batch Write

适合大规模批量创建（一次最多 25 条）：

```python
import boto3
import secrets
import time

dynamodb = boto3.client('dynamodb', region_name='us-west-2')
TABLE_NAME = 'litellm-api-keys'

def batch_create_keys(count=100):
    """使用 batch_write_item 批量创建"""
    batch_size = 25  # DynamoDB 单次最多 25 条
    created_at = int(time.time())

    for batch_start in range(0, count, batch_size):
        batch_end = min(batch_start + batch_size, count)

        request_items = []
        for i in range(batch_start, batch_end):
            token = f"sk-{secrets.token_hex(32)}"
            user_id = f"batch_user_{i:05d}"

            request_items.append({
                'PutRequest': {
                    'Item': {
                        'token': {'S': token},
                        'user_id': {'S': user_id},
                        'created_at': {'N': str(created_at)},
                        'models': {'L': [
                            {'S': 'claude-haiku-4-5'},
                            {'S': 'claude-sonnet-3-5'}
                        ]},
                        'max_budget': {'N': '2.0'}
                    }
                }
            })

        # 批量写入
        dynamodb.batch_write_item(
            RequestItems={TABLE_NAME: request_items}
        )

        print(f"✓ Created {batch_end}/{count} keys")
        time.sleep(0.1)  # 避免限流

batch_create_keys(100)
```

---

## Key 参数说明

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `token` | String | ✓ | API Key (sk-xxx)，分区键 |
| `user_id` | String | ✓ | 用户标识 |
| `created_at` | Number | ✓ | 创建时间戳 (Unix timestamp) |
| `models` | List | | 允许的模型列表，空表示全部模型 |
| `max_budget` | Number | | 预算上限 (USD) |
| `expires_at` | Number | | 过期时间戳 (TTL) |
| `metadata` | Map | | 自定义元数据 |

---

## 导出所有 Key

### 导出为 JSON

```bash
aws dynamodb scan \
  --table-name litellm-api-keys \
  --region us-west-2 \
  --output json > all_keys.json
```

### 导出为 CSV

```bash
aws dynamodb scan \
  --table-name litellm-api-keys \
  --region us-west-2 \
  --output json | \
  jq -r '.Items[] | [.token.S, .user_id.S, .created_at.N] | @csv' > keys.csv
```

### Python 导出脚本

```python
import boto3
import json

dynamodb = boto3.client('dynamodb', region_name='us-west-2')
TABLE_NAME = 'litellm-api-keys'

def export_all_keys():
    """导出所有 Key"""
    keys = []
    last_evaluated_key = None

    while True:
        if last_evaluated_key:
            response = dynamodb.scan(
                TableName=TABLE_NAME,
                ExclusiveStartKey=last_evaluated_key
            )
        else:
            response = dynamodb.scan(TableName=TABLE_NAME)

        for item in response.get('Items', []):
            keys.append({
                'token': item['token']['S'],
                'user_id': item['user_id']['S'],
                'created_at': int(item['created_at']['N']),
                'models': [m['S'] for m in item.get('models', {}).get('L', [])],
                'budget': float(item.get('max_budget', {}).get('N', 0))
            })

        last_evaluated_key = response.get('LastEvaluatedKey')
        if not last_evaluated_key:
            break

    with open('all_keys_export.json', 'w') as f:
        json.dump(keys, f, indent=2)

    print(f"✓ Exported {len(keys)} keys to all_keys_export.json")

export_all_keys()
```

---

## Key 管理最佳实践

### 1. 使用 TTL 自动清理

```python
# 创建 30 天后过期的 Key
expires_at = int(time.time()) + (30 * 86400)

dynamodb.put_item(
    TableName=TABLE_NAME,
    Item={
        'token': {'S': f"sk-{secrets.token_hex(32)}"},
        'user_id': {'S': 'temp_user'},
        'created_at': {'N': str(int(time.time()))},
        'expires_at': {'N': str(expires_at)}  # TTL 字段
    }
)
```

### 2. 按用户查询 Key

```bash
aws dynamodb scan \
  --table-name litellm-api-keys \
  --filter-expression "user_id = :uid" \
  --expression-attribute-values '{":uid":{"S":"user_001"}}' \
  --region us-west-2
```

### 3. 删除过期 Key

```python
import boto3
import time

dynamodb = boto3.client('dynamodb', region_name='us-west-2')
TABLE_NAME = 'litellm-api-keys'

def delete_expired_keys():
    """手动删除过期 Key（TTL 自动清理有延迟）"""
    now = int(time.time())

    response = dynamodb.scan(TableName=TABLE_NAME)

    for item in response.get('Items', []):
        expires_at = item.get('expires_at', {}).get('N')
        if expires_at and int(expires_at) < now:
            token = item['token']['S']
            dynamodb.delete_item(
                TableName=TABLE_NAME,
                Key={'token': {'S': token}}
            )
            print(f"Deleted expired key: {token}")

delete_expired_keys()
```

---

## 验证 Key

### cURL 测试

```bash
curl -X POST https://litellm.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-haiku-4-5",
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 10
  }'
```

### Python 测试

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://litellm.example.com/v1",
    api_key="sk-xxx"
)

response = client.chat.completions.create(
    model="claude-haiku-4-5",
    messages=[{"role": "user", "content": "Hi"}],
    max_tokens=10
)

print(response.choices[0].message.content)
```

---

## 常见问题

### Q: Key 数量有上限吗？

A: DynamoDB 表无容量上限，但注意：
- 按需计费模式在高 QPS 下可能限流
- 建议监控 `ThrottledRequests` 指标
- 超过 10 万条 Key 建议切换到预置容量模式

### Q: 如何批量删除 Key？

A: 使用 Python batch_write_item:

```python
import boto3

dynamodb = boto3.client('dynamodb', region_name='us-west-2')
TABLE_NAME = 'litellm-api-keys'

# 批量删除指定前缀的 Key
response = dynamodb.scan(
    TableName=TABLE_NAME,
    FilterExpression='begins_with(user_id, :prefix)',
    ExpressionAttributeValues={':prefix': {'S': 'test_user'}}
)

delete_requests = [
    {'DeleteRequest': {'Key': {'token': {'S': item['token']['S']}}}}
    for item in response['Items']
]

# 分批删除（每次最多 25 条）
for i in range(0, len(delete_requests), 25):
    batch = delete_requests[i:i+25]
    dynamodb.batch_write_item(RequestItems={TABLE_NAME: batch})
```

### Q: 如何统计某用户的使用量？

A: 需要在应用层记录 API 调用量，DynamoDB 表仅存储 Key 元数据，不记录使用量。建议：
- 在 LiteLLM 应用中集成 CloudWatch Metrics
- 或使用 DynamoDB Streams 触发 Lambda 记录调用量

---

## 相关文档

- [API 使用指南](./API_USAGE.md)
- [故障排查指南](../TROUBLESHOOTING.md)
- [manage-keys.sh 脚本](../scripts/manage-keys.sh)
