#!/bin/bash

# change current working directory to the root of this repositpry
parent_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )

THREESCALE_CONFIG_FILE="$HOME/.3scalerc.yaml"
JENKINS_PROJECT_NAME="jenkins-cicd"
OC_USER=$(oc whoami)

if [[ "$OC_USER" != "customer-admin" ]]; then
    echo -e "\nThis script must be run as customer-admin on an RHMI (Integreatly) Cluster."
    echo "Please run \"oc login -u customer-admin\""
    exit 1
fi

if [ ! -f "$THREESCALE_CONFIG_FILE" ]; then
  echo -e "\nUnable to find 3scale toolbox config in $THREESCALE_CONFIG_FILE"
  echo "Install 3scale Toolbox and run \"3scale remote add rhmi-cluster https://<ACCESS_TOKEN>@3scale-admin.apps.<YOUR_CLUSTER>.com\""
  exit 1
fi

if [[ -z "$MESSAGING_SERVICE_HOST" || -z "$MESSAGING_SERVICE_USER" || -z "$MESSAGING_SERVICE_PASSWORD" || -z "$MESSAGING_SERVICE_PORT" ]]; then
  echo -e "\nThe following variables must be set for this process: MESSAGING_SERVICE_HOST, MESSAGING_SERVICE_USER, MESSAGING_SERVICE_PASSWORD, MESSAGING_SERVICE_PORT\n"
  echo -e "You can get value for these from task #3 in the \"Integrating message-oriented middleware with a RESTful API using AMQ Online\" Solution Pattern on your cluster. Once you get these try again like so:\n"
  echo "MESSAGING_SERVICE_HOST='messaging-unique-id.enmasse.svc' MESSAGING_SERVICE_USER='user-unique-id' MESSAGING_SERVICE_PORT=5672 MESSAGING_SERVICE_PASSWORD='random-password' setup.sh"
  exit 1
fi

function log {
  echo -e "\n[INFO] - $*\n"
}

# create the jenkins project and deployment so it's ready when we need it
log "Creating Jenkins Persistent instance in project named $JENKINS_PROJECT_NAME"
oc new-project $JENKINS_PROJECT_NAME > /dev/null
oc new-app \
-e DISABLE_ADMINISTRATIVE_MONITORS=false -e OPENSHIFT_ENABLE_OAUTH=true \
-p VOLUME_CAPACITY=8Gi -p MEMORY_LIMIT=4Gi jenkins-persistent > /dev/null

# create the dev environment
log "Create dev project and give jenkins serviceaccount permissions"
oc new-project order-system-dev > /dev/null

# provide jenkins access to the project
oc policy add-role-to-user admin system:serviceaccount:$JENKINS_PROJECT_NAME:jenkins

# create secret to hold amq online connection details
oc create secret generic amqp-settings \
--from-literal=MESSAGING_SERVICE_HOST="$MESSAGING_SERVICE_HOST" \
--from-literal=MESSAGING_SERVICE_USER="$MESSAGING_SERVICE_USER" \
--from-literal=MESSAGING_SERVICE_PASSWORD="$MESSAGING_SERVICE_PASSWORD" \
--from-literal=MESSAGING_SERVICE_PORT="$MESSAGING_SERVICE_PORT"

# deploy the project based on infrastructure-as-code (i.e everything is configured in JSON/YAML)
oc apply -f cicd/openshift/dev/build-config.yml
oc apply -f cicd/openshift/dev/service.yml
oc apply -f cicd/openshift/dev/image-stream.yml
oc apply -f cicd/openshift/dev/route.yml

log "Waiting for build to complete before triggering rollout/deployment"

dev_build_ready=1
while [ "$dev_build_ready" -ne 0 ]
do
  oc get builds | grep -i complete
  dev_build_ready=$?
  sleep 5
done

log "Rolling out dev image"
oc apply -f cicd/openshift/dev/deployment-config.yml

# create the live environment - automatically deploys the tag we just created above
log "Create live project and provide it with image-puller rights in order-system-dev namespace"
oc new-project order-system-live > /dev/null
oc policy add-role-to-user system:image-puller system:serviceaccount:order-system-live:default -n order-system-dev
oc policy add-role-to-user admin system:serviceaccount:$JENKINS_PROJECT_NAME:jenkins
oc adm policy add-role-to-group view system:authenticated -n order-system-dev
oc create secret generic amqp-settings \
--from-literal=MESSAGING_SERVICE_HOST="$MESSAGING_SERVICE_HOST" \
--from-literal=MESSAGING_SERVICE_USER="$MESSAGING_SERVICE_USER" \
--from-literal=MESSAGING_SERVICE_PASSWORD="$MESSAGING_SERVICE_PASSWORD" \
--from-literal=MESSAGING_SERVICE_PORT="$MESSAGING_SERVICE_PORT"
oc apply -f cicd/openshift/live/service.yml
oc apply -f cicd/openshift/live/route.yml
oc apply -f cicd/openshift/live/deployment-config.yml

log "Create 3scale-toolbox secret in Jenkins project"
oc create secret generic 3scale-toolbox --from-file="$HOME/.3scalerc.yaml" -n $JENKINS_PROJECT_NAME

log "Waiting for Jenkins to be ready. This takes a while, so now would be a good time to go get some coffee or tea ☕ ⏱"

# Wait for Jenkins to be ready before attempting to create the pipeline
jenkins_ready=1
while [ "$jenkins_ready" -ne 0 ]
do
  oc get pods -n $JENKINS_PROJECT_NAME | grep -vi deploy | grep '1/1' > /dev/null
  jenkins_ready=$?
  sleep 5
done


log "Copying build/job config.xml into Jenkins persistent volume"

# Sync the build config.xml into the jobs/ folder in the Jenkins
# volume and redeploy jenkins so it loads in this new job config
JENKINS_POD=$(oc get pods -n $JENKINS_PROJECT_NAME | awk '{print $1}' | tail -n 1)
JENKINS_HOME=$(oc exec $JENKINS_POD -n $JENKINS_PROJECT_NAME -- bash -c 'echo $JENKINS_HOME')
JENKINS_ROUTE=$(oc get route jenkins -n $JENKINS_PROJECT_NAME -o jsonpath='{.spec.host}')

oc rsync cicd/order-entry-system $JENKINS_POD:$JENKINS_HOME/jobs/ -n $JENKINS_PROJECT_NAME

log "Click *Reload Configuration from Disk* at https://$JENKINS_ROUTE/manage to ensure the CI pipeline is loaded"

log "Summary: Created order-system-dev, order-system-live, and jenkins-cicd projects. Use Jenkins to create the first dev build and deployment at https://$JENKINS_ROUTE"
