#!/bin/bash
SLACK_APP="https://hooks.slack.com/services/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"
RESTORE_HOST0=10.103.1.13
RESTORE_HOST1=10.103.1.14
RESTORE_HOST2=10.103.1.15
HOST0=10.103.1.16
HOST1=10.103.1.17
HOST2=10.103.1.18
PORT=2379

RESTORE_ENDPOINTS="http://${RESTORE_HOST0}:${PORT},http://${RESTORE_HOST1}:${PORT},http://${RESTORE_HOST2}:${PORT}"
ENDPOINTS="http://${HOST0}:${PORT},http://${HOST1}:${PORT},http://${HOST2}:${PORT}"

FULL_BACKUP_OBJECT_STORAGE_BUCKET=s3://full-backup
DIFF_BACKUP_OBJECT_STORAGE_BUCKET=s3://diff-backup

FULL_BACKUP_DIR=/etcd_backup/full/
DIFF_BACKUP_DIR=/etcd_backup/diff/
mkdir -p ${FULL_BACKUP_DIR}
mkdir -p ${DIFF_BACKUP_DIR}

cp ./.s3cfg ~/.s3cfg

# http:// is mandatory
echo "Check etcd cluster health"
etcdctl --endpoints ${ENDPOINTS} cluster-health
etcdctl --endpoints ${RESTORE_ENDPOINTS} cluster-health

echo "Check etcdtool"
etcdtool --peers ${ENDPOINTS} tree /
etcdtool --peers ${RESTORE_ENDPOINTS} tree /

echo "Check s3cmd"
s3cmd put test.sh ${FULL_BACKUP_OBJECT_STORAGE_BUCKET}/test.sh
s3cmd put test.sh ${DIFF_BACKUP_OBJECT_STORAGE_BUCKET}/test.sh
s3cmd ls ${FULL_BACKUP_OBJECT_STORAGE_BUCKET}
s3cmd ls ${DIFF_BACKUP_OBJECT_STORAGE_BUCKET}
s3cmd rm ${FULL_BACKUP_OBJECT_STORAGE_BUCKET}/*
s3cmd rm ${DIFF_BACKUP_OBJECT_STORAGE_BUCKET}/*

IFS=","

echo "Check Slack webhook"
for ENDPOINT in $ENDPOINTS;
do
  HEALTH=$(curl -L ${ENDPOINT}/health | jq -r '.health')
  if [ "$HEALTH" = false ]; then
    curl -X POST -H 'Content-type: application/json' --data '{"text": "'"${ENDPOINT}"' unhealthy"}' ${SLACK_APP}
  elif [ "$HEALTH" = true ]; then
    curl -X POST -H 'Content-type: application/json' --data '{"text": "'"${ENDPOINT}"' healthy"}' ${SLACK_APP}
  else
    curl -X POST -H 'Content-type: application/json' --data '{"text": "Could not detect"}' ${SLACK_APP}
  fi
done
