# php-github-runner

Self-hosted GitHub Actions runner for PHP and Laravel CI. It's built on Ubuntu 24.04 and includes **PHP (8.3, 8.4 or 8.5), Composer, Node, git** and the system libraries Playwright's Chromium needs.

- **Ephemeral by default.** Each runner takes one job and then exits. The container restarts with a clean home directory and a fresh copy of the runner, so nothing a job leaves behind reaches the next job.
- **Your GitHub token stays out of jobs.** The PAT used for registration is only held by a root process. The runner and every job run as an unprivileged user, and that user can't see the token.
- **Org-level or repo-level** runners, with optional labels and runner group. A `php-<version>` label is always added.
- **Rebuilt weekly** with the latest runner release and OS/PHP security updates. Published for `linux/amd64` and `linux/arm64`.

## Usage

```bash
docker run -d --restart always \
  -e REPO=my-org \
  -e ACCESS_TOKEN=ghp_xxx \
  -e NAME=runner-1 \
  rhuruphansen/php-github-runner:8.4
```

`--restart always` (or `restart: always` in Compose) is required in ephemeral mode. Without it the container stops after the first job. See [docker-compose.example.yml](docker-compose.example.yml) for several runners plus MySQL and Mailpit for tests.

In a workflow:

```yaml
jobs:
  test:
    runs-on: [self-hosted, php-8.4]
```

### Images and tags

The images are published to Docker Hub as `rhuruphansen/php-github-runner` and to GHCR as `ghcr.io/rhurup/php-github-runner`.

| Tag | |
|---|---|
| `8.3`, `8.4`, `8.5` | Latest weekly build of that PHP version |
| `8.4-20261019` | Fixed build (date-stamped) |
| `latest` | Same as `8.4` |

`rhuruphansen/github-runner` is the image's old name. It gets the same tags, so existing setups keep updating.

## Environment variables

| Variable | Default | |
|---|---|---|
| `REPO` | required | Org name (`my-org`) for an org runner, or `owner/repo` for a repo runner |
| `ACCESS_TOKEN` | – | PAT used to fetch a registration token at every start (recommended, see below) |
| `REG_TOKEN` | – | Pre-generated registration token. Only used without `ACCESS_TOKEN`. Expires after about 1 hour |
| `NAME` | hostname | Runner name in GitHub |
| `LABELS` | – | Extra comma-separated labels. `php-<version>` is always added |
| `RUNNER_GROUP` | – | Runner group (org runners) |
| `RUNNER_EPHEMERAL` | `true` | `false` keeps the runner and its files between jobs. Faster, because caches survive, but jobs can affect each other |

### Access token

The PAT needs one of these:

| Runner | Classic PAT | Fine-grained PAT |
|---|---|---|
| Org | `admin:org` | Organization permission *Self-hosted runners: Read and write* |
| Repo | `repo` | Repository permission *Administration: Read and write* |

Use a fine-grained token limited to what's needed, or a dedicated machine user. The token never reaches jobs, but it's still a powerful credential on the host.

## Security notes

- Self-hosted runners execute whatever code a workflow contains. **Don't use them for public repositories**, where pull requests from forks can run jobs on your hardware.
- Ephemeral mode cleans the runner user's home and temp directories between jobs. Jobs can't write anywhere else, because there's no root or sudo. For full isolation, recreate the container instead of restarting it.
- Jobs can't use Docker: there's no Docker socket in the container. Run databases and other test services as sibling containers on the same network, as in the example.

## Notes

- **Playwright:** the system libraries are installed, but the browsers aren't, because they must match your project's Playwright version. Run `npx playwright install chromium` in the job. In ephemeral mode, cache `~/.cache/ms-playwright` with `actions/cache`.
- **Composer and npm caches** are cleared between jobs in ephemeral mode. Use `actions/cache` or `actions/setup-node` caching.
- **pcov** is enabled for code coverage.

## Build your own

```bash
docker build --build-arg PHP_VERSION=8.5 -t php-github-runner:8.5 .
```

Build args: `PHP_VERSION`, `PHP_EXTENSIONS`, `RUNNER_VERSION`, `NODE_VERSION` (default 24), `RUNNER_UID` (default 1001).

## License

[MIT](LICENSE)
