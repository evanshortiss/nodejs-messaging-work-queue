library identifier: '3scale-toolbox-jenkins@toolbox-v014',
        retriever: modernSCM([$class: 'GitSCMSource',
        remote: 'https://github.com/evanshortiss/3scale-toolbox-jenkins.git'])

def service = null
def deployLive = false

pipeline {
  agent {
    node {
      label 'nodejs'
    }
  }
  options {
    timeout(time: 45, unit: 'MINUTES')
  }
  environment {
    HUSKY_SKIP_INSTALL = "true"
    SERVICE_NAME = "order-entry-system"
    PROJECT_ID_DEVELOPMENT = "order-system-dev"
    PROJECT_ID_PRODUCTION = "order-system-live"
  }
  stages {
    stage('preamble') {
      steps {
        script {
          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_DEVELOPMENT) {
              echo "Using project: ${openshift.project()}"
              sh 'echo "Using Node.js: $(node -v)"'
              sh 'echo "Using npm: $(npm -v)"'
            }
          }
        }
      }
    }
    stage('checkout') {
      steps {
        checkout scm
      }
    }
    stage('setup') {
      steps {
        script {
          echo 'Performing build environment setup'
          sh 'cd frontend && npm ci'
        }
      }
    }
    stage('test') {
      steps {
        script {
          echo 'Running test scripts'
          sh 'cd frontend && npm test'
        }
      }
    }
    stage('build') {
      steps {
        script {
          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_DEVELOPMENT) {
              echo 'Applying latest dev build-config'

              def bc = openshift.apply( readFile('cicd/openshift/dev/build-config.yml') )

              bc.startBuild()

              echo 'Fetching builds'
              def builds = bc.related('builds')

              echo 'Waiting for build to finish'
              timeout(5) {
                builds.untilEach(1) {
                  return (it.object().status.phase == 'Complete' || it.object().status.phase == 'Cancelled' )
                }
              }
            }
          }
        }
      }
    }
    stage('deploy(dev): update OpenShift/k8s service') {
      when { changeset "cicd/openshift/dev/service.yml" }
      steps {
        script {
          sh "oc patch service/order-entry-system --patch \"\$(cat cicd/openshift/dev/service.yml)\" -n ${env.PROJECT_ID_DEVELOPMENT}"
        }
      }
    }
    stage('deploy(dev): update OpenShift/k8s route') {
      when { changeset "cicd/openshift/dev/route.yml" }
      steps {
        script {
          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_DEVELOPMENT) {
              openshift.apply(readFile('cicd/openshift/dev/route.yml'), '--force')
            }
          }
        }
      }
    }
    stage('deploy(dev): update OpenShift/k8s deployment-config') {
      when { changeset "cicd/openshift/dev/deployment-config.yml" }
      steps {
        script {
          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_DEVELOPMENT) {
              openshift.apply(readFile('cicd/openshift/dev/deployment-config.yml'), '--force')

              echo "Waiting for potential new rollout to complete due to dc change"
              timeout(5) {
                openshift.selector('dc', env.SERVICE_NAME).related('pods').untilEach(1) {
                  return (it.object().status.phase == 'Running')
                }
              }
            }
          }
        }
      }
    }
    stage('deploy(dev): rollout image') {
      steps {
        script {
          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_DEVELOPMENT) {
              def rollout = openshift.selector('dc', env.SERVICE_NAME).rollout().latest()
              timeout(5) {
                openshift.selector('dc', env.SERVICE_NAME).related('pods').untilEach(1) {
                  return (it.object().status.phase == 'Running')
                }
              }
            }
          }
        }
      }
    }
    stage('deploy(dev): 3scale service') {
      steps {
        script {
          // Prepare to update our 3scale service
          echo 'Preparing 3scale dev service update'
          service = toolbox.prepareThreescaleService(
            openapi:          [ filename: 'frontend/swagger.json' ],
            // The system name is the API in the 3scale tenant. The private base url targets our API service
            environment:      [ environmentName: 'dev', baseSystemName: 'order-entry-system-dev', privateBaseUrl: 'http://order-entry-system.order-system-dev:8080' ],
            // This tells toolbox where to find credentials. They're in a secret in the jenkins-cicd namespace.
            // We want to use the "3scale-admin" as destination since that's the default RHMI tenant
            toolbox:          [ openshiftProject: 'jenkins-cicd', destination: 'rhmi-cluster', secretName: '3scale-toolbox' ],
            // Create an empty map for the 'service'. Not sure why...
            service:          [:],
            // Create an application plan named "test"
            applicationPlans: [
              [ systemName: 'test',  name: 'Test',  defaultPlan: true,  published: true ]
            ],
            // Create a dev application, targeting the test plan, using the account ID given, "3" is usually the default "Developer" account
            applications:     [ [ name: 'order-entry-system-dev',  description: 'This is used for the development environment',  plan: 'test',  account: '3' ] ]
          )

          echo 'Performing 3scale dev api import'
          service.importOpenAPI()
          echo "Service with system_name ${service.environment.targetSystemName} created"
          service.applyApplicationPlans()
          service.applyApplication()
        }
      }
    }
    stage('deploy(live): promotion prompt') {
      steps {
        script {
          timeout(time:30, unit:'MINUTES') {
            try {
              // The input method throws if user chooses "Abort" instead of "Continue"
              deployLive = input(message: 'Promote this build to live environment?', ok: 'Continue')
            } catch (e) {
              deployLive = false
            }
          }
        }
      }
    }
    stage('deploy(live): create live image tag') {
      steps {
        script {
          if (deployLive == false) {
            echo "Skipping step since live deployment was not approved"
            return
          }

          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_DEVELOPMENT) {
              openshift.tag("${env.SERVICE_NAME}:latest", "${env.SERVICE_NAME}-live:latest")
            }
          }
        }
      }
    }
    stage('deploy(live): update OpenShift/k8s API objects') {
      steps {
        script {
          if (deployLive == false) {
            echo "Skipping step since live deployment was not approved"
            return
          }

          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_PRODUCTION) {
              echo 'Applying latest live API object definitions'
              openshift.apply(readFile('cicd/openshift/live/deployment-config.yml'), '--force')
              openshift.apply(readFile('cicd/openshift/live/route.yml'), '--force')
              openshift.apply(readFile('cicd/openshift/live/service.yml'), '--force')
            }
          }
        }
      }
    }
    stage('deploy(live): rollout image') {
      steps {
        script {
          if (deployLive == false) {
            echo "Skipping step since live deployment was not approved"
            return
          }

          openshift.withCluster() {
            openshift.withProject(env.PROJECT_ID_PRODUCTION) {
              def rollout = openshift.selector('dc', env.SERVICE_NAME).rollout().latest()
              timeout(5) {
                openshift.selector('dc', env.SERVICE_NAME).related('pods').untilEach(1) {
                  return (it.object().status.phase == 'Running')
                }
              }
            }
          }
        }
      }
    }
    stage('deploy(live): 3scale service') {
      steps {
        script {
          if (deployLive == false) {
            echo "Skipping step since live deployment was not approved"
            return
          }

          echo 'Preparing 3scale live service update'
          service = toolbox.prepareThreescaleService(
            openapi:          [ filename: 'frontend/swagger.json' ],
            // The system name is the API in the 3scale tenant. The private base url targets our API service
            environment:      [ baseSystemName: 'order-entry-system-live', privateBaseUrl: 'http://order-entry-system.order-system-live:8080' ],
            // This tells toolbox where to find credentials. They're in a secret in the jenkins-cicd namespace.
            // We want to use the "3scale-admin" as destination since that's the default RHMI tenant
            toolbox:          [ openshiftProject: 'jenkins-cicd', destination: 'rhmi-cluster', secretName: '3scale-toolbox' ],
            // Create an empty map for the 'service'. Not sure why...
            service:          [:],
            // Create an application plan named "test"
            applicationPlans: [
              [ systemName: 'live',  name: 'Live',  defaultPlan: true,  published: true ]
            ],
            // Create a dev application, targeting the test plan, using the account ID given, "3" is usually the default "Developer" account
            applications:     [ [ name: 'order-entry-system-live',  description: 'This is used for the live environment',  plan: 'live',  account: '3' ] ]
          )

          echo 'Performing 3scale live api import'
          service.importOpenAPI()
          echo "Service with system_name ${service.environment.targetSystemName} created"
          service.applyApplicationPlans()
          service.applyApplication()
        }
      }
    }
  }
}
