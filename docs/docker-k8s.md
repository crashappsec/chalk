# Chalk and Docker ENTRYPOINT in k8s

One of the main objectives of chalk is to connect the dots between build
pipelines and deployment environments. In order to accomplish that while
wrapping docker builds chalk:

- copies chalk binary to `/chalk` in the image
- copies build-time chalkmark to `/chalk.json` in the image
- wraps existing image `ENTRYPOINT` to use `chalk exec` in the `Dockerfile`

See [Docker Wrapping](./docker-wrapping.md) how chalk accomplishes that.

When starting a docker container, docker uses image’s `ENTRYPOINT` as well
as its `CMD` to figure out what command to `exec`. Starting container from
the command line normally honors image’s `ENTRYPOINT` and only its `CMD` is
overwritten. For example:

```bash
docker run -it alpine <cmd>
```

To override the image `ENTRYPOINT` in the terminal explicit `--entrypint` flag
needs to be used. For example:

```bash
docker run -it --entrypoint=<entrypoint> alpine <cmd>
```

Note that at run-time, if a chalk-wrapped image's `ENTRYPOINT` is overwritten,
`chalk` won't be able to collect any run-time metadata, leaving a visibility
gap.

## K8S

Docker and k8s however have
[different terminology](https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/)
for `ENTRYPOINT` and a `CMD` hence making it very easy to
unintentionally override it’s `ENTERYPOINT` as `k8s` `command` sets
the run-time `ENTRYPOINT`. Here is the mapping between docker and
[k8s terminology](https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/):

| Docker       | K8S       |
| ------------ | --------- |
| `ENTRYPOINT` | `command` |
| `CMD`        | `args`    |

### Pods

Consider the following pod definition:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example
spec:
  containers:
    - name: example
      image: chalkedimage
      command: ["sh", "-c"]
      args: ["echo", "hello"]
```

Even though the `chalkedimage` is a chalk wrapped image, as pod explicitly
overwrites the `ENTRYPOINT`, chalk will never run therefore will not collect
and report any of the runtime information.

In order to fix the pod definition to run chalk, you can either:

- omit the`command` in the pod definition and only use `args` in which case k8s
  will honor the `ENTRYPOINT` from the image config. For example:

  ```yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: example
  spec:
    containers:
      - name: example
        image: chalkedimage
        # note the "command" is omitted and instead all params were moved to "args"
        args: ["sh", "-c", "echo", "hello"]
  ```

- (Not recommended) Explicitly add `chalk` to the `ENTRYPOINT` override by
  adding `["chalk", "exec", "--"]`. For example:

  ```yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: example
  spec:
    containers:
      - name: example
        image: chalkedimage
        # note chalk is explicitly added to the ENTRYPOINT override
        command: ["chalk", "exec", "--", "sh", "-c"]
        args: ["echo", "hello"]
  ```

  NOTE this approach is not recommended as it will bypass any additional flags
  chalk might be adding while during image build

### Other k8s resources

Often the pod will not be created directly but instead it will be created via
another k8s resource such as a `Deployment`. Consider the following deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example
spec:
  replicas: 1
  template:
    spec:
      serviceAccountName: example
      containers:
        - name: example
          image: chalkedimage
          command: ["sh", "-c"]
          args: ["echo", "hello"]
```

The fix is identical to vanilla pod definition except the `containers` section
is defined inside a deployment resource under `template.spec`. The same
principle applies to other k8s resources which will create a pod implicitly
such as a cronjob, etc.

## Helm values.yaml

Similar to k8s, many of the helm charts which deploy a pod often have a
configuration of how the container should be started via `command`/ `args`
options inside `values.yaml`. Consider the following `values.yaml`:

```yaml
# values.yaml
image:
  registry: docker.io
  image: chalkedimage
  tag: latest
  command: ["sh", "-c"]
  args: ["echo", "hello"]
```

The fix the same as in k8s resources except the parameters are changed inside
the `values.yaml` file used by helm.

As helm `values.yaml` structure is arbitrary there is no one pattern to
validate however the usage of `command` anywhere within the `values.yaml` file
is a good start.

NOTE that some helm charts can source their template values from values file.
For example it might use `values.yaml` as well as `values.<env>.yaml` to render
the complete helm template. If there are multiple yaml files for a single helm
chart, the `command` usage should be checked in all of them.

### Helm templates

Not all helm charts support setting `command`/ `args` in `values.yaml`. For
example default chart bootstrapped by `helm create` does not allow to customize
`command` / `args` in `values.yaml`. To adjust containers `command` / `args`
helm template needs to be adjusted. All templates should be in `templates`
directory. Searching for where the container definition is defined will allow
to determine how to adjust its `command` / `args`. Some useful strings to
search for:

- `containers:`
- `command:`

## Validation

Once the pod definition is adjusted not to override its `command`, chalk should
run during container run-time. To validate that:

- check `command` is not set in the pod definition via `kubectl` command:

  ```bash
  kubectl get pod -n <namespacce> <podname> -o yaml | grep command
  ```

  If the container still overrides `ENTRYPOINT` via `command`, then something
  is still overriding the `command`.

## References

- https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/
