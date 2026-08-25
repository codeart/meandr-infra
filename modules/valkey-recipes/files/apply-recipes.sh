#!/usr/bin/env bash
# Applies the recipe set to every node, once each.
#
# Runs on the OPERATOR's machine (Terraform local-exec), not on a node.
# Delivery is SSM, so nothing here touches user-data and adding a recipe
# can never plan an instance replacement.
#
# Idempotency lives on the node: a ledger of applied recipe names, checked
# before each one runs. That makes the fan-out safe to repeat, which
# matters because ANY new instance re-triggers it for the whole fleet.
set -euo pipefail

: "${RECIPES_DIR:?}" "${AWS_PROFILE:?}" "${AWS_REGION:?}"
RECIPE_FILES="${RECIPE_FILES:-}"
INSTANCE_IDS="${INSTANCE_IDS:-}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
LEDGER=/var/lib/meandr/recipes-applied

if [ -z "${RECIPE_FILES// /}" ]; then
  echo "recipes: none defined, nothing to do"
  exit 0
fi
if [ -z "${INSTANCE_IDS// /}" ]; then
  echo "recipes: no instances, nothing to do"
  exit 0
fi

# The node-side program. Each recipe arrives base64'd so no quoting of
# recipe content can break the payload.
payload() {
  cat <<'PROLOGUE'
set -uo pipefail
LEDGER=/var/lib/meandr/recipes-applied
mkdir -p "$(dirname "$LEDGER")"
touch "$LEDGER"
failed=0

# The ledger key is name:sha256, not name — so CORRECTING a recipe
# re-applies it everywhere instead of being skipped forever.
#
# That costs nothing, because recipes must already be idempotent: a
# replaced node arrives with an empty ledger and replays the whole
# backlog from 001. Anything unsafe to run twice was already unsafe.
run_recipe() {
  name="$1"; body="$2"
  sha="$(printf '%s' "$body" | base64 -d | sha256sum | cut -d' ' -f1)"
  key="$name:$sha"

  if grep -qxF "$key" "$LEDGER" 2>/dev/null; then
    echo "skip  $name"
    return 0
  fi
  echo "apply $name"
  # Recorded only on success, so a failure retries on the next run
  # instead of being silently marked done.
  if printf '%s' "$body" | base64 -d | bash; then
    # Drop any previous entry for this name: the ledger is current state,
    # one line per recipe, not an edit history. Matches a bare name too,
    # which is what the ledger held before keys carried a hash.
    { grep -vE "^$name(:|$)" "$LEDGER" 2>/dev/null || true; } >"$LEDGER.tmp"
    mv "$LEDGER.tmp" "$LEDGER"
    echo "$key" >>"$LEDGER"
    echo "ok    $name"
  else
    echo "FAIL  $name"
    failed=1
  fi
}
PROLOGUE

  for f in $RECIPE_FILES; do
    printf 'run_recipe %s %s\n' "$f" "$(base64 <"$RECIPES_DIR/$f" | tr -d '\n')"
  done

  echo 'exit $failed'
}

# One line, base64 only — no quotes, spaces or commas to survive the trip
# through SSM's parameter encoding.
B64="$(payload | base64 | tr -d '\n')"
PARAMS="$(mktemp)"
OUTFILE="$(mktemp)"
trap 'rm -f "$PARAMS" "$OUTFILE"' EXIT
printf '{"commands":["echo %s | base64 -d | bash"]}\n' "$B64" >"$PARAMS"

echo "recipes: $(echo "$RECIPE_FILES" | wc -w | tr -d ' ') defined, $(echo "$INSTANCE_IDS" | wc -w | tr -d ' ') nodes"

CID="$(aws ssm send-command \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --document-name AWS-RunShellScript \
  --comment "meandr valkey recipes" \
  --timeout-seconds "$WAIT_SECONDS" \
  --instance-ids $INSTANCE_IDS \
  --parameters "file://$PARAMS" \
  --query Command.CommandId --output text)"

echo "recipes: command $CID"

rc=0
for id in $INSTANCE_IDS; do
  # Returns non-zero when the invocation failed, which is a result we
  # want to report rather than an error that should abort the loop.
  aws ssm wait command-executed \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$CID" --instance-id "$id" >/dev/null 2>&1 || true

  # Queried on its own. Asking for Status alongside the output fields
  # returns them TAB-separated on one line, so any attempt to read the
  # status off the first line matches the output too — and every node
  # reads as failed.
  status="$(aws ssm get-command-invocation \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$CID" --instance-id "$id" \
    --query Status --output text 2>/dev/null || echo Unreachable)"

  aws ssm get-command-invocation \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$CID" --instance-id "$id" \
    --query StandardOutputContent --output text >"$OUTFILE" 2>/dev/null || : >"$OUTFILE"

  printf '\n--- %s: %s\n' "$id" "$status"
  sed 's/^/    /' "$OUTFILE"

  if [ "$status" != "Success" ]; then
    rc=1
    # stderr only when it failed — on success it is noise, and a chatty
    # recipe would otherwise bury the nine lines that matter.
    aws ssm get-command-invocation \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --command-id "$CID" --instance-id "$id" \
      --query StandardErrorContent --output text 2>/dev/null \
      | sed 's/^/    stderr: /' || true
  fi
done

if [ "$rc" -ne 0 ]; then
  echo ""
  echo "recipes: at least one node did not converge — this resource stays"
  echo "tainted, so the next apply retries. Nodes that succeeded have it"
  echo "recorded in $LEDGER and will skip on the retry."
fi
exit "$rc"
