# Cloudera Machine Learning Migration

This is a guide to interactively performing a migration from a CDSW cluster to a CML workspace. `./migrate.sh` is an automated version of this same process used for testing the procedure. As this is an immature process, it should probably be performed manually to check for problems at each step. Please ensure this README and migrate.sh are kept in sync with each other. Fixes, improvements and other feedback are welcome.

## Requirements

This requires a new CML workspace to already be provisioned. It must not have any existing projects. At least 1 admin user must have already logged in to the workspace (the migration will be easier if no one else has logged in).

The migration can be driven from any machine that has a copy of the data exported from the CDSW cluster and Kubernetes connectivity to the new workspace. The code snippets below have been tested on Ubuntu 18.04, but they are expected to work on Mac OS X too. The following tools are required:

* `awk`
* `cat`
* `date`
* `head`
* `grep`
* `kubectl`
* `rm`
* `sed`
* `sleep`
* `sort`
* `tail`
* `tar`
* `wc`

You also need the `kubeconfig` from the workspace. Ensure that `kubectl api-versions` works in your terminal.

## Limitations

Data that is *not* migrated in this process includes:
* Logs from previous sessions, jobs, etc.
* Docker images, including those from previous model builds, experiment builds, etc.

Users are also not migrated. All resources will be owned by an administrator in the new workspace, to be reassigned on a case-by-case basis.

## Exporting data from CDSW

1. A full back-up of the CDSW cluster before attempting the migration. A partial backup will be done using a different process below to prevent the need to share sensitive database tables during the migration.

2. The CDSW service must be running because the database must be up. But it would be safe to spin down all database clients to ensure the database dump is consistent:

```bash
for d in web feature-flags usage-reporter model-proxy cron; do
  kubectl scale deployment $d --replicas=0
done
```

3. Export the contents of the database. The contents of sensitive tables are excluded from this dump:

```bash
DB_POD=$(kubectl get pod | grep ^db | grep -v ^db-migrate | awk '{ print $1 }')
kubectl exec ${DB_POD} -- pg_dump -U sense \
  --exclude-table-data=kerberos --exclude-table-data=kerberos_seq \
  --exclude-table-data=ssh_keys --exclude-table-data=ssh_keys_seq \
  --exclude-table-data=access_keys --exclude-table-data=access_keys_seq \
> /var/lib/cdsw/current/db.sql
```

4. At this point, the database clients can be spun back up:

```bash
for d in feature-flags usage-reporter model-proxy cron; do
  kubectl scale deployment $d --replicas=1
done

for d in web; do
  kubectl scale deployment $d --replicas=3
done
```

5. Archive this dump along with the contents of the NFS directory (scratch can be excluded because it is intended as temporary data):

```bash
tar --exclude='projects/scratch/*' -czf cml-migration.tar.gz -C `pwd` db.sql projects
```

6. You can then dispense with the database dump:

```bash
rm /var/lib/cdsw/current/db.sql
```

## Importing Data into CML

### Shell Variables

You'll need a directory for a few temporary files, like some original database state and helper files for Kubernetes. You can use a temporary directory, but you may wish to use a subdirectory of ${HOME} in case the migration context needs to persist across a restart.

```bash
TEMP_DIR=$(mktemp -d)
```

Also set the namespace to be used for Kubernetes operations. This is `mlx` for public cloud, but for private cloud it may be different.

```bash
NAMESPACE=mlx
```

### Saving CML Data

Shut down any pods that will talk to the database:

```bash
for d in web feature-flags usage-reporter model-proxy cron metering; do
  kubectl scale deployment -n ${NAMESPACE} $d --replicas=0
done
```

Save the current state of the `site_config` table:

```bash
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM site_config) TO '/tmp/site_config.csv' DELIMITER ',' CSV HEADER"
kubectl cp ${NAMESPACE}/db-0:/tmp/$site_config.csv ${TEMP_DIR}/site_config.csv
```

Save the current default image from the `engine_images` table:

```bash
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM engine_images WHERE id=(SELECT MAX(id) FROM engine_images)) TO '/tmp/engine_images.csv' DELIMITER ',' CSV HEADER"
kubectl cp ${NAMESPACE}/db-0:/tmp/engine_images.csv ${TEMP_DIR}/engine_images1.csv
cat ${TEMP_DIR}/engine_images1.csv | head -1 | sed -e 's/^id,//' > ${TEMP_DIR}/engine_images2.csv
cat ${TEMP_DIR}/engine_images1.csv | tail -n +2 | sed 's/^[[:digit:]]\+,Default engine image/Default engine image/g' >> ${TEMP_DIR}/engine_images2.csv
```

