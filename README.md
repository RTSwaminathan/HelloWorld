# HelloWorld

This repository contains two small Java projects and helper scripts to deploy one of them to AWS Elastic Beanstalk.

## Prerequisites
- Java 17
- Gradle (or use the included Gradle wrapper)
- AWS CLI configured

## Quick setup

1) Configure AWS credentials for profile `aarthi-aws`:

    ```bash
    aws configure --profile aarthi-aws
    ```

2) Build the example jar you want to deploy (example: Java hello-world):

    ```bash
    cd gs-accessing-data-rest/java-hello-world-with-gradle
    ./gradlew clean fatJar
    ```

## Deploy to Elastic Beanstalk

Edit and verify the top of `gs-accessing-data-rest/deploy-eb.sh` for correct defaults, then run:

```bash
./gs-accessing-data-rest/deploy-eb.sh --app aarth-app --env aarthi-env --bucket aarthi-bucket --region us-west-2 --profile aarthi-aws
```

## Cleanup created resources

To remove application versions, terminate environment and optionally delete the S3 bucket and application:

```bash
./gs-accessing-data-rest/cleanup-eb.sh --app aarth-app-1 --env aarthi-env-1 --bucket aarthi-bucket-2 --region us-west-2 --profile aarthi-aws --delete-bucket --delete-app
```

## Notes
- Do not hardcode AWS credentials in scripts. Use profiles, environment variables, or IAM roles.
- The deploy script will attempt to create IAM roles and instance profiles if missing; running it requires sufficient IAM permissions for that.
- The application defaults to listening on port 5000 and the deploy script sets the EB environment PORT accordingly.