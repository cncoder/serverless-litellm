FROM ghcr.io/berriai/litellm:main-stable

# 安装 DynamoDB 认证依赖
COPY requirements-custom.txt /tmp/requirements-custom.txt
RUN pip install --no-cache-dir -r /tmp/requirements-custom.txt && rm /tmp/requirements-custom.txt

# 复制自定义认证模块
COPY custom_auth.py /app/custom_auth.py

WORKDIR /app
