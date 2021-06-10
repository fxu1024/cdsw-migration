#!/usr/bin/env bash
# © Copyright 2020 Cloudera, Inc.

# To run interactively, replace the contents of exit_fn and set CDSW_BACKUP manually

function usage() {
  cat <<EOF

Usage:

    ${0} [ARCHIVE]

ARCHIVE should be generated according to export.sh
EOF
}

# Exit statuses
SUCCESS=0
REQUIRED_BINARY_NOT_FOUND=1
KUBECTL_FAILED=2
CDSW_BACKUP_NOT_PROVIDED=3
UNEXPECTED_ARCHIVE_LAYOUT=4
TIMED_OUT_WAITING_FOR_POD=5
UNABLE_TO_IDENTIFY_SINGLE_ADMIN=5
EXISTING_PROJECT_FILES=6
UNEXPECTED_ERR=255

NAMESPACE=mlx

function log_err {
  echo "[ERROR] ${1}"
}

function log_info {
  echo "[INFO] ${1}"
}

function exit_fn() {
  # Separate function to easily stop the script from closing terminals when running this code interactively
  exit ${1}
}

function err_trap() {
  log_err "Unexpected error on line $1!"
  exit_fn ${UNEXPECTED_ERR}
}
trap 'err_trap $LINENO' ERR

for required_binary in awk cat date head grep kubectl rm sed sleep sort tail tar wc; do
  if ! which ${required_binary} > /dev/null; then
    log_err "${required_binary} must be on ${PATH}!"
    exit_fn ${REQUIRED_BINARY_NOT_FOUND}
  fi
done

if ! kubectl api-versions > /dev/null; then
  log_err "Unable to connect to Kubernetes cluster: check Kubeconfig!"
  exit_fn ${KUBECTL_FAILED}
fi

if [ "${#}" -ne 1 ]; then
  log_err "${#} arguments received, 1 expected."
  usage
  exit_fn ${CDSW_BACKUP_NOT_PROVIDED}
fi
CDSW_BACKUP=${1}
if [ ! -f "${CDSW_BACKUP}" ]; then
  exit_fn ${CDSW_BACKUP_NOT_PROVIDED}
fi
ACTUAL_ARCHIVE_DIRS=$(tar tf ${CDSW_BACKUP} --exclude="*/*" | sort)
EXPECTED_ARCHIVE_DIRS="db.sql projects/"
if [ "$(echo ${ACTUAL_ARCHIVE_DIRS})" != "$(echo ${EXPECTED_ARCHIVE_DIRS})" ]; then
  log_err "archive contents (${ACTUAL_ARCHIVE_DIRS}), is not what is expected (${EXPECTED_ARCHIVE_DIRS})"
  usage
  exit_fn ${UNEXPECTED_ARCHIVE_LAYOUT}
fi

function get_pod_status {
  POD_PREFIX=${1}
  kubectl get pods -n ${NAMESPACE} | grep ^${POD_PREFIX} | awk '{ print $3 }'
}

function wait_for_pod {
  POD_PREFIX=${1}
  DESIRED_STATUS=${2} # can be empty to wait for termination

  current_status=$(get_pod_status ${POD_PREFIX})
  i=0
  max=60
  while [ ${i} -lt ${max} -a "${current_status}" != "${DESIRED_STATUS}" ]; do
    sleep 10
    i=$((i + 1))
    current_status=$(get_pod_status ${POD_PREFIX})
  done
  if [ ${i} -eq ${max} ]; then
    log_info "Timed out waiting for ${POD_PREFIX} pod to reach status ${DESIRED_STATUS}!"
    exit_fn ${TIMED_OUT_WAITING_FOR_POD}
  fi
}

TEMP_DIR=$(mktemp -d)
CML_MIGRATION_POD_YAML=${TEMP_DIR}/cml-migration-pod.yaml
DB_MIGRATION_JOB_YAML=${TEMP_DIR}/db-migration.yaml
log_info "Temporary files in: ${TEMP_DIR}"
function cleanup {
  if kubectl describe pod cml-migration-pod -n ${NAMESPACE}; then
    kubectl delete pod cml-migration-pod -n ${NAMESPACE}
  fi
  read -p "Delete temporary files (some DB table exports and auxiliary Kubernetes files) in ${TEMP_DIR} (y/n)? " choice
  case "$choice" in
    y|Y )
      log_info "Deleting temporary files"
      rm -r ${TEMP_DIR}
      log_info "Temporary files deleted!"
    ;;
    n|N )
      log_info "Leaving files in place"
    ;;
    * )
      log_err "Invalid input: leaving files in place"
    ;;
  esac
}

