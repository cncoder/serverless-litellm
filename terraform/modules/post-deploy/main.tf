# Wait for EKS cluster to be ready
resource "null_resource" "wait_for_cluster" {
  depends_on = [var.eks_cluster_endpoint]

  provisioner "local-exec" {
    command = "sleep 30"
  }
}

# Build and push Docker image to ECR
resource "null_resource" "build_push_image" {
  depends_on = [null_resource.wait_for_cluster]

  triggers = {
    dockerfile_hash = filemd5("${path.root}/../docker/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Login to ECR
      aws ecr get-login-password --region ${var.aws_region} | \
        docker login --username AWS --password-stdin ${var.ecr_repository_url}

      # Build and push (linux/amd64 required for Fargate x86_64)
      docker build --platform linux/amd64 -t litellm-custom ${path.root}/../docker/
      docker tag litellm-custom:latest ${var.ecr_repository_url}:latest
      docker push ${var.ecr_repository_url}:latest

      echo "Docker image pushed to ${var.ecr_repository_url}:latest"
    EOT
  }
}

# Deploy Kubernetes resources
resource "null_resource" "deploy_litellm" {
  depends_on = [null_resource.build_push_image]

  triggers = {
    config_hash = filemd5("${path.root}/../kubernetes/configmap.yaml")
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Update kubeconfig
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

      # Create namespace
      kubectl apply -f ${path.root}/../kubernetes/namespace.yaml

      # Create service account with IRSA role ARN annotation
      export LITELLM_POD_ROLE_ARN="${var.litellm_pod_role_arn}"
      envsubst < ${path.root}/../kubernetes/serviceaccount.yaml | kubectl apply -f -

      # Delete legacy K8s Secret if it exists (secrets now injected via Init Container from Secrets Manager)
      kubectl delete secret litellm-secrets -n litellm --ignore-not-found

      # Apply ConfigMap
      kubectl apply -f ${path.root}/../kubernetes/configmap.yaml

      # Apply deployment with ECR image + Secrets Manager substitution
      export ECR_REPOSITORY_URL="${var.ecr_repository_url}"
      export MASTER_KEY_SECRET_ID="${var.master_key_secret_id}"
      export DB_PASSWORD_SECRET_ID="${var.db_password_secret_id}"
      export DATABASE_URL_BASE="${var.database_url_base}"
      export AWS_REGION_VAL="${var.aws_region}"
      envsubst < ${path.root}/../kubernetes/deployment.yaml | kubectl apply -f -

      # Apply service
      kubectl apply -f ${path.root}/../kubernetes/service.yaml

      # Apply HPA and PDB
      kubectl apply -f ${path.root}/../kubernetes/hpa.yaml
      kubectl apply -f ${path.root}/../kubernetes/pdb.yaml

      # Apply Ingress with variable substitution
      export LITELLM_HOST="${var.litellm_host}"
      export BOT_HOST="${var.bot_host}"
      export ACM_CERTIFICATE_ARN="${var.acm_certificate_arn}"

      if [ -z "${var.acm_certificate_arn}" ]; then
        echo "No ACM certificate provided - deploying HTTP only (port 80)"
        envsubst < ${path.root}/../kubernetes/ingress-http.yaml | kubectl apply -f -
      else
        echo "ACM certificate found - deploying HTTPS (port 443)"
        envsubst < ${path.root}/../kubernetes/ingress.yaml | kubectl apply -f -
      fi

      # Conditionally apply Cognito ingress
      if [ "${var.enable_cognito}" = "true" ]; then
        export COGNITO_USER_POOL_ARN="${var.cognito_user_pool_arn}"
        export COGNITO_USER_POOL_CLIENT_ID="${var.cognito_user_pool_client_id}"
        export COGNITO_USER_POOL_DOMAIN="${var.cognito_user_pool_domain}"
        # Remove non-cognito UI ingress and apply cognito version
        kubectl delete ingress litellm-ingress-ui -n litellm --ignore-not-found
        envsubst < ${path.root}/../kubernetes/ingress-cognito.yaml | kubectl apply -f -
        echo "Cognito UI authentication enabled"
      else
        echo "Cognito UI authentication disabled"
      fi

      # Wait for pods to be ready (Fargate may take longer)
      echo "Waiting for LiteLLM pods to be ready (Fargate cold start may take 1-2 minutes)..."
      kubectl wait --for=condition=Ready pods -l app=litellm -n litellm --timeout=600s || true

      # Wait for ALB to be provisioned
      echo "Waiting for ALB to be provisioned..."
      for i in $(seq 1 60); do
        ALB_DNS=$(kubectl get ingress -n litellm litellm-ingress-ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ ! -z "$ALB_DNS" ]; then
          echo ""
          echo "============================================"
          echo "ALB DNS: $ALB_DNS"
          echo "Create CNAME record: ${var.litellm_host} -> $ALB_DNS"
          if [ "${var.bot_host}" != "bot.example.com" ]; then
            echo "Create CNAME record: ${var.bot_host} -> $ALB_DNS"
          fi
          echo "============================================"
          break
        fi
        sleep 5
      done
    EOT
  }
}
