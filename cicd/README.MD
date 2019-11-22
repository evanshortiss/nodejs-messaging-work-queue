# CICD Example using Jenkins

## Requirements

* An RHMI (Integreatly) v1.5+ Cluster
* [3scale Toolbox v0.14+](https://github.com/3scale/3scale_toolbox)
* [OpenShift CLI v3.10+](https://github.com/openshift/origin/releases/tag/v3.10.0)

## Overview

This example demonstrates how developers can use [Infrastructure-as-Code](https://en.wikipedia.org/wiki/Infrastructure_as_code)
concepts to create and manage deployments on OpenShift via YAML definitions of
OpenShift/Kubernets API Objects.

An included `BuildConfig` Object is used to define how our Node.js source code
should be packaged as a container using the [source-to-image](https://github.com/openshift/source-to-image)
process.

Lastly, a Jenkins Pipeline is defined in a `Jenkinsfile` in the root of this
repository and a Jenkins `config.xml` is conveniently included so developers
can easily create the pipeline. This pipeline will run the following steps:

1. Fetch the code from this repository (the repository can be changed in the `config.xml` - useful if you fork this)
1. Run the unit tests.
1. Apply and run the new `BuildConfig` in the associated OpenShift project.
1. Create a new build/image using the `BuildConfig`
1. Apply the new OpenShift/Kubernetes API Objects, e.g `service`, `route`, etc.
1. Rollout the new image in the development environment.
1. Update the API on 3scale from the Swagger JSON file in this repository.
1. Allow the developer to optionally run a live deployment that:
  1. Creates a new `live` tag of the image currently deployed in the development environment.
  1. Updates the OpenShift/Kubernetes API Objects in the live environment.
  1. Rolls out the live image in the live environment.
  1. Updates the live 3scale using the Swagger JSON file.

## Setup

The *setup.sh* script will create the environment so this can be demoed easily,
but you'll need to perform the prerequisites outlined below prior to running
the *setup.sh*.

### 1 - Login as Customer Admin

On your development machine run `oc login https://master.<YOUR_CLUSTER>.com -u customer-admin`
and enter the `customer-admin` password when prompted.

### 2 - Create a 3scale Service Token and Config

Before running the *setup.sh* script you need to create a 3scale service token
and a *.3scalerc.yaml* file that contains the token and points to your 3scale
instance. This *.3scalerc.yaml* file is used as a secret in the CICD pipeline
that will allow the pipeline to update the 3scale configuration for the API.

1. Navigate to `https://3scale-admin.apps.<YOUR_CLUSTER>.com/p/admin/user/access_tokens#service-tokens`
1. Click `Add Access Token`.
1. Name the token `CICD`.
1. Check each of the `Scopes` boxes and set `Permission` to `Read & Write`.
1. Click `Create Access Token` and save the token that's displayed on the next screen.

Using the token you can create the 3scale YAML configuration by running the command
`3scale remote add rhmi-cluster https://<TOKEN>@<3SCALE_HOST> --verbose` or by
creating the file manually with the following format:

```
---
:remotes:
  rhmi-cluster:
    :authentication: <TOKEN>
    :endpoint: <3SCALE_HOST>
```

### 3 - Run the Setup Script

Go ahead and run the *setup.sh*. The script will take a while to run as it does
the following:

1. Verifies the user is `customer-admin` and has run the `3scale remote` command.
1. Provisions a Jenkins Persistent instance in its own namespace.
1. Creates a **dev** environment (OpenShift Project) for our API.
1. Creates a Deployment, Service, Route and Build in the **dev** project.
1. Waits for the s2i build to finish in **dev**.
1. Creates a **live** tag of the **dev** build.
1. Creates a **live** environment (OpenShift Project) for our API.
1. Deploys the **live** tag in the **live** environment using Service, Route, and Deployment configs.
1. Waits for Jenkins to finish provisioning.
1. Copies the local *.3scalerc.yaml* to the Jenkins namespace.
1. Configures the Jenkins build by copying a *config.xml* into the Jenkins Pod.
1. Prompts you to reload the Jenkins configuration from disk.
