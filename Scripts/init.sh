#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""

# ============================================================
# M346 Projekt: FaceRecognition Service (S3 -> Lambda -> S3)
# Init-Script (idempotent)
#
# Erstellt:
# - S3 In-Bucket (Upload)
# - S3 Out-Bucket (JSON Resultate)
# - IAM Rolle + Policy fuer Lambda
# - Lambda Funktion (Runtime dotnet8) inkl. Env OUTPUT_BUCKET
# - S3 Trigger (ObjectCreated -> Lambda)
#
# Voraussetzungen:
# - AWS CLI v2 konfiguriert (Learner Lab Credentials)
# - dotnet SDK 8 installiert
# - zip installiert (Linux) bzw. verfügbar (Git Bash/WSL)
#
# Nutzung:
#   ./Scripts/init.sh
#   ENV-Overrides (optional):
#     AWS_REGION=eu-central-1
#     PROJECT_PREFIX=m346-facerec
#     IN_BUCKET=<name>
#     OUT_BUCKET=<name>
#     LAMBDA_NAME=<name>
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_PREFIX="${PROJECT_PREFIX:-m346-facerec}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
  echo "FEHLER: AWS CLI ist nicht konfiguriert oder Credentials fehlen (sts get-caller-identity fehlgeschlagen)."
  exit 1
fi

# Bucket-Namen muessen global eindeutig sein -> Account-ID verwenden
IN_BUCKET="${IN_BUCKET:-${PROJECT_PREFIX}-${ACCOUNT_ID}-in}"
OUT_BUCKET="${OUT_BUCKET:-${PROJECT_PREFIX}-${ACCOUNT_ID}-out}"

LAMBDA_NAME="${LAMBDA_NAME:-${PROJECT_PREFIX}-lambda}"
ROLE_NAME="${ROLE_NAME:-${PROJECT_PREFIX}-lambda-role}"
POLICY_NAME="${POLICY_NAME:-${PROJECT_PREFIX}-lambda-policy}"
STATEMENT_ID="${STATEMENT_ID:-${PROJECT_PREFIX}-s3invoke}"

echo "=== Konfiguration ==="
echo "Region:        ${AWS_REGION}"
echo "Account ID:    ${ACCOUNT_ID}"
echo "In-Bucket:     ${IN_BUCKET}"
echo "Out-Bucket:    ${OUT_BUCKET}"
echo "Lambda Name:   ${LAMBDA_NAME}"
echo "Role Name:     ${ROLE_NAME}"
echo "Policy Name:   ${POLICY_NAME}"
echo "====================="

# ----------------------------
# Helpers
# ----------------------------
bucket_exists() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

create_bucket_if_missing() {
  local bucket="$1"
  if bucket_exists "$bucket"; then
    echo "OK: Bucket existiert bereits: ${bucket}"
    return
  fi

  echo "Erstelle Bucket: ${bucket}"
  # Region-spezifisch: us-east-1 ohne LocationConstraint, sonst mit
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${bucket}" >/dev/null
  else
    aws s3api create-bucket       --bucket "${bucket}"       --region "${AWS_REGION}"       --create-bucket-configuration LocationConstraint="${AWS_REGION}" >/dev/null
  fi

  # Optional: Versioning (hilft bei Nachvollziehbarkeit)
  aws s3api put-bucket-versioning --bucket "${bucket}" --versioning-configuration Status=Enabled >/dev/null

  echo "OK: Bucket erstellt: ${bucket}"
}

render_policy() {
  # Ersetzt Platzhalter ${IN_BUCKET}/${OUT_BUCKET} in Template (bash here-doc replacement)
  local template_path="${PROJECT_DIR}/infra/lambda-policy.template.json"
  local out_path="$1"
  sed     -e "s/\${IN_BUCKET}/${IN_BUCKET}/g"     -e "s/\${OUT_BUCKET}/${OUT_BUCKET}/g"     "${template_path}" > "${out_path}"
}

ensure_iam_role_and_policy() {
  echo "=== IAM Rolle/Policy ==="

  local role_arn
  role_arn="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text 2>/dev/null || true)"

  if [[ -z "${role_arn}" || "${role_arn}" == "None" ]]; then
    echo "Erstelle IAM Rolle: ${ROLE_NAME}"
    aws iam create-role       --role-name "${ROLE_NAME}"       --assume-role-policy-document "file://${PROJECT_DIR}/infra/iam-trust-policy.json" >/dev/null
  else
    echo "OK: Rolle existiert: ${ROLE_NAME}"
  fi

  role_arn="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"
  echo "Role ARN: ${role_arn}"

  # Policy erstellen/finden
  local policy_arn
  policy_arn="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text 2>/dev/null || true)"

  local rendered_policy="${PROJECT_DIR}/infra/lambda-policy.rendered.json"
  render_policy "${rendered_policy}"

  if [[ -z "${policy_arn}" || "${policy_arn}" == "None" ]]; then
    echo "Erstelle IAM Policy: ${POLICY_NAME}"
    policy_arn="$(aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "file://${rendered_policy}" --query Policy.Arn --output text)"
  else
    echo "OK: Policy existiert: ${POLICY_NAME}"
    # Policy aktualisieren (neue Version setzen)
    # IAM erlaubt max. 5 Versionen -> alte loeschen, falls notwendig
    local versions
    versions="$(aws iam list-policy-versions --policy-arn "${policy_arn}" --query "Versions[?IsDefaultVersion==\\`false\\`].VersionId" --output text || true)"
    # Wenn bereits 4 non-default vorhanden -> eine loeschen
    local count
    count="$(aws iam list-policy-versions --policy-arn "${policy_arn}" --query "length(Versions[?IsDefaultVersion==\\`false\\`])" --output text)"
    if [[ "${count}" -ge 4 ]]; then
      # Loesche die aelteste non-default Version
      local oldest
      oldest="$(aws iam list-policy-versions --policy-arn "${policy_arn}" --query "sort_by(Versions[?IsDefaultVersion==\\`false\\`], &CreateDate)[0].VersionId" --output text)"
      aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${oldest}" >/dev/null || true
    fi
    aws iam create-policy-version --policy-arn "${policy_arn}" --policy-document "file://${rendered_policy}" --set-as-default >/dev/null
  fi

  echo "Policy ARN: ${policy_arn}"

  # Policy an Rolle haengen (falls noch nicht)
  local attached
  attached="$(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query "AttachedPolicies[?PolicyArn=='${policy_arn}'] | length(@)" --output text)"
  if [[ "${attached}" == "0" ]]; then
    echo "Hänge Policy an Rolle: ${POLICY_NAME} -> ${ROLE_NAME}"
    aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${policy_arn}" >/dev/null
  else
    echo "OK: Policy ist bereits an Rolle angehängt"
  fi

  echo "${role_arn}"
}