# Note: we do this early so it's still easy to fix
# We check again later when all the DB clients are shut down
log_info "Checking for admin user"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM users WHERE admin=TRUE) TO '/tmp/users.csv' DELIMITER ',' CSV HEADER"
kubectl cp ${NAMESPACE}/db-0:/tmp/users.csv ${TEMP_DIR}/users1.csv
NUM_USERS=$(tail -n+2 ${TEMP_DIR}/users1.csv | wc -l)
if [ "${NUM_USERS}" -lt "1" ]; then
  log_err "No admins in workspace: please log in first"
  exit_fn ${UNABLE_TO_IDENTIFY_SINGLE_ADMIN}
fi

log_info "Scaling down all database clients"
for d in web feature-flags usage-reporter model-proxy cron metering; do
  log_info "Scaling down deployment ${d}"
  kubectl scale deployment -n ${NAMESPACE} $d --replicas=0
  wait_for_pod ${d} ''
done

TABLES_TO_COPY="site_config"
if [ -n "${TABLES_TO_COPY}" ]; then
  for table in ${TABLES_TO_COPY}; do
    # A proper DB back up should be made, and we shouldn't entirely decommission CDSW until the migration is known to be good
    log_info "Copying DB table ${table}"
    kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM ${table}) TO '/tmp/${table}.csv' DELIMITER ',' CSV HEADER"
    kubectl cp ${NAMESPACE}/db-0:/tmp/${table}.csv ${TEMP_DIR}/${table}.csv
  done
fi

log_info "Saving default CML image from database"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM engine_images WHERE id=(SELECT MAX(id) FROM engine_images)) TO '/tmp/engine_images.csv' DELIMITER ',' CSV HEADER"
kubectl cp ${NAMESPACE}/db-0:/tmp/engine_images.csv ${TEMP_DIR}/engine_images1.csv
cat ${TEMP_DIR}/engine_images1.csv | head -1 | sed -e 's/^id,//' > ${TEMP_DIR}/engine_images2.csv
cat ${TEMP_DIR}/engine_images1.csv | tail -n +2 | sed 's/^[[:digit:]]\+,Default engine image/Default engine image/g' >> ${TEMP_DIR}/engine_images2.csv

# Special handling for the users table because we import a single administrator and assign everything to them
log_info "Copying users table to identify administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM users WHERE admin=TRUE) TO '/tmp/users.csv' DELIMITER ',' CSV HEADER"
kubectl cp ${NAMESPACE}/db-0:/tmp/users.csv ${TEMP_DIR}/users1.csv
NUM_USERS=$(tail -n+2 ${TEMP_DIR}/users1.csv | wc -l)
USERNAMES=$(tail -n+2 ${TEMP_DIR}/users1.csv | sed -e 's/,/\t/g' | awk '{ print $2 }')
if [ "${NUM_USERS}" -lt "1" ]; then
  log_err "No admins in workspace: please log in first"
  exit_fn ${UNABLE_TO_IDENTIFY_SINGLE_ADMIN}
fi
if [ "${NUM_USERS}" -gt "1" ]; then
  echo "Please select the admin that will own the migrated data:"
  select user in ${USERNAMES}; do
    #export user=${user}
    break
  done
else
  user=${USERNAMES}
fi
cat ${TEMP_DIR}/users1.csv | head -1 | sed -e 's/^id,//' > ${TEMP_DIR}/users2.csv
cat ${TEMP_DIR}/users1.csv | grep "^[[:digit:]]\+,${user}," | sed 's/^[[:digit:]]\+,//g' >> ${TEMP_DIR}/users2.csv

log_info "Shutting down database pod"
kubectl scale statefulset -n ${NAMESPACE} db --replicas=0
wait_for_pod db-0 ''

