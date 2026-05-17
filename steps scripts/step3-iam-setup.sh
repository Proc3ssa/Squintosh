# SquishIt — IAM Setup Guide
# Run these commands in order using AWS CLI
# Prerequisites: AWS CLI installed and configured (aws configure)

# ─────────────────────────────────────────────
# 0. SET YOUR VARIABLES (edit these)
# ─────────────────────────────────────────────
export AWS_REGION="us-east-1"                          # your preferred region
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export RAW_BUCKET="squishit-raw-uploads-${AWS_ACCOUNT_ID}"
export COMPRESSED_BUCKET="squishit-compressed-${AWS_ACCOUNT_ID}"

echo "Account ID : $AWS_ACCOUNT_ID"
echo "Region     : $AWS_REGION"
echo "Raw bucket : $RAW_BUCKET"
echo "Compressed : $COMPRESSED_BUCKET"


# ─────────────────────────────────────────────
# 1. TRUST POLICY (lets Lambda assume the role)
# ─────────────────────────────────────────────
cat > /tmp/lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF


# ─────────────────────────────────────────────
# 2. CREATE THE IAM ROLE
# ─────────────────────────────────────────────
aws iam create-role \
  --role-name squishit-lambda-role \
  --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
  --description "SquishIt Lambda execution role"

# Save the role ARN for later
export LAMBDA_ROLE_ARN=$(aws iam get-role \
  --role-name squishit-lambda-role \
  --query "Role.Arn" --output text)

echo "Role ARN: $LAMBDA_ROLE_ARN"


# ─────────────────────────────────────────────
# 3. ATTACH AWS MANAGED POLICY — Basic Lambda Logs
#    (allows Lambda to write to CloudWatch)
# ─────────────────────────────────────────────
aws iam attach-role-policy \
  --role-name squishit-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole


# ─────────────────────────────────────────────
# 4. CREATE INLINE S3 POLICY
#    - Read from raw bucket
#    - Write to compressed bucket
#    - List compressed bucket (for the /list API)
#    - Generate presigned URLs (via s3:GetObject on compressed)
# ─────────────────────────────────────────────
cat > /tmp/squishit-s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadRawBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:HeadObject"
      ],
      "Resource": "arn:aws:s3:::${RAW_BUCKET}/*"
    },
    {
      "Sid": "WriteCompressedBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:HeadObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${COMPRESSED_BUCKET}",
        "arn:aws:s3:::${COMPRESSED_BUCKET}/*"
      ]
    },
    {
      "Sid": "PresignedURLsForRawBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::${RAW_BUCKET}/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name squishit-lambda-role \
  --policy-name squishit-s3-access \
  --policy-document file:///tmp/squishit-s3-policy.json

echo "✓ S3 policy attached"


# ─────────────────────────────────────────────
# 5. VERIFY — list policies on the role
# ─────────────────────────────────────────────
echo ""
echo "=== Attached managed policies ==="
aws iam list-attached-role-policies \
  --role-name squishit-lambda-role \
  --query "AttachedPolicies[].PolicyName" \
  --output table

echo ""
echo "=== Inline policies ==="
aws iam list-role-policies \
  --role-name squishit-lambda-role \
  --query "PolicyNames" \
  --output table

echo ""
echo "✅ IAM setup complete!"
echo ""
echo "Save these for the next steps:"
echo "  LAMBDA_ROLE_ARN  = $LAMBDA_ROLE_ARN"
echo "  RAW_BUCKET       = $RAW_BUCKET"
echo "  COMPRESSED_BUCKET= $COMPRESSED_BUCKET"
echo "  AWS_REGION       = $AWS_REGION"