ensure_lambda() {
  local role_arn="$1"
  echo "=== Lambda Deploy ==="

  # Build + Package
  local build_dir="${PROJECT_DIR}/dist"
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"

  echo "dotnet publish (net8.0) ..."
  dotnet publish "${PROJECT_DIR}/FaceRecognitionLambda.csproj" -c Release -o "${build_dir}" >/dev/null

  local zip_path="${PROJECT_DIR}/dist/lambda.zip"
  (cd "${build_dir}" && zip -qr "${zip_path}" .)

  # Handler: Assembly::Namespace.Class::Method
  local handler="FaceRecognitionLambda::FaceRecognitionLambda.Function::FunctionHandler"
  local function_arn
  function_arn="$(aws lambda get-function --function-name "${LAMBDA_NAME}" --query Configuration.FunctionArn --output text 2>/dev/null || true)"

  if [[ -z "${function_arn}" || "${function_arn}" == "None" ]]; then
    echo "Erstelle Lambda Funktion: ${LAMBDA_NAME}"
    aws lambda create-function       --function-name "${LAMBDA_NAME}"       --runtime dotnet8       --handler "${handler}"       --role "${role_arn}"       --zip-file "fileb://${zip_path}"       --timeout 30       --memory-size 256       --environment "Variables={OUTPUT_BUCKET=${OUT_BUCKET}}"       --region "${AWS_REGION}" >/dev/null
  else
    echo "OK: Lambda existiert -> Update Code/Config"

    aws lambda update-function-code       --function-name "${LAMBDA_NAME}"       --zip-file "fileb://${zip_path}"       --region "${AWS_REGION}" >/dev/null

    aws lambda update-function-configuration       --function-name "${LAMBDA_NAME}"       --handler "${handler}"       --timeout 30       --memory-size 256       --environment "Variables={OUTPUT_BUCKET=${OUT_BUCKET}}"       --region "${AWS_REGION}" >/dev/null
  fi

  # Warte bis Lambda bereit
  aws lambda wait function-active --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}"

  function_arn="$(aws lambda get-function --function-name "${LAMBDA_NAME}" --query Configuration.FunctionArn --output text --region "${AWS_REGION}")"
  echo "Lambda ARN: ${function_arn}"
}

ensure_s3_invoke_permission() {
  echo "=== Lambda Permission fuer S3 ==="
  local bucket_arn="arn:aws:s3:::${IN_BUCKET}"

  # Prüfen ob Statement existiert
  local exists="0"
  if aws lambda get-policy --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    exists="$(aws lambda get-policy --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}"       --query "Policy" --output text | grep -c ""Sid":"${STATEMENT_ID}"" || true)"
  fi

  if [[ "${exists}" == "0" ]]; then
    echo "Füge add-permission hinzu (Sid=${STATEMENT_ID})"
    aws lambda add-permission       --function-name "${LAMBDA_NAME}"       --statement-id "${STATEMENT_ID}"       --action "lambda:InvokeFunction"       --principal s3.amazonaws.com       --source-arn "${bucket_arn}"       --region "${AWS_REGION}" >/dev/null
  else
    echo "OK: Permission existiert bereits"
  fi
}

ensure_bucket_notification() {
  echo "=== S3 Notification (Trigger) ==="
  local lambda_arn
  lambda_arn="$(aws lambda get-function --function-name "${LAMBDA_NAME}" --query Configuration.FunctionArn --output text --region "${AWS_REGION}")"

  local notif_file="${PROJECT_DIR}/infra/s3-notification.json"
  cat > "${notif_file}" <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${PROJECT_PREFIX}-objectcreated",
      "LambdaFunctionArn": "${lambda_arn}",
      "Events": ["s3:ObjectCreated:*"]
    }
  ]
}
EOF

  aws s3api put-bucket-notification-configuration     --bucket "${IN_BUCKET}"     --notification-configuration "file://${notif_file}"     --region "${AWS_REGION}" >/dev/null

  echo "OK: Trigger gesetzt (S3:ObjectCreated:* -> ${LAMBDA_NAME})"
}

# ----------------------------
# MAIN
# ----------------------------
create_bucket_if_missing "${IN_BUCKET}"
create_bucket_if_missing "${OUT_BUCKET}"

ROLE_ARN="$(ensure_iam_role_and_policy)"
# IAM propagation: kurz warten, damit create-function nicht sporadisch scheitert
sleep 5

ensure_lambda "${ROLE_ARN}"
ensure_s3_invoke_permission
ensure_bucket_notification

echo
echo "FERTIG."
echo "Naechster Schritt (Test):"
echo "  ./Scripts/test.sh ./docs/sample-images/<dein_bild>.jpg"
