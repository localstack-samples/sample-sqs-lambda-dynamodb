#!/bin/bash
# Upload the sample CSV and check that every row ends up in DynamoDB
# (S3 -> CSV processing Lambda -> SQS -> DynamoDB writer Lambda).
set -euo pipefail

CSV=sqs_blog/sample_file.csv
MAX_ATTEMPTS=${MAX_ATTEMPTS:-30}

BUCKET_NAME=$(lstk aws s3api list-buckets --query "Buckets[?contains(Name, 'inventoryupdatesbucket')].Name | [0]" --output text)
TABLE_NAME=$(lstk aws dynamodb list-tables --query "TableNames[?contains(@, 'InventoryUpdates')] | [0]" --output text)
echo "Bucket: $BUCKET_NAME"
echo "Table: $TABLE_NAME"

count_items() {
  lstk aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT --query Count --output text
}

expected=$(tail -n +2 "$CSV" | grep -c .)
before=$(count_items)

lstk aws s3 cp "$CSV" "s3://$BUCKET_NAME/" > /dev/null
echo "Uploaded $CSV ($expected rows)"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  added=$(( $(count_items) - before ))
  if [ "$added" -ge "$expected" ]; then
    break
  fi
  echo "Attempt $attempt/$MAX_ATTEMPTS: $added/$expected items in DynamoDB"
  sleep 2
done

if [ "$added" -lt "$expected" ]; then
  echo "Test failed: expected $expected new items, found $added"
  exit 1
fi

item=$(lstk aws dynamodb scan --table-name "$TABLE_NAME" \
  --filter-expression "product_id = :p" \
  --expression-attribute-values '{":p": {"S": "P002"}}' \
  --query "Items[0]")
echo "Sample item: $item"
if ! echo "$item" | jq -e '.location.S == "Warehouse B" and .quantity.N == "25"' > /dev/null; then
  echo "Test failed: item for P002 does not match the CSV row"
  exit 1
fi

echo "Test passed: all $expected rows were written to DynamoDB"
