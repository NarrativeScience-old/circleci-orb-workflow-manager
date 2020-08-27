# CircleCI Orb: Workflow Manager [![CircleCI Orb Version](https://img.shields.io/badge/endpoint.svg?url=https://badges.circleci.io/orb/narrativescience/workflow-manager)](https://circleci.com/orbs/registry/orb/narrativescience/workflow-manager) [![License](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)

[View in CircleCI Orb Registry](https://circleci.com/orbs/registry/orb/narrativescience/workflow-manager)

Manage workflow concurrency and job state using an external store. 

This orb allows you to:

- Limit the number of concurrently running workflows. This is useful when you want to only allow one batch of changes at a time or use AWS CloudFormation and need to wait for the previous deploy to finish.
- Squash commits that are deployed in a workflow when the workflow is allowed to proceed
- Store and retreive data from a key-value store in jobs, even if they're run in parallel
- Track the status of a workflow from the command line
- Send a Slack message when a workflow succeeds after failing

## Rationale

Even though we tested it in different jobs, the [queue orb](https://circleci.com/orbs/registry/orb/eddiewebb/queue) did not consistently block the deploy workflow from executing more than one commit at a time. We don't think the issue is necessarily with the queue orb, it's most likely with the CircleCI API.

Instead of using the CircleCI API to determine if the workflow can continue, we can use a remote key-value store (DynamoDB) that acts as a first-in-first-out (FIFO) queue. This will allow us to process deploys one at a time, in the order the commits were merged.

## Installation

### Requirements

- Install the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html)
- Install [jq](https://stedolan.github.io/jq/download/)
- Set your AWS user profile or `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_DEFAULT_REGION` in your shell

### Deploying the Stack

This orb uses a DynamoDB table to store state. Deploy the [CloudFormation stack](./cloudformation_template.yml) with infrastructure to support this orb using the AWS CLI:

```bash
aws cloudformation deploy \
    --template-file cloudformation_template.yml \
    --stack-name my-new-stack
```

This will create a DynamoDB table. You can tweak that template to align with your organization's standards or use the AWS console instead.

### IAM Permissions

You need to allow your CircleCI AWS IAM user to interact with the DynamoDB table. Create a managed or inline policy and attach it to the IAM user:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowTableAccess",
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:UpdateItem",
                "dynamodb:GetItem",
                "dynamodb:Query"
            ],
            "Resource": [
                "arn:aws:dynamodb:*:*:table/name-of-the-dynamodb-table"
            ]
        }
    ]
}
```

### CircleCI Context

For each workflow that uses this `workflow-manager` orb, create a [CircleCI Context](https://circleci.com/docs/2.0/contexts/) with an environment variable named `WORKFLOW_LOCK_KEY` set to the name of a workflow. Then, set `context: my-new-context` for every job in the workflow.

## Usage

### Entering the Queue: `wait-in-queue`

We run the [`wait-in-queue` job](src/jobs/wait-in-queue.yml) first in the deploy workflow. For example:

```yaml
jobs:
    - workflow-manager/wait-in-queue:
        context: my-deploy
        filters:
            branches:
            only: master
        check_previous_commit: true
        do_not_cancel_workflow_if_tag_in_commit: "[force deploy]"
```

It starts by adding an item to the table with some attributes pertaining to the workflow instance:

Field | Type | Description
--- | --- | ---
key | string | Hash key. The lock "key" that unifies different workflow instances. You must set a `WORKFLOW_LOCK_KEY` environment variable in the your project settings or in a CircleCI context used by your workflow.
committed_at | number | Sort/range key. Unix timestamp of when this commit was committed
created_at | number | Unix timestamp of when this item was added to the table
expires_at | number | Unix timestamp of when this item expires and gets removed from the table
build_num | number | CircleCI build number
commit | string | Git commit SHA
username | string | GitHub username of commit author
workflow_id | string | Workflow instance ID
status | string | Localized secondary index. One of `QUEUED`, `RUNNING`, `SUCCESS`, `FAILED`. Starts out as `QUEUED`.

The job then starts polling the table for the oldest item that doesn't have a status attribute of `SUCCESS` or `FAILED`. If that item has the same `workflow_id` as the job, that means the job is at the "front" of the queue and can continue; we set the item's status to `RUNNING` and the workflow transitions to the next job. It will wait in the queue for up to 4 hours before failing. When the workflow is allowed to continue, it can be said to have a "lock".

### Exiting the Queue: `exit-queue`

The [`exit-queue` job](src/jobs/exit-queue.yml) updates the table item's status attribute to be `SUCCESS` or `FAILED` depending on the value of the `exit_condition` parameter. By updating the job status, it allows other workflows to continue. This job should be called as the last job of every "branch" in a given workflow. For example:

```yaml
jobs:
    # ...
    - workflow-manager/exit-queue:
        context: my-deploy
        requires:
            - deploy-stack
        filters:
        branches:
            only: master
        send_slack_on_recovery: true