Save the users table:

```bash
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY (SELECT * FROM users WHERE admin=TRUE) TO '/tmp/users.csv' DELIMITER ',' CSV HEADER"
kubectl cp ${NAMESPACE}/db-0:/tmp/users.csv ${TEMP_DIR}/users.csv
```

Edit `${TEMP_DIR}/users.csv` and ensure there is *exactly one* entry. It should be an admin that has previously logged in. Remove any other users from this file. The admin that is in this file will be the owner of all projects and other resources that are loaded into the CML cluster. If the desired admin is not in this file, have them log in, and then repeat the last step. Remove the "id," field from the header / first row, and the corresponding value from the second row.

### Copying in CDSW Data

Once the required state is copied out, shut down the database pod:

```bash
kubectl scale statefulset -n ${NAMESPACE} db --replicas=0
```

To copy in the files exported from CDSW, create a helper pod that has the required volumes:

```bash
cat > ${TEMP_DIR}/cml-migration-pod.yaml<<EOF
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
EOF
kubectl apply -f ${TEMP_DIR}/cml-migration-pod.yaml
```

Ensure there are no existing project files about to get mixed in with the migrated files. This command should yield no results:

```bash
kubectl exec cml-migration-pod -n ${NAMESPACE} -- find /migration/projects/projects -type f
```

Copy the archive taken from the CDSW cluster to this pod, then extract it. If this step fails because of memory constraints, extract the archive locally and do the subsequent copying in smaller batches:

```bash
kubectl cp cml-migration.tar.gz ${NAMESPACE}/cml-migration-pod:/migration/backup.tar.gz
kubectl exec cml-migration-pod -n ${NAMESPACE} -- mkdir -p /migration/backup
kubectl exec cml-migration-pod -n ${NAMESPACE} -- tar xzf /migration/backup.tar.gz -C /migration/backup
```

Copy the contents of the NFS storage, and ensure the `cdsw` user (UID 8536) owns them:

```bash
kubectl exec cml-migration-pod -n ${NAMESPACE} -- cp -rf /migration/backup/projects /migration/
kubectl exec cml-migration-pod -n ${NAMESPACE} -- chown -R 8536:8536 /migration/projects; then
```

Copy the database files (you may wish to also save the current CML database state to make it slightly easier to start over, if needed):

```bash
kubectl exec cml-migration-pod -n ${NAMESPACE} -- mv /migration/db-versioned/11 /migration/db-versioned/11.cml-migrate.$(date -Iseconds)
kubectl exec cml-migration-pod -n ${NAMESPACE} -- cp -r /migration/backup/db.sql /migration/db-versioned/db.sql
```

The helper pod can now be deleted:

```bash
kubectl delete pod cml-migration-pod -n ${NAMESPACE}
```

### Database Migrations (and merging other CML DB state)

Restart the database:

```bash
kubectl scale statefulset -n ${NAMESPACE} db --replicas=1
```

Wipe out the CML database and replace it with the CDSW database dump as a starting point:

```bash
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'DROP SCHEMA public CASCADE;'
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'DROP SCHEMA feature_flags CASCADE;'
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'CREATE SCHEMA public;'
kubectl exec db-0 -n ${NAMESPACE} -- bash -c 'psql -U sense < /data-versioned/db.sql'
```

Until DSE-11000 is fixed, we also need to remove any existing quotas to avoid some problems later:

```bash
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'TRUNCATE custom_quota'
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c 'TRUNCATE default_quota'
```

Re-run the db-migrations job. This ensures the schema is complete and up to date:

```bash
MIGRATION_JOB=$(kubectl get jobs -n ${NAMESPACE} | grep ^db-migrate | awk '{ print $1 }')
kubectl get job -n ${NAMESPACE} ${MIGRATION_JOB} -o yaml \
  | grep -v controller-uid \
  > ${TEMP_DIR}/db-migrations.yaml
kubectl delete job ${TEMP_DIR}/db-migrations.yaml -n ${NAMESPACE}
kubectl apply -f ${TEMP_DIR}/db-migrations.yaml -n ${NAMESPACE}
```

Watch the output of `kubectl get pod ${MIGRATION_JOB} -n ${NAMESPACE}` until it completes.

Re-import the CML users table as extracted (and possibly edited) earlier:

