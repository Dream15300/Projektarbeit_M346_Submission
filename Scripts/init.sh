#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Konfiguration (Defaults)
# -----------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IN_BUCKET="${IN_BUCKET:-m346-facerec-${ACCOUNT_ID}-in}"
OUT_BUCKET="${OUT_BUCKET:-m346-facerec-${ACCOUNT_ID}-out}"

LAMBDA_NAME="${LAMBDA_NAME:-m346-facerec-lambda}"

# Wunschrollenname (wird im Learner Lab oft NICHT erstellbar sein)
ROLE_NAME="${ROLE_NAME:-m346-facerec-lambda-role}"
POLICY_NAME="${POLICY_NAME:-m346-facerec-lambda-policy}"

# Fallback-Rollen (Learner Lab typisch)
FALLBACK_ROLES=("LabRole" "vocareum" "VoclabsRole" "AWSLabRole" "LearnerLabRole")

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAMBDA_SRC_DIR="${ROOT_DIR}/FaceRecognitionLambda/FaceRecognitionLambda"
PUBLISH_DIR="${LAMBDA_SRC_DIR}/publish"
ZIP_PATH="${PUBLISH_DIR}/lambda.zip"

# -----------------------------
# Helpers
# -----------------------------
log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command fehlt: $1"
}

bucket_exists() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

create_bucket() {
  local b="$1"
  if bucket_exists "$b"; then
    log "OK: Bucket existiert bereits: $b"
    return 0
  fi

  log "Erstelle Bucket: $b"
  # us-east-1: KEIN LocationConstraint
  aws s3api create-bucket --bucket "$b" --region "$AWS_REGION" >/dev/null
  log "OK: Bucket erstellt: $b"
}

get_role_arn_if_exists() {
  local rn="$1"
  aws iam get-role --role-name "$rn" --query Role.Arn --output text 2>/dev/null || true
}

try_create_role_and_policy() {
  # Trust Policy
  local trust_doc="${ROOT_DIR}/infra/iam-trust-policy.json"
  local policy_tpl="${ROOT_DIR}/infra/lambda-policy.template.json"


  [[ -f "$trust_doc" ]] || die "Fehlt: $trust_doc"
  [[ -f "$policy_tpl" ]] || die "Fehlt: $policy_tpl"

  log "=== IAM Rolle/Policy (optional) ==="
  log "Versuche IAM Rolle zu erstellen: $ROLE_NAME"

  # CreateRole kann im Learner Lab verboten sein -> Fehler abfangen
  set +e
  local create_role_out
  create_role_out="$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${trust_doc}" 2>&1)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    if echo "$create_role_out" | grep -qi "AccessDenied"; then
      warn "iam:CreateRole ist im Learner Lab gesperrt. Nutze vorhandene Lab-Rolle (Fallback)."
      return 1
    fi
    warn "CreateRole fehlgeschlagen: $create_role_out"
    return 1
  fi

  local role_arn
  role_arn="$(get_role_arn_if_exists "$ROLE_NAME")"
  [[ -n "$role_arn" ]] || die "Rolle wurde erstellt, aber ARN konnte nicht gelesen werden."

  log "OK: Rolle erstellt: $ROLE_NAME"
  log "Role ARN: $role_arn"

  # Policy erstellen (falls bereits existiert -> weiter)
  # Template mit Bucket-Namen ersetzen
  local policy_doc_tmp
  policy_doc_tmp="$(mktemp)"
  sed \
    -e "s|__IN_BUCKET__|${IN_BUCKET}|g" \
    -e "s|__OUT_BUCKET__|${OUT_BUCKET}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    "$policy_tpl" > "$policy_doc_tmp"

  log "Versuche IAM Policy zu erstellen/zu finden: $POLICY_NAME"
  local policy_arn=""
  set +e
  local create_policy_out
  create_policy_out="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${policy_doc_tmp}" 2>&1)"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    policy_arn="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text)"
  else
    # Wenn Policy schon existiert, ARN auslesen
    policy_arn="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text 2>/dev/null || true)"
    if [[ -z "$policy_arn" || "$policy_arn" == "None" ]]; then
      warn "CreatePolicy fehlgeschlagen: $create_policy_out"
      warn "Weiter mit Rolle ohne eigene Policy (kann zu Rekognition/S3-Fehlern fuehren)."
      rm -f "$policy_doc_tmp"
      echo "$role_arn"
      return 0
    fi
  fi

  log "Policy ARN: $policy_arn"

  # Policy an Rolle anhaengen (kann ebenfalls verboten sein)
  set +e
  local attach_out
  attach_out="$(aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    if echo "$attach_out" | grep -qi "AccessDenied"; then
      warn "attach-role-policy ist im Learner Lab gesperrt. Rolle muss bereits passende Rechte haben."
    else
      warn "attach-role-policy fehlgeschlagen: $attach_out"
    fi
  else
    log "OK: Policy an Rolle angehaengt."
  fi

  rm -f "$policy_doc_tmp"
  echo "$role_arn"
}