```

Even if we add the `exit-queue` job in all the right places in the workflow, we can still get into a state in which the lock is not released when a job fails. CircleCI does not have support for "run a job if some other job failed" so we have to add boilerplate to do so. This takes the form of adding the following step at the bottom of every job that the deploy workflow uses:

```yaml
- exit-queue:
    exit_condition: on_fail
```

The `exit-queue` command will then release the lock only if a previous step in the job failed. It was modeled after the [slack/status command source](https://circleci.com/orbs/registry/orb/circleci/slack#commands-status).

Instead of passing a lock key parameter down through the job/command parameter stack, we can instead leverage a [CircleCI Context](https://circleci.com/docs/2.0/contexts/) that sets an environment variable called `WORKFLOW_LOCK_KEY`. If all jobs in the  workflow include the `context: <context name>` parameter, all commands will have access to that environment variable. The lock-related commands can source that variable to set the lock key.

### Squashing Commits

The deploy worklow has the capability to "squash commits", which replicates a feature of Jenkins that didn't come for free in CircleCI.

__Why?__ The primary goal of this is to reduce the time it takes for developers to get their merged code into production. A secondary goal is to reduce the cost of a bunch of containers burning CircleCI credits while trying to acquire a lock on the workflow.

__How does it work?__ When you merge, your commit [enters the queue](#entering-the-queue). However, if someone else merges and your commit is still waiting to proceed, it will detect that it's no longer last in the queue and self-cancel. Since we build and deploy everything during the workflow, your changes will be included when that later commit starts running. Once a workflow passes the `wait-in-queue` job, it is considered to be in the "running" state and will not be squashed.

__What if I don't want my commit squashed?__ There are known cases in which a commit should not be squashed, in these cases add `[force deploy]` in your merged commit message. This is most common when a commit has database migrations included or the workflow has specific conditions that require commits to be executed without being squashed.

__Note:__ As of now, if there's a failure in the deploy workflow, the Slack message sent to the channel will only include the author of that commit, i.e. it won't contain the list of authors of commits that were squashed. We can see how it plays out before deciding if this behavior should be added.

### Workflows CLI

The `./workflows-cli.sh` script is a CLI for working with CircleCI workflows. It's mostly a wrapper on top of the `aws` CLI and primarily queries the workflows table in DynamoDB (see: [Deploy Queue](#deploy-queue)).

```bash
Usage:
        ./workflows-cli.sh <command> [<arg>...] [options]

Commands:
        ls                      List workflows
        cancel <workflow-id>    Cancel a workflow

List Options:
        -c <column>     Include specific columns in the table. Either provide 'all' or a comma-separated list
                        including one or more of: acquired_at,commit,committed_at,created_at,released_at,status,username,workflow_id
                        (default: workflow_id,status,username,committed_at,acquired_at,released_at,commit)
        -l <count>      Limit the number of workflows returned. Must be between 1 and 100 (default: 100)
        -p <seconds>    Polling interval when watching for updates. Must be between 1 and 60 (default: 2)
        -s <status>     Filter workflows by status. Either provide 'all' or a comma-separated list
                        including one or more of: RUNNING,QUEUED,SUCCESS,FAILED,CANCELLED
                        (default: QUEUED,RUNNING)
        -w              Watch for updates. This clears the terminal.

Common Options:
        -k <key>        DynamoDB primary key value
        -t <table>      DynamoDB table
```

### Recipes

```bash
# Watch the list of currently running or queued workflows
./workflows-cli.sh ls -w

# Watch the list of currently running or queued workflows for a different workflow lock key
./workflows-cli.sh ls -w -k other-workflow-lock-key

# List the all completed workflows
./workflows-cli.sh ls -s SUCCESS,FAILED,CANCELLED

# Manually release the lock if something gets stuck
# List workflows...
./workflows-cli.sh ls
# ...then copy the workflow ID and pass it to the `cancel` command:
./workflows-cli.sh cancel <id>
```