log_info "Launching migration helper pod"
cat > ${CML_MIGRATION_POD_YAML} <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cml-migration-pod
  namespace: ${NAMESPACE}
spec:
  containers:
  - image: busybox
    volumeMounts:
    - mountPath: /migration/projects
      name: cml-migration-projects
    - mountPath: /migration/db-versioned
      name: cml-migration-db-versioned
    command: ["tail", "-f", "/dev/null"]
    imagePullPolicy: IfNotPresent
    name: busybox
  volumes:
    - name: cml-migration-projects
      persistentVolumeClaim:
        claimName: projects-pvc
    - name: cml-migration-db-versioned
      persistentVolumeClaim:
        claimName: postgres-data-versioned-db-0
  tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/infra
    operator: Equal
    value: "true"
  # TODO force to infra node?
EOF
kubectl apply -f ${CML_MIGRATION_POD_YAML}
wait_for_pod cml-migration-pod 'Running'

log_info "Checking for existing projects"
existing_projects=$(kubectl exec cml-migration-pod -n ${NAMESPACE} -- find /migration/projects/projects -type f | wc -l)
if [ "${existing_projects}" != "0" ]; then
  log_err "Existing project files detected in NFS volume!"
  exit_fn ${EXISTING_PROJECT_FILES}
fi

# NOTE: if this step exceeds memory capacity, we can try breaking it up and copying direct to the volumes
log_info "Copying export archive into migration pod"
kubectl cp ${CDSW_BACKUP} ${NAMESPACE}/cml-migration-pod:/migration/backup.tar.gz

log_info "Extracting export archive"
kubectl exec cml-migration-pod -n ${NAMESPACE} -- mkdir -p /migration/backup
kubectl exec cml-migration-pod -n ${NAMESPACE} -- tar xzf /migration/backup.tar.gz -C /migration/backup

log_info "Copying project files"
kubectl exec cml-migration-pod -n ${NAMESPACE} -- cp -rf /migration/backup/projects /migration/
if ! kubectl exec cml-migration-pod -n ${NAMESPACE} -- chown -R 8536:8536 /migration/projects; then
  # Some complaints about .snapshot may be common
  log_err "Review any errors above to see if NFS chown was successful"
fi

# Back up for dev - to easily reset state
#kubectl exec cml-migration-pod -n ${NAMESPACE} -- cp -r /migration/db-versioned/11 /migration/db-versioned/11.cml-migrate.$(date -Iseconds)

log_info "Copying database files"
kubectl exec cml-migration-pod -n ${NAMESPACE} -- cp -r /migration/backup/db.sql /migration/db-versioned/db.sql

log_info "Shutting down migration helper pod"
kubectl delete pod cml-migration-pod -n ${NAMESPACE}
wait_for_pod cml-migration-pod ''

log_info "Restarting database pod"
kubectl scale statefulset -n ${NAMESPACE} db --replicas=1
wait_for_pod db-0 'Running'

kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'DROP SCHEMA public CASCADE;'
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'DROP SCHEMA feature_flags CASCADE;'
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'CREATE SCHEMA public;'
kubectl exec db-0 -n ${NAMESPACE} -- bash -c 'psql -U sense < /data-versioned/db.sql'

kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'TRUNCATE custom_quota'
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'TRUNCATE default_quota'

log_info "Reapplying database migrations"
MIGRATION_JOB=$(kubectl get jobs -n ${NAMESPACE} | grep ^db-migrate | awk '{ print $1 }')
kubectl get job -n ${NAMESPACE} ${MIGRATION_JOB} -o yaml \
  | grep -v controller-uid \
  > ${DB_MIGRATION_JOB_YAML}
kubectl delete job ${MIGRATION_JOB} -n ${NAMESPACE}
kubectl apply -f ${DB_MIGRATION_JOB_YAML} -n ${NAMESPACE}
wait_for_pod ${MIGRATION_JOB} 'Completed'

log_info "Importing administrator user"
kubectl cp ${TEMP_DIR}/users2.csv ${NAMESPACE}/db-0:/tmp/users.csv
CSV_COLUMNS=$(cat ${TEMP_DIR}/users2.csv | head -n1)
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY users(${CSV_COLUMNS}) FROM '/tmp/users.csv' DELIMITER ',' CSV HEADER"
kubectl exec db-0 -n ${NAMESPACE} -- rm /tmp/users.csv