resolve_execution_role_arn() {
  # 1) Existierende Wunschrolle?
  local arn
  arn="$(get_role_arn_if_exists "$ROLE_NAME")"
  if [[ -n "$arn" && "$arn" != "None" ]]; then
    echo "$arn"
    return 0
  fi

  # 2) Versuch Rolle/Policy zu erstellen
  if arn="$(try_create_role_and_policy)"; then
    [[ -n "$arn" ]] || die "Interner Fehler: ROLE ARN leer."
    echo "$arn"
    return 0
  fi

  # 3) Fallback: typische LabRole(s)
  for r in "${FALLBACK_ROLES[@]}"; do
    arn="$(get_role_arn_if_exists "$r")"
    if [[ -n "$arn" && "$arn" != "None" ]]; then
      warn "Verwende vorhandene Ausfuehrungsrolle: $r"
      echo "$arn"
      return 0
    fi
  done

  die "Keine verwendbare IAM Rolle gefunden. Im Learner Lab existiert meist 'LabRole'. Bitte in IAM Roles nachsehen und FALLBACK_ROLES in init.sh anpassen."
}

deploy_lambda() {
  local role_arn="$1"

  log "=== Lambda Deploy ==="
  require_cmd dotnet
  require_cmd zip

  log "dotnet publish (net8.0) ..."
  dotnet publish "${LAMBDA_SRC_DIR}/FaceRecognitionLambda.csproj" -c Release -o "$PUBLISH_DIR" >/dev/null

  # ZIP neu erzeugen (idempotent)
  rm -f "$ZIP_PATH"
  (cd "$PUBLISH_DIR" && zip -r "lambda.zip" . >/dev/null)

  # Exists?
  if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "Update Lambda Code: $LAMBDA_NAME"
    aws lambda update-function-code \
      --function-name "$LAMBDA_NAME" \
      --zip-file "fileb://${ZIP_PATH}" \
      --region "$AWS_REGION" >/dev/null

    log "OK: Lambda Code aktualisiert."
  else
    log "Erstelle Lambda Funktion: $LAMBDA_NAME"
    aws lambda create-function \
      --function-name "$LAMBDA_NAME" \
      --runtime dotnet8 \
      --handler "FaceRecognitionLambda::FaceRecognitionLambda.Function::FunctionHandler" \
      --role "$role_arn" \
      --zip-file "fileb://${ZIP_PATH}" \
      --timeout 30 \
      --memory-size 256 \
      --region "$AWS_REGION" >/dev/null

    log "OK: Lambda erstellt."
  fi

  # Warten bis aktiv
  aws lambda wait function-active --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
  log "OK: Lambda aktiv."
}

configure_s3_trigger() {
  log "=== S3 Trigger konfigurieren ==="

  local lambda_arn
  lambda_arn="$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text)"
  [[ -n "$lambda_arn" ]] || die "Lambda ARN konnte nicht gelesen werden."

  # Permission fuer S3 -> Lambda (idempotent per StatementId)
  local statement_id="s3invoke-${IN_BUCKET}"
  set +e
  aws lambda add-permission \
    --function-name "$LAMBDA_NAME" \
    --statement-id "$statement_id" \
    --action "lambda:InvokeFunction" \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::${IN_BUCKET}" \
    --region "$AWS_REGION" >/dev/null 2>&1
  set -e

  # Notification Configuration setzen (ersetzt bestehende)
  local notif_tmp
  notif_tmp="$(mktemp)"
  cat > "$notif_tmp" <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "${lambda_arn}",
      "Events": ["s3:ObjectCreated:*"]
    }
  ]
}
EOF

  aws s3api put-bucket-notification-configuration \
    --bucket "$IN_BUCKET" \
    --notification-configuration "file://${notif_tmp}" \
    --region "$AWS_REGION" >/dev/null

  rm -f "$notif_tmp"
  log "OK: S3 Trigger gesetzt (In-Bucket -> Lambda)."
}

# -----------------------------
# Main
# -----------------------------
log "=== Konfiguration ==="
log "Region:        ${AWS_REGION}"
log "Account ID:    ${ACCOUNT_ID}"
log "In-Bucket:     ${IN_BUCKET}"
log "Out-Bucket:    ${OUT_BUCKET}"
log "Lambda Name:   ${LAMBDA_NAME}"
log "Role Name:     ${ROLE_NAME}"
log "Policy Name:   ${POLICY_NAME}"
log "====================="

create_bucket "$IN_BUCKET"
create_bucket "$OUT_BUCKET"

ROLE_ARN="$(resolve_execution_role_arn)"
log "Execution Role ARN: ${ROLE_ARN}"

deploy_lambda "$ROLE_ARN"
configure_s3_trigger

log ""
log "=== Fertig ==="
log "Upload ins In-Bucket:  s3://${IN_BUCKET}"
log "Ergebnisse im Out-Bucket: s3://${OUT_BUCKET}"
