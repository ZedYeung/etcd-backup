#!/bin/bash
# openssl encrypt large file
# https://gist.github.com/crazybyte/4142975
RESTORE_HOST0=10.103.1.13
RESTORE_HOST1=10.103.1.14
RESTORE_HOST2=10.103.1.15
HOST0=10.103.1.16
HOST1=10.103.1.17
HOST2=10.103.1.18
PORT=2379

export SLACK_APP="https://hooks.slack.com/services/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"
export RESTORE_ENDPOINTS="http://${RESTORE_HOST0}:${PORT},http://${RESTORE_HOST1}:${PORT},http://${RESTORE_HOST2}:${PORT}"
export ENDPOINTS="http://${HOST0}:${PORT},http://${HOST1}:${PORT},http://${HOST2}:${PORT}"
export GENERATE_INTERVAL=10

TEST_FULL_NUM=2
TEST_DIFF_NUM=2
FULL_INTERVAL=180
DIFF_INTERVAL=60

FULL_BACKUP_OBJECT_STORAGE_BUCKET=s3://full-backup
DIFF_BACKUP_OBJECT_STORAGE_BUCKET=s3://diff-backup
BACKUP_ENDPOINT=/
PRIVATE_KEY_PEM=private_key.pem
PUBLIC_KEY_PEM=public_key.pem
SLEEP_TIME=$[${TEST_FULL_NUM} * ${FULL_INTERVAL} + ${TEST_DIFF_NUM} * ${DIFF_INTERVAL}]

echo "Generate ssl file..."
openssl req -x509 -days 100000 -newkey rsa:4096 -keyout ${PRIVATE_KEY_PEM} -out ${PUBLIC_KEY_PEM}

echo "Generate data..."
./generate_random_data.sh &

echo "First backup"
./etcd-backup-full.sh
./etcd-backup-diff.sh

# CRON JOB TO BACKUP
# https://stackoverflow.com/questions/878600/how-to-create-a-cron-job-using-bash-automatically-without-the-interactive-editor
echo "Create cronjob..."
crontab -l > backup_cronjob
echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> backup_cronjob
echo "*/3 * * * * ~/cd-etcd-backup/etcd-backup-full.sh" >> backup_cronjob
echo "* * * * * ~/cd-etcd-backup/etcd-backup-diff.sh" >> backup_cronjob
echo "* * * * * ~/cd-etcd-backup/etcd_unhealth_alert.sh" >> backup_cronjob
# echo "* * * * * ./generate_random_data.sh" >> backup_cronjob
crontab backup_cronjob
# rm backup_cronjob

echo "Backup..."
sleep ${SLEEP_TIME}

# simulate clash
# etcdctl rm ${BACKUP_ENDPOINT} --recursive
# TODO VPN CONNECT
echo "Restore..."
# s3cmd output sample
# 2018-06-28 22:47      3576   s3://full-backup/test.sh
LATEST_FULL_ENC_BACKUP=$(basename $(s3cmd ls ${FULL_BACKUP_OBJECT_STORAGE_BUCKET} | tail -n 1 | awk {'print $4'}))
LATEST_DIFF_ENC_BACKUP=$(basename $(s3cmd ls ${DIFF_BACKUP_OBJECT_STORAGE_BUCKET} | tail -n 1 | awk {'print $4'}))
# LATEST_FULL_BACKUP=$(${LATEST_FULL_ENC_BACKUP} | rev | cut -f 2- -d '.' | rev)
LATEST_FULL_BACKUP=$(basename ${LATEST_FULL_ENC_BACKUP} .enc)
echo ${LATEST_FULL_BACKUP}
# LATEST_DIFF_BACKUP=$(${LATEST_DIFF_ENC_BACKUP} | rev | cut -f 2- -d '.' | rev)
LATEST_DIFF_BACKUP=$(basename ${LATEST_DIFF_BACKUP} .enc)
echo ${LATEST_DIFF_BACKUP}

echo "Pulling ${LATEST_FULL_ENC_BACKUP}"
s3cmd get ${FULL_BACKUP_OBJECT_STORAGE_BUCKET}/${LATEST_FULL_ENC_BACKUP} ${LATEST_FULL_ENC_BACKUP}
echo "Pulling ${LATEST_DIFF_ENC_BACKUP}"
s3cmd get ${DIFF_BACKUP_OBJECT_STORAGE_BUCKET}/${LATEST_DIFF_ENC_BACKUP} ${LATEST_DIFF_ENC_BACKUP}

echo "Descrypting..."
openssl smime -decrypt -binary -in ${LATEST_FULL_ENC_BACKUP} -inform DER -out ${LATEST_FULL_BACKUP} -inkey ${PRIVATE_KEY_PEM}
openssl smime -decrypt -binary -in ${LATEST_DIFF_ENC_BACKUP} -inform DER -out ${LATEST_DIFF_BACKUP} -inkey ${PRIVATE_KEY_PEM}

# TEST FULL BACKUP
# TODO: CA
echo "Recovering..."
etcdtool --peers ${RESTORE_ENDPOINTS} import -y ${BACKUP_ENDPOINT} ${LATEST_FULL_BACKUP}

FULL_BACKUP_TEST_CASE_NUM=$[${TEST_FULL_NUM} * ${FULL_INTERVAL} / ${GENERATE_INTERVAL}]
RESTORE_FULL_BACKUP_NUM=$(etcdctl --endpoints ${RESTORE_ENDPOINTS} ls /test | wc -l)
if  [ ${RESTORE_FULL_BACKUP_NUM} -ne ${FULL_BACKUP_TEST_CASE_NUM} ]; then
  echo "Full backup test case number: ${FULL_BACKUP_TEST_CASE_NUM}"
  echo "Restore full backup number: ${RESTORE_FULL_BACKUP_NUM}"
fi

for i in $(seq 1 ${FULL_BACKUP_TEST_CASE_NUM});
do
  # deployment=nginx${i}
  # assert $(etcdctl get /registry/deployments/${deployment})
  if [ $(etcdctl --endpoints ${RESTORE_ENDPOINTS} get /test/case${i}) -ne $[${i} * 2 - 1] ]; then
    echo "mismatch"
  fi
done


# TEST DIFF BACKUP
UPDATED_FULL_BACKUP=updated_full_backup.json
patch ${LATEST_FULL_BACKUP} -i ${LATEST_DIFF_BACKUP} -o ${UPDATED_FULL_BACKUP}

etcdtool --peers ${RESTORE_ENDPOINTS} import -y ${BACKUP_ENDPOINT} ${UPDATED_FULL_BACKUP}

DIFF_BACKUP_TEST_CASE_NUM=$[${SLEEP_TIME} / ${GENERATE_INTERVAL}]
RESTORE_DIFF_BACKUP_NUM=$(etcdctl --endpoints ${RESTORE_ENDPOINTS} ls /test | wc -l)
if  [ ${RESTORE_DIFF_BACKUP_NUM} -ne ${DIFF_BACKUP_TEST_CASE_NUM} ]; then
  echo "Diff backup test case number: ${DIFF_BACKUP_TEST_CASE_NUM}"
  echo "Restore diff backup number: ${RESTORE_DIFF_BACKUP_NUM}"
fi

for i in $(seq 1 ${DIFF_BACKUP_TEST_CASE_NUM});
do
  if [ $(etcdctl --endpoints ${RESTORE_ENDPOINTS} get /test/case${i}) -ne $[${i} * 2 - 1] ]; then
    echo "mismatch"
  fi
done