log_info "Importing engine images table"
kubectl cp ${TEMP_DIR}/engine_images2.csv ${NAMESPACE}/db-0:/tmp/engine_images.csv
CSV_COLUMNS=$(cat ${TEMP_DIR}/engine_images2.csv | head -n1)
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY engine_images(${CSV_COLUMNS}) FROM '/tmp/engine_images.csv' DELIMITER ',' CSV HEADER"
kubectl exec db-0 -n ${NAMESPACE} -- rm /tmp/engine_images.csv

log_info "Importing site config"
kubectl cp ${TEMP_DIR}/site_config.csv ${NAMESPACE}/db-0:/tmp/site_config.csv
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "TRUNCATE site_config"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY site_config FROM '/tmp/site_config.csv' DELIMITER ',' CSV HEADER"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE site_config SET default_engine_image_id=(SELECT MAX(id) FROM engine_images)"
kubectl exec db-0 -n ${NAMESPACE} -- rm /tmp/site_config.csv

log_info "Pausing all jobs"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE jobs SET paused=true"
log_info "Marking all applications as stopped"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE applications SET status='stopped'"

# If we're cleaning up the user's table, we first have to find every row that references users and either update it to point at the new admin or delete it:
# SELECT conname, pg_catalog.pg_get_constraintdef(r.oid, true) as condef FROM pg_catalog.pg_constraint r WHERE r.confrelid = 'users'::regclass;

log_info "Giving duplicate projects unique slugs"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE projects SET slug = slug || '-cdsw-user-' || user_id WHERE slug IN (SELECT slug FROM projects GROUP BY slug HAVING COUNT(*) > 1)"
log_info "Transferring all projects to administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE projects SET user_id=(SELECT MAX(id) FROM users), creator_id=(SELECT MAX(id) FROM users)"
log_info "Transferring all jobs to administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE jobs SET creator_id=(SELECT MAX(id) FROM users)"
log_info "Transferring all experiments to administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE batch_runs SET user_id=(SELECT MAX(id) FROM users)"
log_info "Transferring all models to administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE models SET creator_id=(SELECT MAX(id) FROM users)"
log_info "Transferring all applications to administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE applications SET creator_id=(SELECT MAX(id) FROM users)"
log_info "Transferring all image builds to administrator"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE build_details SET user_id=(SELECT MAX(id) FROM users)"
log_info "Changing project engine images to latest CML image"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE projects_engine_images SET engine_image_id=(SELECT MAX(id) FROM engine_images);"
# TODO can we point everything in batch_runs at a single "old image" place holder, and truncate build_details?
# TODO Same with the clusters referenced by dashboards

log_info "Truncating tables that no longer apply to new context"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "DELETE FROM invitations"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "TRUNCATE \
access_keys,
authorized_keys,
followers,
job_notifications,
kerberos,
licenses,
model_builds,
model_deployments,
password_resets,
projects_users,
project_invitations,
organization_members,
organization_invitations,
shared_job_run_acl,
shared_session_acl,
ssh_keys,
stars,
user_billing,
user_events,
waiting,
watchers"

# If we end up keeping users, organization_members & job_notifications don't need go

log_info "Deleting previous users"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "DELETE FROM users WHERE id != (SELECT MAX(id) FROM users)"

log_info "Restoring database password"
kubectl exec db-0 -n ${NAMESPACE} -- bash -c "psql -U sense -c \"ALTER USER sense WITH PASSWORD '\$(echo \${POSTGRES_PASSWORD})'\""
kubectl delete pod db-0 -n ${NAMESPACE} # TODO is this necessary?
wait_for_pod db-0 'Running'

for d in feature-flags usage-reporter model-proxy cron metering; do
  log_info "Scaling up deployment ${d}"
  kubectl scale deployment -n ${NAMESPACE} $d --replicas=1
done
for d in web; do
  log_info "Scaling up deployment ${d}"
  kubectl scale deployment -n ${NAMESPACE} $d --replicas=3
done

cleanup
exit_fn ${SUCCESS}
