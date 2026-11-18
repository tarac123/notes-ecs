# Notes app on ECS

The starter code for the "Continuous Deployment to ECS" tutorial.

## Running it on AWS

You need the AWS CLI, signed in, and the GitHub CLI, signed in with
`gh auth login`. Run the setup script from the root of your own repository,
created from this template:

```bash
./scripts/create-infrastructure.sh
```

The script creates an ECS service behind a load balancer, an ECR repository,
and a role that GitHub Actions in your repository can use.

When you're finished, delete everything:

```bash
./scripts/destroy-infrastructure.sh
```

## Running it locally

```bash
docker compose up --build
```

Then open <http://localhost:8000>. Locally, attached files are written to
`backend/uploads` instead of S3.