```bash
kubectl cp ${TEMP_DIR}/users.csv ${NAMESPACE}/db-0:/tmp/users.csv
CSV_COLUMNS=$(cat ${TEMP_DIR}/users.csv | head -n1)
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY users(${CSV_COLUMNS}) FROM '/tmp/users.csv' DELIMITER ',' CSV HEADER"
kubectl exec db-0 -n ${NAMESPACE} -- rm /tmp/users.csv
```

Re-import the CML engine\_images table as extracted (and possibly edited) earlier:

```bash
kubectl cp ${TEMP_DIR}/engine_images2.csv ${NAMESPACE}/db-0:/tmp/engine_images.csv
CSV_COLUMNS=$(cat ${TEMP_DIR}/engine_images2.csv | head -n1)
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY engine_images(${CSV_COLUMNS}) FROM '/tmp/engine_images.csv' DELIMITER ',' CSV HEADER"
kubectl exec db-0 -n ${NAMESPACE} -- rm /tmp/engine_images.csv
```

Re-import the CML site\_config table as extracted earlier, and set the default image to the CML one:

```bash
kubectl cp ${TEMP_DIR}/site_config.csv ${NAMESPACE}/db-0:/tmp/site_config.csv
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "TRUNCATE site_config"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "COPY site_config FROM '/tmp/site_config.csv' DELIMITER ',' CSV HEADER"
kubectl exec db-0 -n ${NAMESPACE} -- psql -U sense -c "UPDATE site_config SET default_engine_image_id=(SELECT MAX(id) FROM engine_images)"
kubectl exec db-0 -n ${NAMESPACE} -- rm /tmp/site_config.csv
```

### Update Database Context for Migration

Open an interactive PostgreSQL shell:

```bash
kubectl exec -it db-0 -n ${NAMESPACE} -- psql -U sense
```

Ensure all jobs are paused (they should be unpaused on a case-by-case basis) and all applications are (correctly) marked as stopped:

```sql
UPDATE jobs SET paused=true;
UPDATE applications SET status='stopped';
```

Because all projects will be owned by the administrator, we need to ensure they'll all have a unique URL to access them:

```sql
UPDATE projects SET slug = slug || '-cdsw-user-' || user_id WHERE slug IN (SELECT slug FROM projects GROUP BY slug HAVING COUNT(*) > 1)
```

Transfer all projects, jobs, experiments, models, applications, and image builds to the administrator. The images referred to by the builds are actually gone, but the references to them can't easily be removed from the database yet. Confirm that the nested query is pointing at the admin selected previously: `SELECT * FROM users WHERE id=(SELECT MAX(id) FROM users);`:

```sql
UPDATE projects SET user_id=(SELECT MAX(id) FROM users), creator_id=(SELECT MAX(id) FROM users);
UPDATE jobs SET creator_id=(SELECT MAX(id) FROM users);
UPDATE batch_runs SET user_id=(SELECT MAX(id) FROM users);
UPDATE models SET creator_id=(SELECT MAX(id) FROM users);
UPDATE applications SET creator_id=(SELECT MAX(id) FROM users);
UPDATE build_details SET user_id=(SELECT MAX(id) FROM users);
UPDATE projects_engine_images SET engine_image_id=(SELECT MAX(id) FROM engine_images);
```

And delete other context from the database that is not relevant to the new environment:

```sql
DELETE FROM invitations;
TRUNCATE \
  access_keys, authorized_keys, followers, job_notifications, kerberos,
  licenses, model_builds, model_deployments, password_resets, projects_users,
  project_invitations, organization_members, organization_invitations,
  shared_job_run_acl, shared_session_acl, ssh_keys, stars, user_billing,
  user_events, waiting, watchers;
```

And delete previous users. Inspect the output of the first query before running the second, to ensure the new admin is not accidentally deleted:

```sql
SELECT * FROM users WHERE id != (SELECT MAX(id) FROM users);
DELETE FROM users WHERE id != (SELECT MAX(id) FROM users);
```

### Starting Services Back Up

```bash
kubectl exec db-0 -n ${NAMESPACE} -- bash -c "psql -U sense -c \"ALTER USER sense WITH PASSWORD '\$(echo \${POSTGRES_PASSWORD})'\""
kubectl delete pod db-0 -n ${NAMESPACE}

for d in feature-flags usage-reporter model-proxy cron ; do
  kubectl scale deployment -n ${NAMESPACE} $d --replicas=1
done
for d in web; do
  kubectl scale deployment -n ${NAMESPACE} $d --replicas=3
done
```

## Clean Up

Once the migration is complete and successful, you may wish to clean up the temporary files:

```bash
rm -r ${TEMP_DIR}
```
