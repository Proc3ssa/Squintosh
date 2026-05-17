#!/usr/bin/env bash
# SquishIt — API Gateway Setup
# Run AFTER step5-lambda-deploy.sh
set -euo pipefail

# ─────────────────────────────────────────────
# 0. VARIABLES
# ─────────────────────────────────────────────
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
API_LAMBDA="squishit-api"
API_NAME="squishit-api-gateway"
STAGE_NAME="prod"

echo "Account ID : $AWS_ACCOUNT_ID"
echo "Region     : $AWS_REGION"
echo ""


# ─────────────────────────────────────────────
# 1. CREATE THE REST API
# ─────────────────────────────────────────────
echo "Creating REST API..."
API_ID=$(aws apigateway create-rest-api \
  --name "$API_NAME" \
  --description "SquishIt image compressor API" \
  --region "$AWS_REGION" \
  --query "id" --output text)

echo "  ✓ API created — ID: $API_ID"

# Get the root resource ID (/)
ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --region "$AWS_REGION" \
  --query "items[?path=='/'].id" --output text)

echo "  ✓ Root resource ID: $ROOT_ID"


# ─────────────────────────────────────────────
# 2. CREATE /upload-url RESOURCE + POST METHOD
# ─────────────────────────────────────────────
echo ""
echo "Creating /upload-url resource..."

UPLOAD_URL_ID=$(aws apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$ROOT_ID" \
  --path-part "upload-url" \
  --region "$AWS_REGION" \
  --query "id" --output text)

# POST method
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$UPLOAD_URL_ID" \
  --http-method POST \
  --authorization-type NONE \
  --region "$AWS_REGION" > /dev/null

# Lambda integration
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${API_LAMBDA}"
aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$UPLOAD_URL_ID" \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ POST /upload-url → squishit-api"

# OPTIONS method for CORS preflight
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$UPLOAD_URL_ID" \
  --http-method OPTIONS \
  --authorization-type NONE \
  --region "$AWS_REGION" > /dev/null

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$UPLOAD_URL_ID" \
  --http-method OPTIONS \
  --type MOCK \
  --request-templates '{"application/json":"{\"statusCode\":200}"}' \
  --region "$AWS_REGION" > /dev/null

aws apigateway put-method-response \
  --rest-api-id "$API_ID" \
  --resource-id "$UPLOAD_URL_ID" \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{
    "method.response.header.Access-Control-Allow-Headers": false,
    "method.response.header.Access-Control-Allow-Methods": false,
    "method.response.header.Access-Control-Allow-Origin": false
  }' \
  --region "$AWS_REGION" > /dev/null

aws apigateway put-integration-response \
  --rest-api-id "$API_ID" \
  --resource-id "$UPLOAD_URL_ID" \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{
    "method.response.header.Access-Control-Allow-Headers": "'"'"'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"'"'",
    "method.response.header.Access-Control-Allow-Methods": "'"'"'POST,OPTIONS'"'"'",
    "method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'"
  }' \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ OPTIONS /upload-url (CORS preflight)"


# ─────────────────────────────────────────────
# 3. CREATE /list RESOURCE + GET METHOD
# ─────────────────────────────────────────────
echo ""
echo "Creating /list resource..."

LIST_ID=$(aws apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$ROOT_ID" \
  --path-part "list" \
  --region "$AWS_REGION" \
  --query "id" --output text)

# GET method
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$LIST_ID" \
  --http-method GET \
  --authorization-type NONE \
  --region "$AWS_REGION" > /dev/null

# Lambda integration
aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$LIST_ID" \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ GET /list → squishit-api"

# OPTIONS for CORS
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$LIST_ID" \
  --http-method OPTIONS \
  --authorization-type NONE \
  --region "$AWS_REGION" > /dev/null

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$LIST_ID" \
  --http-method OPTIONS \
  --type MOCK \
  --request-templates '{"application/json":"{\"statusCode\":200}"}' \
  --region "$AWS_REGION" > /dev/null

aws apigateway put-method-response \
  --rest-api-id "$API_ID" \
  --resource-id "$LIST_ID" \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{
    "method.response.header.Access-Control-Allow-Headers": false,
    "method.response.header.Access-Control-Allow-Methods": false,
    "method.response.header.Access-Control-Allow-Origin": false
  }' \
  --region "$AWS_REGION" > /dev/null

aws apigateway put-integration-response \
  --rest-api-id "$API_ID" \
  --resource-id "$LIST_ID" \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{
    "method.response.header.Access-Control-Allow-Headers": "'"'"'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"'"'",
    "method.response.header.Access-Control-Allow-Methods": "'"'"'GET,OPTIONS'"'"'",
    "method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'"
  }' \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ OPTIONS /list (CORS preflight)"


# ─────────────────────────────────────────────
# 4. GRANT API GATEWAY PERMISSION TO INVOKE LAMBDA
# ─────────────────────────────────────────────
echo ""
echo "Granting API Gateway permission to invoke Lambda..."

aws lambda add-permission \
  --function-name "$API_LAMBDA" \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$AWS_REGION" > /dev/null

echo "  ✓ Permission granted"


# ─────────────────────────────────────────────
# 5. DEPLOY TO PROD STAGE
# ─────────────────────────────────────────────
echo ""
echo "Deploying to '$STAGE_NAME' stage..."

aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --stage-description "SquishIt production stage" \
  --description "Initial deployment" \
  --region "$AWS_REGION" > /dev/null

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE_NAME}"
echo "  ✓ Deployed!"


# ─────────────────────────────────────────────
# 6. QUICK SMOKE TEST
# ─────────────────────────────────────────────
echo ""
echo "Running smoke test on GET /list..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/list")

if [ "$HTTP_STATUS" = "200" ]; then
  echo "  ✓ GET /list returned 200 OK"
else
  echo "  ⚠ GET /list returned HTTP $HTTP_STATUS (may need a moment to warm up)"
fi


# ─────────────────────────────────────────────
# 7. PRINT FINAL SUMMARY
# ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              ✅  API GATEWAY COMPLETE                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  API URL:                                                ║"
echo "║  $API_URL"
echo "║                                                          ║"
echo "║  Endpoints:                                              ║"
echo "║  POST $API_URL/upload-url"
echo "║  GET  $API_URL/list"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "⚡ FINAL STEP: Open index.html and replace:"
echo "   YOUR_API_GATEWAY_URL  →  $API_URL"
echo ""
echo "   sed -i \"s|YOUR_API_GATEWAY_URL|$API_URL|g\" index.html"
